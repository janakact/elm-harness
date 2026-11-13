module Protocol exposing (action, document, documentDecoder, Saved, validate)

import Runner
import Runner.Types as Jobs
import Dict
import Core
import Policy
import Json.Decode as D
import Json.Encode as E
import User

action : D.Decoder Core.Msg
action =
    let
        str key = D.field key D.string
        at = D.oneOf [ str "at", D.succeed "" ]
    in
    str "type" |> D.andThen (\tag ->
        case tag of
            "StartJob" -> D.map5 Core.StartJob (str "threadId") (D.field "backend" Jobs.backendDecoder) (str "text") (D.oneOf [ str "model", D.succeed "" ]) at
            "ResumeJob" -> D.map3 Core.ResumeJob (str "jobId") (str "text") at
            "CancelJob" -> D.map2 Core.CancelJob (str "jobId") at
            "ReportJob" -> D.map3 Core.ReportJob (str "jobId") (str "target") at
            "NewChat" -> D.map4 Core.NewChatIn (D.oneOf [ str "workspace", D.succeed "" ]) (str "title") (str "model") at
            "Rename" -> D.map2 Core.RenameThread (str "threadId") (str "title")
            "StopThread" -> D.map Core.StopThread (str "threadId")
            "Submit" -> D.map3 Core.Submit (str "threadId") (str "text") at
            "Fork" -> D.map4 Core.Fork (str "nodeId") (str "title") (str "task") at
            "Send" -> D.map5 Core.Send (str "from") (str "target") (str "text") (D.field "refs" (D.list D.string)) at
            "SetModel" -> D.map2 Core.SetModel (str "threadId") (str "model")
            "Run" -> D.map Core.RunThread (str "threadId")
            "Cancel" -> D.map Core.Cancel (str "runId")
            "Approve" -> D.oneOf [ D.map4 Core.ApproveIn (str "threadId") (str "callId") (D.field "allowed" D.bool) at, D.map3 Core.Approve (str "callId") (D.field "allowed" D.bool) at ]
            "SetPolicy" -> D.map3 Core.SetPolicy (str "threadId") (D.field "policy" Policy.decoder) at
            "SetBudget" -> D.map3 Core.SetBudget (str "threadId") (D.field "tokens" D.int) at
            "Summarize" -> D.map2 Core.Summarize (str "threadId") at
            "ApplySummary" -> D.map4 Core.ApplySummary (str "threadId") (str "requestId") (D.oneOf [ str "text", D.succeed "" ]) at
            "DiscardSummary" -> D.map2 Core.DiscardSummary (str "threadId") at
            "Compact" -> D.map3 Core.Compact (str "threadId") (str "text") at
            _ -> D.fail "Unknown action")

type alias Saved = { core : Core.Model, user : User.Model, preservedUser : Maybe E.Value, pluginError : String }

document : Core.Model -> User.Model -> Maybe E.Value -> E.Value
document core user preservedUser = E.object [ ( "documentVersion", E.int 1 ), ( "core", E.object [ ( "schemaVersion", E.int 1 ), ( "data", Core.encode core ) ] ), ( "user", Maybe.withDefault (E.object [ ( "schemaVersion", E.int 2 ), ( "data", User.encode user ) ]) preservedUser ) ]

documentDecoder : D.Decoder Saved
documentDecoder =
    D.map4 (\version coreVersion core rawUser -> { version = version, coreVersion = coreVersion, core = core, rawUser = rawUser }) (D.field "documentVersion" D.int) (D.at [ "core", "schemaVersion" ] D.int) (D.at [ "core", "data" ] Core.decoder) (D.field "user" D.value)
        |> D.andThen (\saved ->
            let core = saved.core
                rawUser = saved.rawUser
            in if saved.version /= 1 || saved.coreVersion /= 1 || not (Core.valid core) then D.fail "Unsupported schema or invalid graph; original preserved" else
            let pluginDecoder = D.field "schemaVersion" D.int |> D.andThen (\v -> if List.member v [ 1, 2 ] then D.field "data" User.decoder else D.fail "Unsupported session plugin schema")
            in case D.decodeValue pluginDecoder rawUser of
                Ok user -> D.succeed { core = core, user = user, preservedUser = Nothing, pluginError = "" }
                Err error -> D.succeed { core = core, user = User.init, preservedUser = Just rawUser, pluginError = D.errorToString error })

{-| Validate public command targets before reporting acceptance. Host stream events
are independently correlated by the core and are not client commands.
-}
validate : Core.Msg -> Core.Model -> Result String ()
validate msg core =
    let thread id = if Dict.member id core.threads then Ok () else Err "Chat not found"
        node id = if Dict.member id core.nodes then Ok () else Err "Node not found"
        job id = Dict.get id core.runners.entries |> Result.fromMaybe "External job not found"
        available backend = Dict.get (Jobs.backendName backend) core.runnerCapabilities |> Maybe.map (\cap -> if cap.available then Ok () else Err cap.error) |> Maybe.withDefault (Err "Runner is unavailable on this server")
        prompt text = if String.isEmpty (String.trim text) || String.length text > 100000 then Err "Job prompt must contain 1–100,000 characters" else Ok ()
    in case msg of
        Core.StartJob id backend text modelName _ -> thread id |> Result.andThen (\_ -> available backend) |> Result.andThen (\_ -> prompt text) |> Result.andThen (\_ -> if String.length modelName > 200 || String.startsWith "-" modelName then Err "Invalid runner model" else if Dict.size core.runners.entries >= 1000 then Err "External job limit reached" else if (Dict.get id core.threads |> Maybe.map (Core.contextEstimate core) |> Maybe.withDefault 0) > 250000 then Err "Captured conversation exceeds external input budget; compact it first" else Ok ())
        Core.ResumeJob id text _ -> job id |> Result.andThen (\entry -> if Jobs.active entry.job.status then Err "Job is already active" else if String.isEmpty entry.job.sessionId then Err "No recorded session to resume; start a new job" else available entry.job.backend) |> Result.andThen (\_ -> prompt text)
        Core.CancelJob id _ -> job id |> Result.map (always ())
        Core.ReportJob id target _ -> job id |> Result.andThen (\entry -> if entry.job.status /= Jobs.Completed || String.isEmpty entry.job.output then Err "Only completed results can be delivered" else thread target)
        Core.Submit id text _ -> if String.isEmpty (String.trim text) then Err "Message is empty" else thread id
        Core.RenameThread id title -> if String.isEmpty (String.trim title) then Err "Title is empty" else thread id
        Core.StopThread id -> thread id
        Core.RunThread id -> thread id
        Core.SetModel id model -> if String.isEmpty (String.trim model) then Err "Model is empty" else thread id
        Core.SetPolicy id _ _ -> thread id
        Core.SetBudget id tokens _ -> if tokens < 1000 || tokens > 1000000 then Err "Input budget is out of range" else thread id
        Core.Summarize id _ -> thread id
        Core.ApplySummary id _ _ _ -> thread id
        Core.DiscardSummary id _ -> thread id
        Core.Compact id _ _ -> thread id
        Core.Fork id _ _ _ -> node id
        Core.Send from target _ refs _ -> if not (List.all (\id -> Dict.member id core.nodes) refs) then Err "Referenced node not found" else thread from |> Result.andThen (\_ -> thread target)
        Core.Cancel id -> if Dict.member id core.runs then Ok () else Err "Run not found"
        Core.NewChatIn root _ _ _ -> if String.isEmpty root || Dict.member root core.workspaces then Ok () else Err "Workspace has not been opened"
        _ -> Ok ()
