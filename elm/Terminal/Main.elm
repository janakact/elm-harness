port module Terminal.Main exposing (main)

import App.Public as Public
import App.RunStatus as Status
import Policy
import Commands
import Dict
import Graph
import Json.Decode as D
import Json.Encode as E
import Platform
import Rich
import Runner.View as JobView
import Runner.Types as Jobs
import User
import Time
import Task
import App.DateTime as DateTime
import App.Ui as Ui
import Terminal.Screen as Screen

port incoming : (E.Value -> msg) -> Sub msg
port outgoing : E.Value -> Cmd msg

type Pane = Compose | Chats | History | Permissions

type alias Model =
    { agentSubmission : Maybe JobView.Pending, agentSeq : Int, zone : Time.Zone, core : Public.Model, selected : String, focused : String, runs : List Public.Run
    , error : String, pendingNew : Bool, pendingFork : Bool, ready : Bool
    , columns : Int, rows : Int, pane : Pane, draft : String, cursor : Int
    , scroll : Int, inspect : Bool, help : Bool, permissionIndex : Int
    , clientId : String, workspaceToken : String, workspaceSeq : Int, info : String, launchPath : String, launchFresh : Bool, user : User.Model, pluginError : String, compactions : Dict.Dict String Public.SummaryDraft
    }

type Msg = GotZone Time.Zone | Incoming E.Value

init : E.Value -> ( Model, Cmd Msg )
init flags =
    let model = { agentSubmission = Nothing, agentSeq = 0, zone = Time.utc, core = Public.init, selected = "n1", focused = "t1", runs = [], error = "Connecting to Elm backend…", pendingNew = False, pendingFork = False, ready = False, columns = 100, rows = 30, pane = Compose, draft = "", cursor = 0, scroll = 0, inspect = False, help = False, permissionIndex = 0, clientId = field "clientId" flags, workspaceToken = "", workspaceSeq = 0, info = "", launchPath = field "workspace" flags, launchFresh = D.decodeValue (D.field "newChat" D.bool) flags |> Result.withDefault False, user = User.init, pluginError = "", compactions = Dict.empty }
    in ( model, Cmd.batch [ render model, Task.perform GotZone Time.here ] )

field : String -> E.Value -> String
field fieldName value = D.decodeValue (D.field fieldName D.string) value |> Result.withDefault ""

str : String -> String -> ( String, E.Value )
str fieldName content = ( fieldName, E.string content )

send : String -> List ( String, E.Value ) -> Cmd Msg
send kind fields = outgoing (E.object [ ( "type", E.string "Action" ), ( "data", E.object (str "type" kind :: fields) ) ])

finish : Model -> Cmd Msg -> ( Model, Cmd Msg )
finish model command = ( model, Cmd.batch [ render model, command ] )

threads : Model -> List Public.Thread
threads model = Public.conversations model.core

nodes : Model -> List Public.Node
nodes model =
    let
        walk id seen acc =
            if List.member id seen then acc else
            case Dict.get id model.core.nodes of
                Nothing -> acc
                Just node -> case node.parentId of
                    Nothing -> node :: acc
                    Just parent -> walk parent (id :: seen) (node :: acc)
    in Dict.get model.focused model.core.threads |> Maybe.map (\t -> walk t.head [] []) |> Maybe.withDefault []

history : Model -> List Public.Node
history model = List.reverse (nodes model)

activeRuns : Model -> List Public.Run
activeRuns model = model.runs |> List.filter (\r -> r.threadId == model.focused && Status.active r.status)

permissions : Model -> List Public.Node
permissions model =
    let
        pending = activeRuns model |> List.concatMap (\r -> r.pending)
    in Public.pendingApprovals model.focused pending model.core

focus : String -> Model -> Model
focus id model =
    case Dict.get id model.core.threads of
        Nothing -> { model | error = "Chat not found" }
        Just thread -> { model | focused = id, selected = thread.head, scroll = 0, inspect = False, permissionIndex = 0 }

cycle : Int -> String -> List String -> String
cycle offset current items =
    let index = List.indexedMap Tuple.pair items |> List.filter (\( _, id ) -> id == current) |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault 0
    in List.drop (modBy (max 1 (List.length items)) (index + offset)) items |> List.head |> Maybe.withDefault current

