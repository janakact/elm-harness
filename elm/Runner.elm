module Runner exposing (Model, Entry, Effect(..), init, create, resume, cancel, frame, exited, schedule, recover, current, jobs, encode, decoder, valid)

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Runner.Protocol as Protocol exposing (Event(..))
import Runner.Types as Types exposing (Backend, Job, Status(..))

type alias Entry = { job : Job, input : String, sequence : Int, messages : Dict String String, order : List String, observations : Dict String String, finished : Bool, failure : String }
type alias Model = { seq : Int, entries : Dict String Entry }
type Effect = Launch Job String | Stop String Int

validSession : String -> Bool
validSession session = not (String.isEmpty session) && String.length session <= 128 && (String.uncons session |> Maybe.map (Tuple.first >> Char.isAlphaNum) |> Maybe.withDefault False) && String.all (\c -> Char.isAlphaNum c || c == '-') session

init : Model
init = { seq = 0, entries = Dict.empty }

jobs : Model -> List Job
jobs model = Dict.values model.entries |> List.map .job |> List.sortBy (\job -> String.dropLeft 1 job.id |> String.toInt |> Maybe.withDefault 0) |> List.reverse

create : String -> String -> Backend -> String -> String -> String -> String -> String -> Model -> Model
create threadId sourceHead backend workspace modelName prompt input at model =
    let id = "j" ++ String.fromInt (model.seq + 1)
        job = { id = id, threadId = threadId, sourceHead = sourceHead, backend = backend, workspace = workspace, model = modelName, prompt = prompt, status = Queued, attempt = 1, sessionId = "", output = "", error = "", observations = [], usage = Nothing, createdAt = at, updatedAt = at }
    in { model | seq = model.seq + 1, entries = Dict.insert id (fresh job input) model.entries }

fresh : Job -> String -> Entry
fresh job input = { job = job, input = input, sequence = 0, messages = Dict.empty, order = [], observations = Dict.empty, finished = False, failure = "" }

resume : String -> String -> String -> Model -> Model
resume id prompt at model =
    { model | entries = Dict.update id (Maybe.map (\entry ->
        let job = entry.job in fresh { job | prompt = prompt, output = "", error = "", observations = [], usage = Nothing, attempt = job.attempt + 1, status = Queued, updatedAt = at } ("Continue this read-only job. Do not modify workspace files.\n\n" ++ prompt))) model.entries }

cancel : String -> String -> Model -> ( Model, List Effect )
cancel id at model = case Dict.get id model.entries of
    Just entry ->
        let job = entry.job in
        if not (Types.active job.status) then ( model, [] ) else
        ( { model | entries = Dict.insert id { entry | job = { job | status = Cancelled, updatedAt = at, error = "Cancelled by user" } } model.entries }, [ Stop id job.attempt ] )
    Nothing -> ( model, [] )

current : String -> Int -> Model -> Bool
current id attempt model = Dict.get id model.entries |> Maybe.map (\entry -> entry.job.attempt == attempt && entry.job.status == Running) |> Maybe.withDefault False

frame : String -> Int -> Int -> E.Value -> String -> Model -> Model
frame id attempt sequence value at model =
    case Dict.get id model.entries of
        Nothing -> model
        Just entry ->
            if not (current id attempt model) || sequence <= entry.sequence then model else
            let
                events = Protocol.decode entry.job.backend value |> Result.withDefault [ Failure "Unsupported or malformed runner event" ]
                apply event state =
                    let job = state.job in case event of
                        Session session ->
                            if not (validSession session) then { state | failure = "Invalid native session ID" }
                            else if not (String.isEmpty job.sessionId) && job.sessionId /= session then { state | failure = "Runner attempted to replace its bound session" }
                            else if List.any (\other -> other.id /= job.id && other.backend == job.backend && other.sessionId == session) (jobs model) then { state | failure = "Native session already belongs to another job" }
                            else { state | job = { job | sessionId = session } }
                        Snapshot key text ->
                            if state.finished then state else
                            let order = if Dict.member key state.messages then state.order else state.order ++ [ key ]
                                messages = Dict.insert key (String.left 500001 text) state.messages
                                output = order |> List.filterMap (\k -> Dict.get k messages) |> String.join "\n\n"
                            in { state | messages = messages, order = order, failure = textBudget output state.failure, job = { job | output = String.left 500000 output } }
                        Delta text -> if state.finished then state else { state | failure = textBudget (job.output ++ text) state.failure, job = { job | output = String.left 500000 (job.output ++ text) } }
                        Observation key text ->
                            let observations = if Dict.size state.observations >= 200 && not (Dict.member key state.observations) then state.observations else Dict.insert key text state.observations
                            in { state | observations = observations, job = { job | observations = Dict.values observations } }
                        Done result usage -> if state.finished then state else { state | finished = True, failure = textBudget (Maybe.withDefault job.output result) state.failure, job = { job | output = Maybe.withDefault job.output result |> String.left 500000, usage = usage } }
                        Failure reason -> { state | failure = String.left 4000 reason }
                updated = List.foldl apply { entry | sequence = sequence } events
                updatedJob = updated.job
            in { model | entries = Dict.insert id { updated | job = { updatedJob | updatedAt = at } } model.entries }

