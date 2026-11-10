module Core exposing (Model, Node, Thread, Run, Msg(..), Effect(..), init, update, view, visibleNodes, schedule, recover, encode, decoder, valid)

import Dict exposing (Dict)
import Prompt
import Json.Decode as D
import Json.Encode as E

type alias Node = { id : String, parentId : Maybe String, refs : List String, threadId : String, actor : String, kind : String, text : String, at : String }
type alias Thread = { id : String, head : String, forkedFrom : Maybe String, title : String, model : String, workspace : String }
type alias Call = { id : String, name : String, arguments : String }
type alias Run = { id : String, threadId : String, status : String, requestId : String, draft : String, calls : Dict Int Call, pending : List String, steps : Int }
type alias Pending = { kind : String, text : String, refs : List String, at : String }
type alias Model = { nodes : Dict String Node, threads : Dict String Thread, runs : Dict String Run, inbox : Dict String (List Pending), seq : Int, revision : Int, focused : String, selected : String, filter : String, maxConcurrent : Int, systemPrompt : String, defaultWorkspace : String, workspaces : Dict String String }

type Msg
    = Submit String String String
    | NewChat String String String
    | NewChatIn String String String String
    | RenameThread String String
    | StopThread String
    | BindWorkspace String String
    | RegisterWorkspace String String
    | Select String
    | Focus String
    | Fork String String String String
    | Send String String String (List String) String
    | SetModel String String
    | Filter String
    | RunThread String
    | Delta String String
    | Finished String String
    | Failed String String String
    | Cancel String
    | ToolDelta String Int String String String
    | ToolFinished String String Bool String
    | Approve String Bool String
    | SetPrompt String
    | Compact String String String
    | RecoverInterrupted String
    | Configure Int

type Effect = Request String String String E.Value | Abort String | Execute String String E.Value Bool

init : Model
init =
    let
        startNode = { id = "n1", parentId = Nothing, refs = [], threadId = "t1", actor = "System", kind = "Notice", text = "Session started", at = "" }
        thread = { id = "t1", head = "n1", forkedFrom = Nothing, title = "Main", model = "deepseek/deepseek-v4-flash", workspace = "" }
    in
    { nodes = Dict.singleton "n1" startNode, threads = Dict.singleton "t1" thread, runs = Dict.empty, inbox = Dict.empty, seq = 1, revision = 0, focused = "t1", selected = "n1", filter = "all", maxConcurrent = 4, systemPrompt = "", defaultWorkspace = "", workspaces = Dict.empty }

busy : String -> Model -> Bool
busy threadId model = Dict.values model.runs |> List.any (\r -> r.threadId == threadId && List.member r.status [ "Queued", "RequestingModel", "Streaming", "ExecutingTool", "AwaitingApproval" ])

queue : String -> Pending -> Model -> Model
queue threadId pending model =
    { model | inbox = Dict.update threadId (\items -> Just (Maybe.withDefault [] items ++ [ pending ])) model.inbox, revision = model.revision + 1 }

flush : String -> Model -> ( Model, Bool )
flush threadId model =
    let
        pending = Dict.get threadId model.inbox |> Maybe.withDefault []
        base = { model | inbox = Dict.remove threadId model.inbox }
        append item current =
            let actor = if item.kind == "UserMessage" then "User" else "Agent"
                ( nextModel, _ ) = commit threadId actor item.kind item.text item.refs item.at current
            in nextModel
    in
    ( List.foldl append base pending, not (List.isEmpty pending) )

recover : Model -> Model
recover model =
    let
        ids node = D.decodeString (D.list (D.field "id" D.string)) node.text |> Result.withDefault []
        results = Dict.values model.nodes |> List.filter (\n -> n.kind == "ToolResult") |> List.filterMap (\n -> D.decodeString (D.field "tool_call_id" D.string) n.text |> Result.toMaybe)
        orphan node current =
            List.foldl (\id state ->
                if List.member id results then state else
                    let
                        payload = E.object [ ( "role", E.string "tool" ), ( "tool_call_id", E.string id ), ( "content", E.string "Tool interrupted by restart. No automatic retry was performed." ) ]
                    in commit node.threadId "System" "ToolResult" (E.encode 0 payload) [] "" state |> Tuple.first) current (ids node)
        repaired = List.foldl orphan model (Dict.values model.nodes |> List.filter (\n -> n.kind == "ToolCall"))
    in List.foldl (\threadId current -> flush threadId current |> Tuple.first) repaired (Dict.keys repaired.inbox)