move : Int -> Model -> Model
move delta model =
    case model.pane of
        Chats -> focus (cycle delta model.focused (List.map .id (threads model))) model
        History -> { model | selected = cycle delta model.selected (List.map .id (history model)), scroll = 0 }
        Permissions -> { model | permissionIndex = clamp 0 (max 0 (List.length (permissions model) - 1)) (model.permissionIndex + delta), scroll = 0 }
        Compose -> { model | scroll = max 0 (model.scroll + delta * 3) }

insert : String -> Model -> Model
insert source model =
    let text = Screen.clean source |> String.left (max 0 (100000 - String.length model.draft))
    in { model | draft = String.left model.cursor model.draft ++ text ++ String.dropLeft model.cursor model.draft, cursor = model.cursor + String.length text }

approve : Bool -> Model -> ( Model, Cmd Msg )
approve allowed model =
    case List.drop model.permissionIndex (permissions model) |> List.head of
        Nothing -> finish { model | error = "No pending approval in this chat" } Cmd.none
        Just node ->
            let id = D.decodeString (D.field "id" D.string) node.text |> Result.withDefault ""
            in finish model (send "Approve" [ str "threadId" model.focused, str "callId" id, ( "allowed", E.bool allowed ) ])

newChat : String -> Model -> ( Model, Cmd Msg )
newChat title model =
    if not model.ready || model.pendingNew then finish model Cmd.none else
    finish { model | pendingNew = True, pane = Compose, inspect = False, help = False, scroll = 0 } (send "NewChat" [ str "title" title, str "model" (Dict.get model.focused model.core.threads |> Maybe.map .model |> Maybe.withDefault "deepseek/deepseek-v4-flash"), str "workspace" (workspace model) ])

workspace : Model -> String
workspace model = Dict.get model.focused model.core.threads |> Maybe.map .workspace |> Maybe.withDefault model.core.defaultWorkspace