textBudget : String -> String -> String
textBudget output previous = if not (String.isEmpty previous) then previous else if String.length output > 500000 then "External text exceeded the 500,000 character limit; the partial output cannot be reported as a completed result" else ""

exited : String -> Int -> Bool -> String -> String -> Model -> Model
exited id attempt ok error at model =
    if not (current id attempt model) then model else
    { model | entries = Dict.update id (Maybe.map (\entry ->
        let job = entry.job
            problem = if not (String.isEmpty entry.failure) then entry.failure else if not ok then error else if not entry.finished then "Runner exited without a terminal result" else if String.isEmpty job.sessionId then "Runner did not provide a native session ID" else ""
        in { entry | job = { job | status = if String.isEmpty problem then Completed else Failed, error = problem, updatedAt = at } })) model.entries }

schedule : Int -> Model -> ( Model, List Effect )
schedule slots model =
    let queued = jobs model |> List.reverse |> List.filter (\job -> job.status == Queued) |> List.take (max 0 slots)
        start job ( state, effects ) = case Dict.get job.id state.entries of
            Nothing -> ( state, effects )
            Just entry ->
                let running = { job | status = Running } in
                ( { state | entries = Dict.insert job.id { entry | job = running } state.entries }, effects ++ [ Launch running entry.input ] )
    in List.foldl start ( model, [] ) queued

recover : Model -> Model
recover model =
    { model | entries = Dict.map (\_ entry -> let job = entry.job in
        if Types.active job.status then { entry | job = { job | status = Interrupted, output = "", error = "Interrupted by restart; nothing was replayed. Resume explicitly or start a new job." } } else entry) model.entries }

encode : Model -> E.Value
encode model = E.object [ ( "schemaVersion", E.int 1 ), ( "seq", E.int model.seq ), ( "entries", E.dict identity (\entry -> E.object [ ( "job", Types.encodeJob entry.job ), ( "input", E.string entry.input ) ]) model.entries ) ]

decoder : D.Decoder Model
decoder = D.field "schemaVersion" D.int |> D.andThen (\version -> if version /= 1 then D.fail "Unsupported runner schema" else
    D.map2 Model (D.field "seq" D.int) (D.field "entries" (D.dict (D.map2 fresh (D.field "job" Types.jobDecoder) (D.field "input" D.string)))))

valid : Model -> Bool
valid model =
    let items = jobs model
        sessions = items |> List.filter (\job -> not (String.isEmpty job.sessionId)) |> List.map (\job -> Types.backendName job.backend ++ ":" ++ job.sessionId)
    in model.seq >= 0 && List.length sessions == Dict.size (Dict.fromList (List.map (\id -> ( id, () )) sessions))
        && List.all (\( id, entry ) -> id == entry.job.id && String.startsWith "j" id && entry.job.attempt > 0 && (String.dropLeft 1 id |> String.toInt |> Maybe.map (\number -> number > 0 && number <= model.seq) |> Maybe.withDefault False) && (String.isEmpty entry.job.sessionId || validSession entry.job.sessionId) && not (String.startsWith "-" entry.job.model)) (Dict.toList model.entries)