next : String -> Model -> ( String, Model )
next prefix model = ( prefix ++ String.fromInt (model.seq + 1), { model | seq = model.seq + 1 } )

commit : String -> String -> String -> String -> List String -> String -> Model -> ( Model, Maybe Node )
commit threadId actor kind content refs at model =
    case Dict.get threadId model.threads of
        Nothing -> ( model, Nothing )
        Just thread ->
            let
                ( id, m1 ) = next "n" model
                node = { id = id, parentId = Just thread.head, refs = refs, threadId = threadId, actor = actor, kind = kind, text = content, at = at }
                threads = Dict.insert threadId { thread | head = id } m1.threads
            in
            ( { m1 | nodes = Dict.insert id node m1.nodes, threads = threads, revision = m1.revision + 1 }, Just node )

ancestry : Model -> String -> List Node
ancestry model head =
    let
        walk id seen =
            if List.member id seen then [] else
                case Dict.get id model.nodes of
                    Nothing -> []
                    Just node -> node :: (Maybe.map (\parent -> walk parent (id :: seen)) node.parentId |> Maybe.withDefault [])
    in
    List.reverse (walk head [])

context : Model -> Thread -> E.Value
context model thread =
    let
        nodes = ancestry model thread.head
        lastSummary = nodes |> List.filter (\n -> n.kind == "Summary") |> List.reverse |> List.head
        relevant = case lastSummary of
            Nothing -> nodes
            Just summary -> nodes |> List.filter (\n -> (String.dropLeft 1 n.id |> String.toInt |> Maybe.withDefault 0) >= (String.dropLeft 1 summary.id |> String.toInt |> Maybe.withDefault 0))
        message n =
            case n.kind of
                "ToolCall" -> D.decodeString D.value n.text |> Result.toMaybe |> Maybe.map (\calls -> E.object [ ( "role", E.string "assistant" ), ( "content", E.null ), ( "tool_calls", calls ) ])
                "ToolResult" -> D.decodeString D.value n.text |> Result.toMaybe
                _ -> if List.member n.kind [ "UserMessage", "AgentMessage", "Handoff", "Summary" ] then Just (E.object [ ( "role", E.string (if n.kind == "AgentMessage" then "assistant" else "user") ), ( "content", E.string n.text ) ]) else Nothing
    in E.list identity (E.object [ ( "role", E.string "system" ), ( "content", E.string (Dict.get thread.workspace model.workspaces |> Maybe.withDefault model.systemPrompt) ) ] :: List.filterMap message relevant)

takeUntilPrompt : List Node -> List Node
takeUntilPrompt nodes =
    case nodes of
        [] -> []
        node :: rest -> if List.member node.kind [ "UserMessage", "Summary" ] then [] else node :: takeUntilPrompt rest

start : String -> Model -> ( Model, List Effect )
start threadId model =
    case Dict.get threadId model.threads of
        Nothing -> ( model, [] )
        Just thread ->
            if busy threadId model then ( model, [] )
            else if activeCount model >= model.maxConcurrent then
                let
                    ( id, queued ) = next "r" model
                    run = { id = id, threadId = threadId, status = "Queued", requestId = "", draft = "", calls = Dict.empty, pending = [], steps = 0 }
                in ( { queued | runs = Dict.insert id run queued.runs }, [] )
            else if String.length (E.encode 0 (context model thread)) > 200000 then
                let ( limited, _ ) = commit threadId "System" "Notice" "Context budget exceeded. Supply an explicit summary using Compact to continue; original history is retained." [] "" model in ( limited, [] )
            else if (ancestry model thread.head |> List.reverse |> takeUntilPrompt |> List.filter (\n -> n.kind == "ToolCall") |> List.length) >= 25 then
                let ( limited, _ ) = commit threadId "System" "Notice" "Tool turn budget reached (25). Send a new instruction to continue." [] "" model in ( limited, [] )
            else
                let
                    ( traced, _ ) = commit threadId "System" "Activity" ("Model request · prompt v3\nSources: SYSTEM.md (override if present), APPEND_SYSTEM.md, AGENTS.md\n" ++ (Dict.get thread.workspace model.workspaces |> Maybe.withDefault model.systemPrompt)) [] "" model
                    ( runId, m1 ) = next "r" traced
                    ( requestId, m2 ) = next "q" m1
                    run = { id = runId, threadId = threadId, status = "RequestingModel", requestId = requestId, draft = "", calls = Dict.empty, pending = [], steps = 0 }
                in
                ( { m2 | runs = Dict.insert runId run m2.runs }, [ Request requestId threadId thread.model (context model thread) ] )