executeIntent : Commands.Intent -> Model -> ( Model, Cmd Msg )
executeIntent intent model =
    let next = { model | draft = "", cursor = 0, error = "", scroll = 0, inspect = False, help = False, info = "" }
        show source = finish { next | help = True, info = source } Cmd.none
    in
    case intent of
        Commands.Workspace path fresh title ->
            let token = String.fromInt (model.workspaceSeq + 1) in
            finish { next | workspaceToken = token, workspaceSeq = model.workspaceSeq + 1 } (send "OpenWorkspace" [ str "path" path, ( "newChat", E.bool fresh ), str "title" title, str "model" (Dict.get model.focused model.core.threads |> Maybe.map .model |> Maybe.withDefault "deepseek/deepseek-v4-flash"), str "token" token ])
        Commands.Action payload ->
            let kind = field "type" payload
                isAgent = List.member kind [ "StartJob", "ResumeJob" ]
                id = model.clientId ++ ":agent:" ++ String.fromInt (model.agentSeq + 1)
                existing = model.core.jobs |> List.filter (\job -> job.id == field "jobId" payload) |> List.head
                backend = if kind == "ResumeJob" then existing |> Maybe.map (.backend >> Jobs.backendName) |> Maybe.withDefault "agent" else field "backend" payload
                threadId = if kind == "ResumeJob" then existing |> Maybe.map .threadId |> Maybe.withDefault model.focused else model.focused
                submission = { id = id, threadId = threadId, backend = backend, prompt = field "text" payload, fromComposer = True }
                request = if isAgent then D.decodeValue (D.dict D.value) payload |> Result.withDefault Dict.empty |> Dict.insert "actionId" (E.string id) |> E.dict identity identity else payload
            in finish { next | pendingNew = kind == "NewChat", pendingFork = kind == "Fork", agentSubmission = if isAgent then Just submission else model.agentSubmission, agentSeq = if isAgent then model.agentSeq + 1 else model.agentSeq } (outgoing (E.object [ str "type" "Action", ( "data", request ) ]))
        Commands.Local name argument ->
            case name of
                "help" -> show ""
                "agents" -> finish { next | help = True, info = "EXTERNAL AGENT JOBS" } Cmd.none
                "history" -> finish { next | pane = History, help = False } Cmd.none
                "chats" -> finish { next | pane = Chats, help = False } Cmd.none
                "workspace" -> show ("CURRENT WORKSPACE\n\n" ++ workspace model ++ "\n\n/workspace PATH switches to another directory.\n/new --workspace PATH [TITLE] starts a separate chat there.\nQuote paths containing spaces.")
                "workspaces" -> show ("OPENED WORKSPACES\n\n" ++ String.join "\n\n" (Dict.keys model.core.workspaces |> List.map (\root -> root ++ "\n  " ++ (Dict.values model.core.threads |> List.filter (\thread -> thread.workspace == root) |> List.map (\thread -> thread.id ++ " " ++ thread.title) |> String.join " · "))) ++ "\n\n/workspace PATH opens or switches workspace.\n/new --workspace PATH [TITLE] starts a new chat.")
                "permissions" -> show ("THIS CHAT’S TOOL PERMISSIONS\n\n" ++ (Dict.get model.focused model.core.threads |> Maybe.map (.policy >> Policy.description) |> Maybe.withDefault "") ++ "\n\n/permissions read-only\n/permissions ask\n/permissions TOOL allow|ask|deny\n\nBash can inspect workspace files. When write is denied its workspace is mounted read-only. Allowing bash without asking permits shell actions inside that sandbox.")
                "usage" -> show (Public.contextReport model.core model.focused)
                "context" -> show (Public.contextReport model.core model.focused ++ "\n\n/budget TOKENS sets the input estimate budget.\n/compact generates a summary for review. Original nodes are retained.")
                "compaction" -> show (compactionText model)
                "prompt" -> show ("EFFECTIVE SYSTEM PROMPT\n\n" ++ (Dict.get model.focused model.core.threads |> Maybe.map .prompt |> Maybe.withDefault ""))
                "model" -> show ("MODEL\n\n" ++ (Dict.get model.focused model.core.threads |> Maybe.map .model |> Maybe.withDefault "") ++ "\n\n/model MODEL changes this chat's model.")
                "status" -> show ("CHAT STATUS\n\n" ++ (Dict.get model.focused model.core.threads |> Maybe.map .title |> Maybe.withDefault "") ++ "\nWorkspace: " ++ workspace model ++ "\nModel: " ++ (Dict.get model.focused model.core.threads |> Maybe.map .model |> Maybe.withDefault "") ++ "\nRuns: " ++ (model.runs |> List.filter (\run -> run.threadId == model.focused) |> List.map (.status >> Status.name) |> String.join ", "))
                "focus" -> case threads model |> List.filter (\thread -> thread.id == argument || thread.title == argument) |> List.head of
                    Just thread -> finish (focus thread.id next) Cmd.none
                    Nothing -> finish { model | error = "Chat not found" } Cmd.none
                "select" -> if List.any (\node -> node.id == argument) (nodes model) then finish { next | selected = argument, pane = History, inspect = True } Cmd.none else finish { model | error = "Node is outside the current chat" } Cmd.none
                "quit" -> finish next (outgoing (E.object [ str "type" "Quit" ]))
                _ -> show Commands.help

submit : Model -> ( Model, Cmd Msg )
submit model =
    if not model.ready || String.isEmpty (String.trim model.draft) then finish model Cmd.none else
    case Commands.parse { threadId = model.focused, nodeId = model.selected, modelName = Dict.get model.focused model.core.threads |> Maybe.map .model |> Maybe.withDefault "deepseek/deepseek-v4-flash", workspace = workspace model, policy = Dict.get model.focused model.core.threads |> Maybe.map .policy |> Maybe.withDefault Policy.default, summaryRequest = Dict.get model.focused model.compactions |> Maybe.map .requestId |> Maybe.withDefault "" } model.draft of
        Err problem -> finish { model | error = problem } Cmd.none
        Ok intent -> executeIntent intent model

previousCursor : Model -> Int
previousCursor model = model.cursor - (String.left model.cursor model.draft |> String.toList |> List.reverse |> List.head |> Maybe.map (String.fromChar >> String.length) |> Maybe.withDefault 0)

nextCursor : Model -> Int
nextCursor model = model.cursor + (String.dropLeft model.cursor model.draft |> String.toList |> List.head |> Maybe.map (String.fromChar >> String.length) |> Maybe.withDefault 0)

key : String -> Model -> ( Model, Cmd Msg )
key pressed model =
    case pressed of
        "f7" -> finish { model | help = True, inspect = False, info = "EXTERNAL AGENT JOBS" } Cmd.none
        "f6" -> finish { model | help = True, inspect = False, info = "SESSION PLUGIN\n\n" ++ String.join "\n" (Ui.lines (if String.isEmpty model.pluginError then User.inspector model.core model.user else Ui.Text model.pluginError)) ++ "\n\n1: toggle count · 2: reset count · 3: new chat" } Cmd.none
        "ctrl+n" -> newChat "" model
        "ctrl+x" -> finish model (Cmd.batch (List.map (\r -> send "Cancel" [ str "runId" (r.id) ]) (activeRuns model)))
        "ctrl+r" -> finish model (send "Run" [ str "threadId" model.focused ])
        "ctrl+l" -> finish model Cmd.none
        "f1" -> finish { model | help = not model.help, info = "" } Cmd.none
        "f2" -> finish { model | pane = Chats, inspect = False } Cmd.none
        "f3" -> finish { model | pane = History, inspect = False } Cmd.none
        "ctrl+g" -> finish { model | pane = History, inspect = False } Cmd.none
        "f4" -> finish { model | pane = Compose, inspect = False, help = False } Cmd.none
        "f5" -> finish { model | pane = Permissions, scroll = 0, inspect = False } Cmd.none
        "tab" -> if model.pane == Compose && String.startsWith "/" model.draft && not (String.contains " " model.draft) then let completed = Commands.complete model.draft in finish { model | draft = completed, cursor = String.length completed } Cmd.none else finish { model | pane = case model.pane of
            Compose -> Chats
            Chats -> History
            History -> if List.isEmpty (permissions model) then Compose else Permissions
            Permissions -> Compose, inspect = False, scroll = 0 } Cmd.none
        "escape" -> finish { model | pane = Compose, help = False, inspect = False, scroll = 0 } Cmd.none
        "up" -> finish (move -1 model) Cmd.none
        "down" -> finish (move 1 model) Cmd.none
        "pageup" -> finish { model | scroll = if model.inspect || model.help || model.pane == Permissions then max 0 (model.scroll - max 1 (model.rows - 12)) else model.scroll + max 1 (model.rows - 12) } Cmd.none
        "pagedown" -> finish { model | scroll = if model.inspect || model.help || model.pane == Permissions then model.scroll + max 1 (model.rows - 12) else max 0 (model.scroll - max 1 (model.rows - 12)) } Cmd.none
        "return" -> case model.pane of
            Compose -> submit model
            History -> finish { model | inspect = True, scroll = 0 } Cmd.none
            Chats -> finish { model | pane = Compose, inspect = False } Cmd.none
            Permissions -> finish model Cmd.none
        "alt+return" -> finish (insert "\n" model) Cmd.none
        "left" -> finish { model | cursor = previousCursor model } Cmd.none
        "right" -> finish { model | cursor = nextCursor model } Cmd.none
        "home" -> finish { model | cursor = 0 } Cmd.none
        "ctrl+a" -> finish { model | cursor = 0 } Cmd.none
        "end" -> finish { model | cursor = String.length model.draft } Cmd.none
        "ctrl+e" -> finish { model | cursor = String.length model.draft } Cmd.none
        "ctrl+u" -> finish { model | draft = String.dropLeft model.cursor model.draft, cursor = 0 } Cmd.none
        "ctrl+k" -> finish { model | draft = String.left model.cursor model.draft } Cmd.none
        "backspace" -> if model.cursor == 0 then finish model Cmd.none else finish { model | draft = String.left (previousCursor model) model.draft ++ String.dropLeft model.cursor model.draft, cursor = previousCursor model } Cmd.none
        "delete" -> finish { model | draft = String.left model.cursor model.draft ++ String.dropLeft (nextCursor model) model.draft } Cmd.none
        _ -> finish model Cmd.none

update : Msg -> Model -> ( Model, Cmd Msg )
update message model = case message of
    GotZone zone -> finish { model | zone = zone } Cmd.none
    Incoming event -> incomingEvent event model