activeCount : Model -> Int
activeCount model = Dict.values model.runs |> List.filter (\r -> List.member r.status [ "RequestingModel", "Streaming", "ExecutingTool", "AwaitingApproval" ]) |> List.length

schedule : Model -> ( Model, List Effect )
schedule model =
    case Dict.values model.runs |> List.filter (\r -> r.status == "Queued") |> List.head of
        Nothing -> ( model, [] )
        Just run ->
            if activeCount model >= model.maxConcurrent then ( model, [] ) else
                let
                    ready = { model | runs = Dict.insert run.id { run | status = "Completed" } model.runs }
                    ( started, effects ) = start run.threadId ready
                    ( scheduled, remaining ) = schedule started
                in ( scheduled, effects ++ remaining )

update : Msg -> Model -> ( Model, List Effect, Maybe String )
update msg model =
    case msg of
        BindWorkspace root prompt ->
            ( { model | defaultWorkspace = root, systemPrompt = prompt, workspaces = Dict.insert root prompt model.workspaces, threads = Dict.map (\_ thread -> if String.isEmpty thread.workspace then { thread | workspace = root } else thread) model.threads }, [], Nothing )
        RegisterWorkspace root prompt -> ( { model | workspaces = Dict.insert root prompt model.workspaces, revision = model.revision + 1 }, [], Nothing )
        RenameThread threadId title ->
            if String.isEmpty (String.trim title) then ( model, [], Nothing ) else
                ( { model | threads = Dict.update threadId (Maybe.map (\thread -> { thread | title = String.trim title })) model.threads, revision = model.revision + 1 }, [], Nothing )
        StopThread threadId ->
            let
                stop run ( current, effects ) = let ( updated, emitted, _ ) = update (Cancel run.id) current in ( updated, effects ++ emitted )
                ( stopped, commands ) = Dict.values model.runs |> List.filter (\r -> r.threadId == threadId && List.member r.status [ "Queued", "RequestingModel", "Streaming", "ExecutingTool", "AwaitingApproval" ]) |> List.foldl stop ( model, [] )
            in ( stopped, commands, Nothing )
        NewChat title modelName at -> update (NewChatIn model.defaultWorkspace title modelName at) model
        NewChatIn requestedWorkspace title modelName at ->
            let
                ( threadId, m1 ) = next "t" model
                ( nodeId, m2 ) = next "n" m1
                node = { id = nodeId, parentId = Nothing, refs = [], threadId = threadId, actor = "System", kind = "Notice", text = "Session started", at = at }
                thread = { id = threadId, head = nodeId, forkedFrom = Nothing, title = if String.isEmpty (String.trim title) then "Chat " ++ String.fromInt (Dict.size model.threads + 1) else String.trim title, model = if String.isEmpty (String.trim modelName) then "deepseek/deepseek-v4-flash" else String.trim modelName, workspace = if String.isEmpty requestedWorkspace then model.defaultWorkspace else requestedWorkspace }
            in
            ( { m2 | nodes = Dict.insert nodeId node m2.nodes, threads = Dict.insert threadId thread m2.threads, selected = nodeId, focused = threadId, revision = m2.revision + 1 }, [], Just "Notice" )
        Submit threadId text at ->
            if String.isEmpty (String.trim text) then ( model, [], Nothing ) else
            if busy threadId model then ( queue threadId { kind = "UserMessage", text = String.trim text, refs = [], at = at } model, [], Nothing ) else
                let
                    ( m1, node ) = commit threadId "User" "UserMessage" (String.trim text) [] at model
                    ( m2, effects ) = start threadId m1
                in
                ( { m2 | selected = Maybe.map .id node |> Maybe.withDefault model.selected }, effects, Just "UserMessage" )
        Select id -> ( if Dict.member id model.nodes then { model | selected = id } else model, [], Nothing )
        Focus id -> ( if Dict.member id model.threads then { model | focused = id, selected = Maybe.map .head (Dict.get id model.threads) |> Maybe.withDefault model.selected } else model, [], Nothing )
        Fork nodeId title task at ->
            case Dict.get nodeId model.nodes of
                Nothing -> ( model, [], Nothing )
                Just source ->
                    let
                        ( threadId, m1 ) = next "t" model
                        sourceModel = Dict.get source.threadId model.threads |> Maybe.map .model |> Maybe.withDefault "deepseek/deepseek-v4-flash"
                        thread = { id = threadId, head = nodeId, forkedFrom = Just nodeId, title = if String.isEmpty (String.trim title) then threadId else title, model = sourceModel, workspace = Dict.get source.threadId model.threads |> Maybe.map .workspace |> Maybe.withDefault model.defaultWorkspace }
                        m2 = { m1 | threads = Dict.insert threadId thread m1.threads, focused = threadId, selected = nodeId, revision = m1.revision + 1 }
                    in
                    if String.isEmpty (String.trim task) then ( m2, [], Nothing ) else update (Submit threadId task at) m2
        Send from target text refs at ->
            if not (Dict.member target model.threads) || String.isEmpty (String.trim text) || not (List.all (\id -> Dict.member id model.nodes) refs) then ( model, [], Nothing ) else
                let
                    source = Dict.get from model.threads |> Maybe.map .title |> Maybe.withDefault "User"
                    snapshots = refs |> List.filterMap (\id -> Dict.get id model.nodes |> Maybe.map (\n -> "[" ++ id ++ "] " ++ n.text)) |> String.join "\n"
                    delivered = "From " ++ source ++ ": " ++ text ++ "\n\nReferenced content:\n" ++ snapshots
                    ( m1, _ ) = if busy target model then ( queue target { kind = "Handoff", text = delivered, refs = refs, at = at } model, Nothing ) else commit target "Agent" "Handoff" delivered refs at model
                in
                ( m1, [], Just "Handoff" )
        SetModel id name ->
            case Dict.get id model.threads of
                Nothing -> ( model, [], Nothing )
                Just thread -> ( { model | threads = Dict.insert id { thread | model = name } model.threads, revision = model.revision + 1 }, [], Nothing )
        Filter value -> ( { model | filter = value }, [], Nothing )
        RunThread id -> let ( m, effects ) = start id model in ( m, effects, Nothing )
        Delta requestId text ->
            ( { model | runs = Dict.map (\_ r -> if r.requestId == requestId && List.member r.status [ "RequestingModel", "Streaming" ] then { r | status = "Streaming", draft = r.draft ++ text } else r) model.runs }, [], Nothing )
        Finished requestId at ->
            case Dict.values model.runs |> List.filter (\r -> r.requestId == requestId && List.member r.status [ "RequestingModel", "Streaming" ]) |> List.head of
                Nothing -> ( model, [], Nothing )
                Just run ->
                    let
                        ( m1, _ ) = if String.isEmpty run.draft then ( model, Nothing ) else commit run.threadId "Agent" "AgentMessage" run.draft [] at model
                        calls = Dict.values run.calls
                        callJson call = E.object [ ( "id", E.string call.id ), ( "type", E.string "function" ), ( "function", E.object [ ( "name", E.string call.name ), ( "arguments", E.string call.arguments ) ] ) ]
                        ( withCalls, _ ) = if List.isEmpty calls then ( m1, Nothing ) else commit run.threadId "Agent" "ToolCall" (E.encode 0 (E.list callJson calls)) [] at m1
                        register call ( current, commands ) =
                            if Prompt.validate call.name call.arguments then
                                if call.name == "read" then ( current, Execute call.id call.name (D.decodeString D.value call.arguments |> Result.withDefault E.null) False :: commands )
                                else
                                    let ( marked, _ ) = commit run.threadId "System" "Approval" (E.encode 0 (callJson call)) [] at current
                                    in ( marked, commands )
                            else ( current, commands )
                        ( registered, toolEffects ) = List.foldl register ( withCalls, [] ) calls
                        invalidEffects = calls |> List.filter (\c -> not (Prompt.validate c.name c.arguments)) |> List.map (\c -> Execute c.id "invalid" E.null False)
                        nextStatus = if List.isEmpty calls then "Completed" else if List.any (\c -> c.name /= "read" && Prompt.validate c.name c.arguments) calls then "AwaitingApproval" else "ExecutingTool"
                        runs = Dict.insert run.id { run | status = nextStatus, requestId = "", draft = "", pending = List.map .id calls } registered.runs
                        ( m2, hadInbox ) = if List.isEmpty calls then flush run.threadId { registered | runs = runs } else ( { registered | runs = runs }, False )
                        ( m3, effects ) = if hadInbox then start run.threadId m2 else ( m2, [] )
                    in
                    ( m3, toolEffects ++ invalidEffects ++ effects, Just "AgentMessage" )
        Failed requestId error at ->
            case Dict.values model.runs |> List.filter (\r -> r.requestId == requestId && List.member r.status [ "RequestingModel", "Streaming" ]) |> List.head of
                Nothing -> ( model, [], Nothing )
                Just run ->
                    let
                        ( m1, _ ) = commit run.threadId "System" "Notice" error [] at model
                    in
                    let
                        ( m2, hadInbox ) = flush run.threadId { m1 | runs = Dict.insert run.id { run | status = "Failed", requestId = "", draft = "" } m1.runs }
                        ( m3, effects ) = if hadInbox then start run.threadId m2 else ( m2, [] )
                    in
                    ( m3, effects, Just "Notice" )
        Configure limit -> ( { model | maxConcurrent = clamp 1 16 limit }, [], Nothing )
        RecoverInterrupted threadId ->
            let ( recovered, _ ) = commit threadId "System" "Notice" "Run interrupted by restart; transient output was discarded. Use Run to resume." [] "" model in ( recovered, [], Nothing )
        SetPrompt prompt -> ( { model | systemPrompt = prompt }, [], Nothing )
        Compact threadId summary at ->
            if busy threadId model || String.isEmpty (String.trim summary) then ( model, [], Nothing ) else
                let ( updated, _ ) = commit threadId "User" "Summary" summary [] at model in ( updated, [], Just "Summary" )
        ToolDelta requestId index callId name args ->
            let
                add _ run =
                    if run.requestId /= requestId then run else
                        let
                            previous = Dict.get index run.calls |> Maybe.withDefault { id = "", name = "", arguments = "" }
                            call = { id = if String.isEmpty callId then previous.id else callId, name = previous.name ++ name, arguments = previous.arguments ++ args }
                        in { run | calls = Dict.insert index call run.calls }
            in ( { model | runs = Dict.map add model.runs }, [], Nothing )
        Approve callId allowed at ->
            case Dict.values model.runs |> List.filter (\r -> List.member callId r.pending) |> List.head of
                Nothing -> ( model, [], Nothing )
                Just run ->
                    case Dict.values run.calls |> List.filter (\c -> c.id == callId) |> List.head of
                        Nothing -> ( model, [], Nothing )
                        Just call ->
                            let
                                already = Dict.values model.nodes |> List.any (\n -> n.kind == "Activity" && String.startsWith (callId ++ ":") n.text)
                                ( marked, _ ) = commit run.threadId "User" "Activity" (callId ++ (if allowed then ": approved" else ": denied")) [] at model
                            in
                            if already then ( model, [], Nothing ) else if allowed then ( marked, [ Execute callId call.name (D.decodeString D.value call.arguments |> Result.withDefault E.null) True ], Nothing ) else update (ToolFinished callId "Permission denied by user" False at) marked
        ToolFinished callId output ok at ->
            case Dict.values model.runs |> List.filter (\r -> List.member callId r.pending && r.status /= "Cancelled") |> List.head of
                Nothing -> ( model, [], Nothing )
                Just run ->
                    let
                        payload = E.object [ ( "role", E.string "tool" ), ( "tool_call_id", E.string callId ), ( "content", E.string ((if ok then "" else "Error: ") ++ output) ) ]
                        ( committed, _ ) = commit run.threadId "Tool" "ToolResult" (E.encode 0 payload) [] at model
                        remaining = List.filter ((/=) callId) run.pending
                        done = List.isEmpty remaining
                        current = { committed | runs = Dict.insert run.id { run | pending = remaining, status = if done then "Completed" else run.status } committed.runs }
                        ( delivered, _ ) = if done then flush run.threadId current else ( current, False )
                        ( continued, effects ) = if done then start run.threadId delivered else ( delivered, [] )
                    in ( continued, effects, Just "ToolResult" )
        Cancel runId ->
            case Dict.get runId model.runs of
                Nothing -> ( model, [], Nothing )
                Just run ->
                    let
                        cancelled id current = commit run.threadId "System" "ToolResult" (E.encode 0 (E.object [ ( "role", E.string "tool" ), ( "tool_call_id", E.string id ), ( "content", E.string "Cancelled by user" ) ])) [] "" current |> Tuple.first
                        recorded = List.foldl cancelled model run.pending
                    in ( { recorded | runs = Dict.insert runId { run | status = "Cancelled", requestId = "", draft = "", pending = [] } recorded.runs }, Abort run.requestId :: List.map Abort run.pending, Nothing )