incomingEvent : E.Value -> Model -> ( Model, Cmd Msg )
incomingEvent event model =
    case field "type" event of
        "ActionResult" ->
            if D.decodeValue (D.at [ "data", "clientId" ] D.string) event /= Ok model.clientId then finish model Cmd.none else
            case D.decodeValue (D.field "data" Public.resultDecoder) event of
                Ok (Public.Rejected id reason) -> finish { model | error = reason, pendingNew = False, pendingFork = False, agentSubmission = if (model.agentSubmission |> Maybe.map .id) == Just id then Nothing else model.agentSubmission } Cmd.none
                Ok (Public.Accepted id) -> finish { model | agentSubmission = if (model.agentSubmission |> Maybe.map .id) == Just id then Nothing else model.agentSubmission } Cmd.none
                _ -> finish model Cmd.none
        "Snapshot" ->
            case D.decodeValue (D.field "data" Public.snapshotDecoder) event of
                Err problem -> finish { model | error = D.errorToString problem, ready = False } Cmd.none
                Ok projection ->
                    let
                        core = projection.core
                        runs = projection.runs
                        error = projection.error
                        created = if model.pendingNew || model.pendingFork then Dict.values core.threads |> List.filter (\t -> not (Dict.member t.id model.core.threads)) |> List.head else Nothing
                        first = if not model.ready && Dict.member core.focused core.threads then core.focused else model.focused
                        incomingModel = { model | core = core, pluginError = D.decodeValue (D.at [ "data", "pluginError" ] D.string) event |> Result.withDefault "", user = D.decodeValue (D.at [ "data", "extension" ] User.decoder) event |> Result.withDefault model.user, runs = runs, error = error, ready = String.isEmpty error, compactions = D.decodeValue (D.at [ "data", "compactions" ] (D.dict Public.summaryDecoder)) event |> Result.withDefault Dict.empty }
                        navigation = D.decodeValue (D.at [ "data", "navigations", model.clientId ] (D.map3 (\token threadId problem -> ( token, threadId, problem )) (D.field "token" D.string) (D.field "threadId" D.string) (D.field "error" D.string))) event |> Result.toMaybe
                        matched = navigation |> Maybe.map (\( token, _, _ ) -> not (String.isEmpty model.workspaceToken) && token == model.workspaceToken) |> Maybe.withDefault False
                        navigated = if matched then
                            case navigation of
                                Just ( _, id, problem ) -> if String.isEmpty problem then focus id { incomingModel | workspaceToken = "" } else { incomingModel | workspaceToken = "", error = problem }
                                Nothing -> incomingModel
                            else incomingModel
                        next = case created of
                            Just thread -> focus thread.id { navigated | pendingNew = False, pendingFork = False }
                            Nothing -> if not model.ready && not matched then focus first navigated else navigated
                        finished = { next | permissionIndex = clamp 0 (max 0 (List.length (permissions next) - 1)) next.permissionIndex }
                    in if not (String.isEmpty model.launchPath) && finished.ready then executeIntent (Commands.Workspace model.launchPath model.launchFresh "") { finished | launchPath = "" } else finish finished Cmd.none
        "Resize" -> finish { model | columns = D.decodeValue (D.field "columns" D.int) event |> Result.withDefault 80 |> clamp 1 400, rows = D.decodeValue (D.field "rows" D.int) event |> Result.withDefault 24 |> clamp 1 160 } Cmd.none
        "Network" -> finish { model | error = field "error" event, agentSubmission = Nothing } Cmd.none
        "Key" -> key (field "key" event) model
        "Paste" -> finish (insert (field "text" event) { model | pane = Compose }) Cmd.none
        "Text" ->
            let value = field "text" event in
            if model.help && String.startsWith "SESSION PLUGIN" model.info && List.member value [ "1", "2", "3" ] then
                let message = if value == "1" then User.ToggleCount else if value == "2" then User.ResetCount else User.StartChat
                in finish { model | pendingNew = message == User.StartChat, help = False } (outgoing (E.object [ str "type" "Action", ( "data", User.encodeMsg model.focused message ) ]))
            else if model.pane == Permissions then if String.toLower value == "y" then approve True model else if String.toLower value == "n" then approve False model else finish model Cmd.none
            else if model.pane == Compose then finish (insert value model) Cmd.none else finish model Cmd.none
        "Line" -> submit { model | draft = field "line" event, cursor = String.length (field "line" event), pane = Compose }
        _ -> finish model Cmd.none