view : Model -> E.Value
view model =
    let
        selected = Dict.get model.selected model.nodes
        nodeItem n = E.object [ ( "id", E.string n.id ), ( "parentId", maybeString n.parentId ), ( "threadId", E.string n.threadId ), ( "kind", E.string n.kind ), ( "actor", E.string n.actor ), ( "preview", E.string (String.left 90 (String.lines n.text |> List.head |> Maybe.withDefault "")) ), ( "text", E.string n.text ), ( "at", E.string n.at ), ( "refs", E.list E.string n.refs ) ]
        threadItem t = E.object [ ( "id", E.string t.id ), ( "title", E.string t.title ), ( "head", E.string t.head ), ( "forkedFrom", maybeString t.forkedFrom ), ( "model", E.string t.model ), ( "workspace", E.string t.workspace ), ( "status", E.string (Dict.values model.runs |> List.sortBy (\r -> String.dropLeft 1 r.id |> String.toInt |> Maybe.withDefault 0) |> List.filter (\r -> r.threadId == t.id) |> List.reverse |> List.head |> Maybe.map .status |> Maybe.withDefault "Idle") ) ]
    in
    E.object [ ( "type", E.string "Column" ), ( "focused", E.string model.focused ), ( "filter", E.string model.filter )
    , ( "sidebar", E.object [ ( "type", E.string "AgentSidebar" ), ( "items", E.list threadItem (Dict.values model.threads) ) ] )
    , ( "graph", E.object [ ( "type", E.string "ConversationGraph" ), ( "nodes", E.list nodeItem (visibleNodes model) ) ] )
    , ( "detail", E.object [ ( "type", E.string "DetailInspector" ), ( "node", Maybe.map nodeItem selected |> Maybe.withDefault E.null ) ] )
    , ( "selected", E.string model.selected ), ( "revision", E.int model.revision )
    , ( "drafts", E.object (Dict.values model.runs |> List.filter (\r -> not (String.isEmpty r.draft)) |> List.map (\r -> ( r.threadId, E.string r.draft ))) ) ]