compactionText : Model -> String
compactionText model =
    case Dict.get model.focused model.compactions of
        Nothing -> "No context summary preview. Use /compact to generate one."
        Just draft -> "CONTEXT SUMMARY · " ++ draft.status ++ "\nEstimated input before: ~" ++ String.fromInt draft.before ++ " tokens; after generated summary: ~" ++ String.fromInt draft.after ++ "\n" ++ draft.error ++ "\n\n" ++ draft.text ++ "\n\nReview with /compact preview (PgUp/PgDn scroll).\n/compact apply accepts this summary; /compact apply REPLACEMENT applies edited text.\n/compact discard keeps the original context. No history nodes are deleted."

pretty : String -> String
pretty source = D.decodeString D.value source |> Result.map (E.encode 2) |> Result.withDefault source

nodeText : Public.Node -> String
nodeText node = if node.kind == "ToolResult" then D.decodeString (D.field "content" D.string) node.text |> Result.withDefault node.text else if List.member node.kind [ "ToolCall", "Approval" ] then pretty node.text else Rich.terminal node.text

window : Int -> Int -> List String -> List String
window height offset lines = lines |> List.drop (max 0 (List.length lines - height - offset)) |> List.take height

around : Int -> Int -> List String -> List String
around height index lines = lines |> List.drop (max 0 (min (max 0 (List.length lines - height)) (index - height // 2))) |> List.take height

indexOf : String -> List String -> Int
indexOf id items = items |> List.indexedMap Tuple.pair |> List.filter (\( _, item ) -> item == id) |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault 0

render : Model -> Cmd Msg
render model =
    let
        columns = model.columns
        height = max 1 (model.rows - 9)
        wide = columns >= 105
        leftWidth = if wide then 20 else 0
        rightWidth = if columns >= 140 then 23 else 0
        centerWidth = max 10 (columns - leftWidth - rightWidth - (if leftWidth > 0 then 3 else 0) - (if rightWidth > 0 then 3 else 0))
        current = Dict.get model.focused model.core.threads
        currentTitle = Maybe.map .title current |> Maybe.withDefault "Chat"
        modelName = Maybe.map .model current |> Maybe.withDefault ""
        allNodes = nodes model
        graphNodes = history model
        messageCount = allNodes |> List.filter (\n -> List.member n.kind [ "UserMessage", "AgentMessage", "Handoff", "RunnerResult" ]) |> List.length
        nativeStatus = model.runs |> List.filter (\r -> r.threadId == model.focused) |> List.reverse |> List.head |> Maybe.map .status |> Maybe.withDefault Status.Idle
        currentStatus = if Status.active nativeStatus then Status.name nativeStatus else JobView.activity model.focused model.agentSubmission model.core.jobs |> Maybe.withDefault (Status.name nativeStatus)
        chatLines = threads model |> List.concatMap (\t -> [ (if t.id == model.focused then "› " else "  ") ++ Screen.clean t.title, "  " ++ DateTime.date model.zone t.updatedAt ])
        chatIndex = 2 * indexOf model.focused (List.map .id (threads model))
        graphLine n = (if n.id == model.selected then "› " else "  ") ++ (if List.member n.kind [ "ToolCall", "ToolResult" ] then "◆ " else "● ") ++ Graph.label n
        graphLines = List.map graphLine graphNodes
        graphIndex = indexOf model.selected (List.map .id graphNodes)
        selectedNode = Dict.get model.selected model.core.nodes
        transcriptNode n =
            if List.member n.kind [ "Activity", "Approval" ] then [] else
            let source = nodeText n
                messageBody = Screen.markdown (centerWidth - 4) source
                bounded = if List.member n.kind [ "ToolCall", "ToolResult" ] && List.length messageBody > 6 then List.take 6 messageBody ++ [ "… full output: F3, select Tool, Enter" ] else messageBody
            in [ "", "  " ++ Graph.label n ] ++ List.map ((++) "  ") bounded
        drafts = activeRuns model |> List.filter (\r -> r.purpose /= "compaction" && not (String.isEmpty (r.draft))) |> List.concatMap (\r -> [ "", "  Chat · Assistant · streaming" ] ++ Screen.markdown (centerWidth - 4) (r.draft))
        agentJobs = model.core.jobs |> List.filter (\job -> job.threadId == model.focused && (Jobs.active job.status || not (List.any (\node -> node.kind == "RunnerResult" && JobView.matchesResult job node.text) allNodes))) |> List.reverse |> List.concatMap (\job -> [ "", "  Agent · " ++ Jobs.backendName job.backend ++ " · " ++ job.id ++ " · " ++ Jobs.statusName job.status ] ++ Screen.markdown (centerWidth - 4) (JobView.progress job ++ "\n\n" ++ job.output ++ (if String.isEmpty job.error then "" else "\n\n" ++ job.error)))
        pending = model.agentSubmission |> Maybe.map (\submission -> if submission.threadId == model.focused then "" :: Screen.markdown (centerWidth - 4) (JobView.pendingText submission) else []) |> Maybe.withDefault []
        transcript = List.concatMap transcriptNode allNodes ++ drafts ++ agentJobs ++ pending ++ (if Dict.member model.focused model.compactions then "" :: Screen.markdown (centerWidth - 4) (compactionText model) else [])
        detail = [ "  " ++ (Maybe.map Graph.label selectedNode |> Maybe.withDefault "Select a node"), "" ] ++ (selectedNode |> Maybe.map (nodeText >> Screen.markdown (centerWidth - 2)) |> Maybe.withDefault []) ++ [ "" ] ++ Ui.lines (if String.isEmpty model.pluginError then User.inspector model.core model.user else Ui.Text model.pluginError)
        approvals = permissions model
        approval = List.drop model.permissionIndex approvals |> List.head
        approvalLines = [ "PERMISSION REVIEW", "", "y: allow once   n: deny   ↑/↓: choose", "Writes change your files; bash uses the workspace sandbox.", "" ] ++ (approval |> Maybe.map (\n -> Screen.markdown centerWidth (pretty n.text)) |> Maybe.withDefault [ "No pending permissions in this chat." ])
        helpLines = Screen.markdown centerWidth (if model.info == "EXTERNAL AGENT JOBS" then JobView.overview model.focused model.core.jobs ++ "\n\n" ++ (Dict.toList model.core.runnerCapabilities |> List.map (\( name, cap ) -> name ++ ": " ++ (if cap.available then cap.version else cap.error)) |> String.join "\n") else if not (String.isEmpty model.info) then model.info else "ELM HARNESS — KEYBOARD\n\nTab              Switch pane\nF2 / F3 / F4     Chats / History / Composer\nF7               External agent jobs\nF6               Session plugin\nF5               Review tool permissions (y allow / n deny)\n↑ / ↓            Navigate chats/history; scroll conversation\nEnter in history Open full selected message or tool result\nPageUp/PageDown  Scroll content\nEsc              Return to conversation and composer\nCtrl+N           New empty chat\nCtrl+R           Resume current chat\nCtrl+X           Stop current run\nCtrl+C / Ctrl+Q  Quit terminal (backend keeps running)\nEnter            Send prompt\nAlt+Enter        Insert a line break\nBracketed paste  Insert multiline text without submitting\nHome/End, ←/→    Edit composer\nCtrl+U / Ctrl+K  Delete before / after cursor\n\n/new [TITLE]\n/fork [TITLE]     Fork from selected history node\n/model MODEL\n/send THREAD MESSAGE\n/compact SUMMARY\n/approve CALL /deny CALL /cancel RUN\n/help /quit\n\n" ++ Commands.help)
        paneContent = if model.help then helpLines else if model.pane == Permissions then approvalLines else if model.inspect then detail else transcript
        bodyCenter = if not wide && model.pane == Chats && not model.help then [ "CHATS — ↑/↓ choose · Enter to compose", "" ] ++ around (height - 2) chatIndex chatLines else if rightWidth == 0 && model.pane == History && not model.inspect && not model.help then [ "HISTORY — ↑/↓ choose · Enter to inspect", "" ] ++ around (height - 2) graphIndex graphLines else window height (if model.inspect || model.help || model.pane == Permissions then max 0 (List.length paneContent - height - model.scroll) else model.scroll) paneContent
        left = [ (if model.pane == Chats then "› CHATS" else "  CHATS"), "" ] ++ around (max 1 (height - 7)) chatIndex chatLines ++ [ "" ] ++ Ui.lines (if String.isEmpty model.pluginError then User.sidebar model.core model.user else Ui.Text "Session plugin disabled")
        right = [ (if model.pane == History then "› HISTORY" else "  HISTORY"), "" ] ++ around (height - 2) graphIndex graphLines
        body = Screen.joinColumns leftWidth left centerWidth bodyCenter rightWidth right height
        separator = Screen.paint "38;5;239" (String.repeat columns "─")
        titleLine = Screen.paint "1;38;5;153" (Screen.pad columns (" λ elm  │  " ++ Screen.clean currentTitle ++ "  ·  " ++ String.fromInt messageCount ++ " messages  ·  " ++ currentStatus))
        notice = if not (String.isEmpty model.error) then model.error else if not (List.isEmpty approvals) then String.fromInt (List.length approvals) ++ " approval(s) waiting · F5 to review" else if not (String.isEmpty model.workspaceToken) then "Opening workspace…" else if String.startsWith "/" model.draft && not (String.contains " " model.draft) then "Tab complete · " ++ (Commands.catalog |> List.filter (\entry -> String.startsWith model.draft entry.name) |> List.take 5 |> List.map .name |> String.join "  ") else if Dict.member model.focused model.compactions then "Context summary · /compact preview · /compact apply · /compact discard" else "Tab panes · F1 help · Ctrl+N new chat · Ctrl+X stop · Ctrl+C quit"
        draftWidth = max 1 (columns - 4)
        prefixLines = Screen.wrap draftWidth (String.left model.cursor model.draft)
        cursorLine = List.length prefixLines - 1
        draftLines = Screen.wrap draftWidth model.draft
        start = max 0 (cursorLine - 2)
        composerLines = draftLines |> List.drop start |> List.take 3
        composeRows = List.range 0 2 |> List.map (\i -> Screen.pad columns ((if i == 0 then " › " else "   ") ++ (List.drop i composerLines |> List.head |> Maybe.withDefault "")))
        cursorColumn = min columns (4 + (List.reverse prefixLines |> List.head |> Maybe.map Screen.width |> Maybe.withDefault 0))
        cursorRow = model.rows - 4 + clamp 0 2 (cursorLine - start)
        footer = if model.pane == Compose then "Enter send · Alt+Enter newline · " ++ modelName ++ " · " ++ (Dict.get model.focused model.core.threads |> Maybe.map (\thread -> "ctx ~" ++ String.fromInt (thread.estimatedInput) ++ "/" ++ String.fromInt thread.contextBudget) |> Maybe.withDefault "") else "Pane: " ++ (case model.pane of
            Chats -> "Chats · ↑/↓ navigate · Enter compose"
            History -> "History · ↑/↓ navigate · Enter details"
            Permissions -> "Permissions · y allow once · n deny · PgUp/PgDn scroll"
            Compose -> "Composer")
        frame = [ titleLine, Screen.paint "38;5;245" (Screen.pad columns (Screen.clean notice)), separator ] ++ body ++ [ separator ] ++ composeRows ++ [ Screen.paint "38;5;245" (Screen.pad columns footer), Screen.paint "38;5;239" (Screen.pad columns ("Workspace: " ++ workspace model ++ " · /workspace PATH · /new --workspace PATH")) ]
    in outgoing (E.object [ str "type" "Draw", str "text" (String.join "\n" (if columns < 40 || model.rows < 12 then List.range 1 model.rows |> List.map (\row -> Screen.pad columns (if row == 1 then "Resize terminal to at least 40 × 12" else "")) else frame)), ( "cursor", E.object [ ( "row", E.int cursorRow ), ( "column", E.int cursorColumn ), ( "visible", E.bool (model.pane == Compose && columns >= 40 && model.rows >= 12) ) ] ) ])

main : Program E.Value Model Msg
main = Platform.worker { init = init, update = update, subscriptions = \_ -> incoming Incoming }