visibleNodes : Model -> List Node
visibleNodes model =
    Dict.values model.nodes
        |> List.sortBy (\n -> String.dropLeft 1 n.id |> String.toInt |> Maybe.withDefault 0)
        |> List.reverse
        |> List.filter (\n -> model.filter == "all" || (model.filter == "messages" && List.member n.kind [ "UserMessage", "AgentMessage", "Handoff" ]) || (model.filter == "tools" && List.member n.kind [ "ToolCall", "ToolResult" ]) || (model.filter == "errors" && n.kind == "Notice"))

maybeString : Maybe String -> E.Value
maybeString value = Maybe.map E.string value |> Maybe.withDefault E.null

encode : Model -> E.Value
encode model =
    E.object [ ( "interrupted", E.list E.string (Dict.values model.runs |> List.filter (\r -> List.member r.status [ "RequestingModel", "Streaming", "ExecutingTool", "AwaitingApproval" ]) |> List.map .threadId) ), ( "defaultWorkspace", E.string model.defaultWorkspace ), ( "workspaces", E.dict identity E.string model.workspaces ), ( "systemPrompt", E.string model.systemPrompt ), ( "schemaVersion", E.int 1 ), ( "seq", E.int model.seq ), ( "revision", E.int model.revision ), ( "focused", E.string model.focused ), ( "selected", E.string model.selected ), ( "filter", E.string model.filter )
    , ( "nodes", E.list (\n -> E.object [ ( "id", E.string n.id ), ( "parentId", maybeString n.parentId ), ( "refs", E.list E.string n.refs ), ( "threadId", E.string n.threadId ), ( "actor", E.string n.actor ), ( "kind", E.string n.kind ), ( "text", E.string n.text ), ( "at", E.string n.at ) ]) (Dict.values model.nodes) )
    , ( "threads", E.list (\t -> E.object [ ( "id", E.string t.id ), ( "head", E.string t.head ), ( "forkedFrom", maybeString t.forkedFrom ), ( "title", E.string t.title ), ( "model", E.string t.model ), ( "workspace", E.string t.workspace ) ]) (Dict.values model.threads) )
    , ( "inbox", E.object (Dict.toList model.inbox |> List.map (\( id, items ) -> ( id, E.list (\p -> E.object [ ( "kind", E.string p.kind ), ( "text", E.string p.text ), ( "refs", E.list E.string p.refs ), ( "at", E.string p.at ) ]) items ) )) ) ]

nodeDecoder : D.Decoder Node
nodeDecoder = D.map7 Node (D.field "id" D.string) (D.field "parentId" (D.nullable D.string)) (D.field "refs" (D.list D.string)) (D.field "threadId" D.string) (D.field "actor" D.string) (D.field "kind" D.string) (D.field "text" D.string) |> D.andThen (\partial -> D.field "at" D.string |> D.map partial)

threadDecoder : D.Decoder Thread
threadDecoder = D.map6 Thread (D.field "id" D.string) (D.field "head" D.string) (D.field "forkedFrom" (D.nullable D.string)) (D.field "title" D.string) (D.field "model" D.string) (D.oneOf [ D.field "workspace" D.string, D.succeed "" ])

decoder : D.Decoder Model
decoder =
    D.map8 (\seq revision focused selected filter nodes threads inbox -> { nodes = Dict.fromList (List.map (\n -> ( n.id, n )) nodes), threads = Dict.fromList (List.map (\t -> ( t.id, t )) threads), runs = Dict.empty, maxConcurrent = 4, systemPrompt = "", defaultWorkspace = "", workspaces = Dict.empty, inbox = inbox, seq = seq, revision = revision, focused = focused, selected = selected, filter = filter })
        (D.field "seq" D.int) (D.field "revision" D.int) (D.field "focused" D.string) (D.field "selected" D.string) (D.field "filter" D.string) (D.field "nodes" (D.list nodeDecoder)) (D.field "threads" (D.list threadDecoder))
        (D.field "inbox" (D.dict (D.list (D.map4 Pending (D.field "kind" D.string) (D.field "text" D.string) (D.field "refs" (D.list D.string)) (D.field "at" D.string)))) |> D.maybe |> D.map (Maybe.withDefault Dict.empty))
        |> D.andThen (\model -> D.map2 (\root workspaces -> { model | defaultWorkspace = root, workspaces = workspaces }) (D.oneOf [ D.field "defaultWorkspace" D.string, D.succeed "" ]) (D.oneOf [ D.field "workspaces" (D.dict D.string), D.succeed Dict.empty ]))
        |> D.andThen (\model ->
            D.map2 (\nodes threads -> List.length nodes == Dict.size model.nodes && List.length threads == Dict.size model.threads)
                (D.field "nodes" (D.list nodeDecoder)) (D.field "threads" (D.list threadDecoder))
                |> D.andThen (\unique -> if unique then D.succeed model else D.fail "Duplicate graph or thread IDs"))

valid : Model -> Bool
valid model =
    let
        acyclic id seen =
            if List.member id seen then False else
                case Dict.get id model.nodes of
                    Nothing -> False
                    Just node -> Maybe.map (\parent -> acyclic parent (id :: seen)) node.parentId |> Maybe.withDefault True
        nodeValid n = Dict.member n.threadId model.threads && acyclic n.id [] && List.all (\r -> Dict.member r model.nodes) n.refs
        threadValid thread = Dict.member thread.head model.nodes && (thread.forkedFrom |> Maybe.map (\id -> List.any (\n -> n.id == id) (ancestry model thread.head)) |> Maybe.withDefault True)
    in
    List.all nodeValid (Dict.values model.nodes) && List.all threadValid (Dict.values model.threads) && List.all (\id -> (String.dropLeft 1 id |> String.toInt |> Maybe.withDefault 0) <= model.seq) (Dict.keys model.nodes ++ Dict.keys model.threads)
