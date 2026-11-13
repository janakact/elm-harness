port module Main exposing (main)

import Browser
import Browser.Dom
import Time
import App.DateTime as DateTime
import Task
import StateViewer
import App.Public as Public
import App.RunStatus as Status
import Policy
import Accounting
import Commands
import Dict
import Graph
import Html exposing (Html, button, div, header, input, main_, option, pre, select, span, text, textarea)
import Html.Attributes exposing (class, disabled, placeholder, title, value)
import Html.Events exposing (onClick, onInput, preventDefaultOn)
import Html.Keyed as Keyed
import Json.Decode as D
import Json.Encode as E
import Rich
import Runner.Types as Jobs
import Runner.View as JobView
import User
import App.Ui as Ui

port snapshot : (E.Value -> msg) -> Sub msg
port actionResult : (E.Value -> msg) -> Sub msg
port network : (String -> msg) -> Sub msg
port action : E.Value -> Cmd msg
port ui : E.Value -> Cmd msg
port uiResult : (E.Value -> msg) -> Sub msg

type alias Run = Public.Run
type alias Model = { agentSubmission : Maybe JobView.Pending, agentCustomModel : String, agentPending : String, agentSeq : Int, showAgents : Bool, agentBackend : String, agentPrompt : String, agentModel : String, agentResume : String, core : Public.Model, runs : List Run, selected : String, focused : String, compose : String, branch : String, target : String, delivery : String, modelName : String, filter : String, error : String, ready : Bool, pendingNew : Bool, prompt : String, showSettings : Bool, showWorkspace : Bool, zone : Time.Zone, showInspector : Bool, count : Int, clientId : String, workspaceToken : String, workspaceSeq : Int, workspaceInput : String, showCommands : Bool, info : String, drafts : Dict.Dict String String, backendState : E.Value, showState : Bool, stateViewer : StateViewer.Model, copyStatus : String, policyEdit : Policy.Model, budgetInput : String, compactions : Dict.Dict String Public.SummaryDraft, summaryEdit : String, summaryRequest : String, notice : String, user : User.Model, pluginError : String }
type Msg = Agents | AgentBackend String | AgentPrompt String | AgentModel String | AgentCustomModel String | StartAgent | ResumeAgent String | GotZone Time.Zone | Workspaces | ClosePanels | ActionResult E.Value | UserMsg User.Msg | Snapshot E.Value | Network String | Select String | Focus String | Compose String | Branch String | Target String | Delivery String | ModelName String | Filter String | Settings | Inspector | Send E.Value | Submit | NewChat | Fork | Deliver | Compact | Key String Bool | WorkspaceInput String | OpenWorkspace Bool | SwitchWorkspace String | CommandsMenu | ChooseCommand String | ComposerFocused (Result Browser.Dom.Error ()) | ToggleState | CloseState | RefreshState | StateViewMsg StateViewer.Msg | CopyState | UiResult E.Value | NoOp | PolicyField String String | ApplyPolicy | BudgetInput String | ApplyBudget | AssistCompact | SummaryEdit String | ApplySummary | DiscardSummary

init : E.Value -> ( Model, Cmd Msg )
init flags = ( { agentSubmission = Nothing, agentCustomModel = "", agentPending = "", agentSeq = 0, showAgents = False, agentBackend = "codex", agentPrompt = "", agentModel = "", agentResume = "", core = Public.init, runs = [], selected = "n1", focused = "t1", compose = "", branch = "", target = "t1", delivery = "", modelName = "deepseek/deepseek-v4-flash", filter = "all", error = "", ready = False, pendingNew = False, prompt = "", showSettings = False, showWorkspace = False, zone = Time.utc, showInspector = False, count = 0, clientId = D.decodeValue (D.field "clientId" D.string) flags |> Result.withDefault "", workspaceToken = "", workspaceSeq = 0, workspaceInput = "", showCommands = False, info = "", drafts = Dict.empty, backendState = E.null, showState = False, stateViewer = StateViewer.init E.null, copyStatus = "", policyEdit = Policy.default, budgetInput = "50000", compactions = Dict.empty, summaryEdit = "", summaryRequest = "", notice = "", user = User.init, pluginError = "" }, Task.perform GotZone Time.here )

str : String -> String -> ( String, E.Value )
str key content = ( key, E.string content )
command : String -> List ( String, E.Value ) -> E.Value
command kind fields = E.object (str "type" kind :: fields)

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Agents -> ( { model | showAgents = True, showSettings = False, showWorkspace = False, showCommands = False }, Cmd.batch [ closePanel "chat-settings-dialog" False, closePanel "workspaces-dialog" False, openPanel "agents-dialog" "agent-prompt" ] )
        AgentBackend backend -> ( { model | agentBackend = backend, agentModel = "", agentCustomModel = "" }, Cmd.none )
        AgentPrompt prompt -> ( { model | agentPrompt = prompt }, Cmd.none )
        AgentModel modelName -> ( { model | agentModel = modelName }, Cmd.none )
        AgentCustomModel modelName -> ( { model | agentCustomModel = modelName }, Cmd.none )
        ResumeAgent id -> ( { model | showAgents = True, showSettings = False, showWorkspace = False, agentResume = id, agentPrompt = "" }, Cmd.batch [ closePanel "chat-settings-dialog" False, closePanel "workspaces-dialog" False, openPanel "agents-dialog" "agent-prompt" ] )
        StartAgent ->
            let payload = if String.isEmpty model.agentResume then command "StartJob" [ str "threadId" model.focused, str "backend" model.agentBackend, str "model" (selectedAgentModel model), str "text" model.agentPrompt ] else command "ResumeJob" [ str "jobId" model.agentResume, str "text" model.agentPrompt ]
            in submitAgent False payload model
        GotZone zone -> ( { model | zone = zone }, Cmd.none )
        ActionResult value ->
            if D.decodeValue (D.field "clientId" D.string) value /= Ok model.clientId then ( model, Cmd.none ) else
            case D.decodeValue Public.resultDecoder value of
                Ok (Public.Rejected id reason) -> ( { model | error = reason, pendingNew = False, agentPending = if id == model.agentPending then "" else model.agentPending, agentSubmission = if id == model.agentPending then Nothing else model.agentSubmission }, Cmd.none )
                Ok (Public.Accepted id) -> if id == model.agentPending then
                    let fromComposer = model.agentSubmission |> Maybe.map .fromComposer |> Maybe.withDefault False in
                    ( { model | agentPending = "", agentSubmission = Nothing, agentPrompt = if fromComposer then model.agentPrompt else "", agentResume = if fromComposer then model.agentResume else "" }, Cmd.none ) else ( model, Cmd.none )
                _ -> ( model, Cmd.none )
        UserMsg message ->
            ( { model | pendingNew = message == User.StartChat }, action (User.encodeMsg model.focused message) )
        Snapshot data ->
            let
                decoder = Public.snapshotDecoder
            in case D.decodeValue decoder data of
                Err e -> ( { model | error = D.errorToString e, ready = False }, Cmd.none )
                Ok projection ->
                    let
                        navigation = D.decodeValue (D.at [ "navigations", model.clientId ] (D.map3 (\token id error -> ( token, id, error )) (D.field "token" D.string) (D.field "threadId" D.string) (D.field "error" D.string))) data |> Result.toMaybe
                        matched = navigation |> Maybe.map (\( token, _, _ ) -> not (String.isEmpty model.workspaceToken) && token == model.workspaceToken) |> Maybe.withDefault False
                        target = if matched then navigation |> Maybe.map (\( _, id, _ ) -> id) |> Maybe.withDefault "" else ""
                        problem = if matched then navigation |> Maybe.map (\( _, _, error ) -> error) |> Maybe.withDefault "" else ""
                        created = if model.pendingNew then Dict.values projection.core.threads |> List.filter (\t -> not (Dict.member t.id model.core.threads)) |> List.head else Nothing
                        focused = if not (String.isEmpty target) then target else Maybe.map .id created |> Maybe.withDefault model.focused
                        thread = Dict.get focused projection.core.threads
                        root = Maybe.map .workspace thread |> Maybe.withDefault projection.core.defaultWorkspace
                        changed = focused /= model.focused
                        compactions = D.decodeValue (D.field "compactions" (D.dict Public.summaryDecoder)) data |> Result.withDefault Dict.empty
                        preview = Dict.get focused compactions
                        readyPreview = preview |> Maybe.andThen (\draft -> if draft.status == "Ready" then Just draft else Nothing)
                        newPreview = readyPreview |> Maybe.map (\draft -> draft.requestId /= model.summaryRequest) |> Maybe.withDefault False
                        oldThread = Dict.get model.focused model.core.threads
                        policyUnedited = oldThread |> Maybe.map (\old -> model.policyEdit == old.policy) |> Maybe.withDefault True
                        budgetUnedited = oldThread |> Maybe.map (\old -> model.budgetInput == String.fromInt old.contextBudget) |> Maybe.withDefault True
                    in
                    ( { model | pluginError = D.decodeValue (D.field "pluginError" D.string) data |> Result.withDefault "", user = D.decodeValue (D.field "extension" User.decoder) data |> Result.withDefault model.user, backendState = data, drafts = if changed && not model.pendingNew && String.isEmpty model.workspaceToken then rememberDraft model else model.drafts, compose = if changed then Dict.get focused model.drafts |> Maybe.withDefault "" else model.compose, compactions = compactions, summaryRequest = if preview == Nothing then "" else if changed || newPreview then readyPreview |> Maybe.map .requestId |> Maybe.withDefault "" else model.summaryRequest, summaryEdit = if preview == Nothing then "" else if changed || newPreview then readyPreview |> Maybe.map .text |> Maybe.withDefault "" else model.summaryEdit, policyEdit = if changed || not model.ready || policyUnedited then Maybe.map .policy thread |> Maybe.withDefault Policy.default else model.policyEdit, budgetInput = if changed || not model.ready || budgetUnedited then Maybe.map (.contextBudget >> String.fromInt) thread |> Maybe.withDefault "50000" else model.budgetInput, showAgents = if changed then False else model.showAgents, showSettings = if changed then False else model.showSettings, showWorkspace = if changed || (matched && String.isEmpty problem) then False else model.showWorkspace, core = projection.core, runs = projection.runs, prompt = thread |> Maybe.map .prompt |> Maybe.withDefault projection.prompt, error = if String.isEmpty projection.error then problem else projection.error, count = projection.count, ready = String.isEmpty projection.error, pendingNew = model.pendingNew && created == Nothing, focused = focused, selected = if changed then Maybe.map .head thread |> Maybe.withDefault model.selected else model.selected, workspaceToken = if matched then "" else model.workspaceToken, workspaceInput = if changed || String.isEmpty model.workspaceInput then root else model.workspaceInput, modelName = if changed then Maybe.map .model thread |> Maybe.withDefault model.modelName else model.modelName }, if not model.showState && (changed || (not model.ready && String.isEmpty projection.error) || (matched && String.isEmpty problem)) then Cmd.batch [ if changed then focusChat else focusComposer, if changed || (matched && String.isEmpty problem) then Cmd.batch [ closePanel "agents-dialog" True, closePanel "chat-settings-dialog" True, closePanel "workspaces-dialog" True ] else Cmd.none ] else Cmd.none )
        Network problem -> ( { model | error = problem, agentPending = "", agentSubmission = Nothing }, Cmd.none )
        Select id -> ( { model | selected = id, showInspector = True }, Cmd.none )
        Focus id ->
            let saved = rememberDraft model in
            ( { model | focused = id, policyEdit = Dict.get id model.core.threads |> Maybe.map .policy |> Maybe.withDefault Policy.default, budgetInput = Dict.get id model.core.threads |> Maybe.map (.contextBudget >> String.fromInt) |> Maybe.withDefault "50000", summaryRequest = Dict.get id model.compactions |> Maybe.map .requestId |> Maybe.withDefault "", summaryEdit = Dict.get id model.compactions |> Maybe.map .text |> Maybe.withDefault "", drafts = saved, compose = Dict.get id saved |> Maybe.withDefault "", showAgents = False, showSettings = False, showWorkspace = False, showCommands = False, workspaceInput = Dict.get id model.core.threads |> Maybe.map .workspace |> Maybe.withDefault model.workspaceInput, prompt = Dict.get id model.core.threads |> Maybe.map .prompt |> Maybe.withDefault model.prompt, selected = Dict.get id model.core.threads |> Maybe.map .head |> Maybe.withDefault model.selected, modelName = Dict.get id model.core.threads |> Maybe.map .model |> Maybe.withDefault model.modelName }, Cmd.batch [ focusChat, closePanel "agents-dialog" True, closePanel "chat-settings-dialog" True, closePanel "workspaces-dialog" True ] )
        Compose content -> ( { model | compose = content }, Cmd.none )
        Branch content -> ( { model | branch = content }, Cmd.none )
        Target id -> ( { model | target = id }, Cmd.none )
        Delivery content -> ( { model | delivery = content }, Cmd.none )
        ModelName content -> ( { model | modelName = content }, Cmd.none )
        Filter content -> ( { model | filter = content }, Cmd.none )
        Settings ->
            ( { model | showAgents = False, showSettings = True, showWorkspace = False, showCommands = False }, Cmd.batch [ closePanel "agents-dialog" False, closePanel "workspaces-dialog" False, openPanel "chat-settings-dialog" "chat-settings-model" ] )
        Workspaces ->
            ( { model | showAgents = False, showWorkspace = True, showSettings = False, showCommands = False, workspaceInput = workspace model }, Cmd.batch [ closePanel "agents-dialog" False, closePanel "chat-settings-dialog" False, openPanel "workspaces-dialog" "workspace-directory" ] )
        ClosePanels ->
            ( { model | showAgents = False, showWorkspace = False, showSettings = False }, Cmd.batch [ closePanel "agents-dialog" False, closePanel "chat-settings-dialog" False, closePanel "workspaces-dialog" False ] )
        Inspector -> ( { model | showInspector = not model.showInspector }, Cmd.none )
        Send payload -> ( model, if model.ready then action payload else Cmd.none )
        Submit ->
            if not model.ready || String.isEmpty (String.trim model.compose) then ( model, Cmd.none ) else
                case Commands.parse (commandContext model) model.compose of
                    Err problem -> ( { model | error = problem }, Cmd.none )
                    Ok intent -> executeIntent intent model
        NewChat ->
            if not model.ready || model.pendingNew then ( model, Cmd.none ) else ( { model | pendingNew = True, drafts = rememberDraft model, compose = "", showInspector = False }, action (command "NewChat" [ str "title" "", str "model" model.modelName, str "workspace" (workspace model) ]) )
        Fork -> ( { model | branch = "", drafts = rememberDraft model, compose = "", pendingNew = True }, action (command "Fork" [ str "nodeId" model.selected, str "title" model.branch, str "task" "" ]) )
        Deliver ->
            let
                note = if String.isEmpty (String.trim model.delivery) then "Shared context from this chat." else model.delivery
                recipient = Dict.get model.target model.core.threads |> Maybe.map .title |> Maybe.withDefault model.target
            in ( { model | delivery = "", notice = "Reference sent to " ++ recipient ++ ". It will be used on the recipient’s next model turn (queued if busy)." }, action (command "Send" [ str "from" model.focused, str "target" model.target, str "text" note, ( "refs", E.list E.string [ model.selected ] ) ]) )
        Compact -> update AssistCompact model
        WorkspaceInput path -> ( { model | workspaceInput = path }, Cmd.none )
        OpenWorkspace fresh -> executeIntent (Commands.Workspace model.workspaceInput fresh "") model
        SwitchWorkspace path -> executeIntent (Commands.Workspace path False "") model
        CommandsMenu -> ( { model | showCommands = not model.showCommands, info = "" }, Cmd.none )
        ChooseCommand name -> ( { model | compose = name ++ " ", showCommands = False }, focusComposer )
        ComposerFocused _ -> ( model, Cmd.none )
        ToggleState ->
            if model.showState then update CloseState model else
            ( { model | showState = True, stateViewer = StateViewer.init (appState model), copyStatus = "" }, ui (command "OpenState" []) )
        CloseState -> ( { model | showState = False }, ui (command "CloseState" []) )
        RefreshState -> ( { model | stateViewer = StateViewer.refresh (appState model) model.stateViewer, copyStatus = "" }, Cmd.none )
        StateViewMsg message -> ( { model | stateViewer = StateViewer.update message model.stateViewer }, Cmd.none )
        CopyState -> ( model, ui (command "CopyState" [ str "text" (E.encode 2 model.stateViewer.source) ]) )
        UiResult result -> ( { model | copyStatus = if D.decodeValue (D.field "ok" D.bool) result |> Result.withDefault False then "Copied JSON" else "Clipboard unavailable; select and copy values directly." }, Cmd.none )
        PolicyField tool name ->
            ( { model | policyEdit = Policy.parseDecision name |> Maybe.andThen (\decision -> Policy.change tool decision model.policyEdit) |> Maybe.withDefault model.policyEdit }, Cmd.none )
        ApplyPolicy -> ( model, action (command "SetPolicy" [ str "threadId" model.focused, ( "policy", Policy.encode model.policyEdit ) ]) )
        BudgetInput value -> ( { model | budgetInput = value }, Cmd.none )
        ApplyBudget ->
            case String.toInt model.budgetInput of
                Just tokens -> if tokens >= 1000 && tokens <= 1000000 then ( model, action (command "SetBudget" [ str "threadId" model.focused, ( "tokens", E.int tokens ) ]) ) else ( { model | error = "Input budget must be between 1,000 and 1,000,000 estimated tokens" }, Cmd.none )
                Nothing -> ( { model | error = "Enter an integer token budget" }, Cmd.none )
        AssistCompact -> ( model, action (command "Summarize" [ str "threadId" model.focused ]) )
        SummaryEdit value -> ( { model | summaryEdit = value }, Cmd.none )
        ApplySummary -> ( model, Cmd.batch [ action (command "ApplySummary" [ str "threadId" model.focused, str "requestId" model.summaryRequest, str "text" model.summaryEdit ]), focusComposer ] )
        DiscardSummary -> ( model, action (command "DiscardSummary" [ str "threadId" model.focused ]) )
        NoOp -> ( model, Cmd.none )
        Key key shift -> if key == "Enter" && not shift then update Submit model else ( model, Cmd.none )

focusComposer : Cmd Msg
focusComposer = Browser.Dom.focus "chat-composer" |> Task.attempt ComposerFocused

focusChat : Cmd Msg
focusChat = Cmd.batch [ focusComposer, ui (command "ChatChanged" []) ]

rememberDraft : Model -> Dict.Dict String String
rememberDraft model = Dict.insert model.focused (if String.startsWith "/" model.compose then "" else model.compose) model.drafts

appState : Model -> E.Value
appState model = E.object
    [ ( "backend", model.backendState )
    , ( "client", E.object [ str "focusedChatId" model.focused, str "selectedNodeId" model.selected, str "workspace" (workspace model), str "model" model.modelName, str "draft" model.compose, ( "draftsByChat", E.dict identity E.string (rememberDraft model) ), str "filter" model.filter, ( "permissionEdits", Policy.encode model.policyEdit ), str "budgetInput" model.budgetInput, str "summaryRequestId" model.summaryRequest, str "summaryEdits" model.summaryEdit, ( "ready", E.bool model.ready ), ( "panels", E.object [ ( "agents", E.bool model.showAgents ), ( "settings", E.bool model.showSettings ), ( "workspaces", E.bool model.showWorkspace ), ( "history", E.bool model.showInspector ), ( "commands", E.bool model.showCommands ) ] ), ( "navigation", E.object [ ( "pendingNewChat", E.bool model.pendingNew ), str "workspaceToken" model.workspaceToken ] ) ] )
    ]

workspace : Model -> String
workspace model = Dict.get model.focused model.core.threads |> Maybe.map .workspace |> Maybe.withDefault model.core.defaultWorkspace

commandContext : Model -> Commands.Context
commandContext model = { threadId = model.focused, nodeId = model.selected, modelName = model.modelName, workspace = workspace model, policy = Dict.get model.focused model.core.threads |> Maybe.map .policy |> Maybe.withDefault Policy.default, summaryRequest = model.summaryRequest }

executeIntent : Commands.Intent -> Model -> ( Model, Cmd Msg )
executeIntent intent model =
    if not model.ready then ( model, Cmd.none ) else
    case intent of
        Commands.Workspace path fresh title ->
            if String.isEmpty (String.trim path) then ( { model | error = "Enter a workspace directory" }, Cmd.none ) else
            let token = String.fromInt (model.workspaceSeq + 1) in
            ( { model | workspaceToken = token, workspaceSeq = model.workspaceSeq + 1, drafts = rememberDraft model, error = "", compose = "", showCommands = False }, action (command "OpenWorkspace" [ str "path" path, ( "newChat", E.bool fresh ), str "title" title, str "model" model.modelName, str "token" token ]) )
        Commands.Action payload ->
            let kind = D.decodeValue (D.field "type" D.string) payload |> Result.withDefault "" in
            if List.member kind [ "StartJob", "ResumeJob" ] then submitAgent True payload { model | compose = "", drafts = Dict.insert model.focused "" model.drafts, showCommands = False } else
            ( { model | compose = "", drafts = if List.member kind [ "NewChat", "Fork" ] then rememberDraft model else Dict.insert model.focused "" model.drafts, error = "", pendingNew = List.member kind [ "NewChat", "Fork" ], showCommands = False }, Cmd.batch [ action payload, focusComposer ] )
        Commands.Local name argument ->
            case name of
                "agents" -> update Agents { model | compose = "" }
                "history" -> ( { model | showInspector = True, compose = "" }, Cmd.none )
                "chats" -> ( { model | showCommands = False, compose = "" }, Cmd.none )
                "workspace" -> update Workspaces { model | compose = "" }
                "workspaces" -> update Workspaces { model | compose = "" }
                "permissions" -> update Settings { model | compose = "" }
                "usage" -> update Settings { model | compose = "" }
                "context" -> update Settings { model | compose = "" }
                "compaction" -> ( { model | compose = "" }, Cmd.none )
                "model" -> update Settings { model | compose = "" }
                "prompt" -> update Settings { model | compose = "" }
                "focus" ->
                    case Dict.values model.core.threads |> List.filter (\thread -> thread.id == argument || thread.title == argument) |> List.head of
                        Just thread -> update (Focus thread.id) { model | compose = "" }
                        Nothing -> ( { model | error = "Chat not found" }, Cmd.none )
                "select" -> if List.any (\node -> node.id == argument) (conversationNodes model) then update (Select argument) { model | compose = "" } else ( { model | error = "Node is outside this chat" }, Cmd.none )
                "status" -> ( { model | showCommands = True, compose = "", info = workspace model ++ " · " ++ model.modelName ++ " · " ++ messageCountLabel model }, Cmd.none )
                "quit" -> ( { model | error = "Close this browser tab to exit the browser client." }, Cmd.none )
                _ -> ( { model | showCommands = True, compose = "", info = "" }, Cmd.none )

selectedAgentModel : Model -> String
selectedAgentModel model = if model.agentModel == "__custom__" then String.trim model.agentCustomModel else model.agentModel

modelOptions : Model -> List (Html Msg)
modelOptions model =
    let choices = Dict.get model.agentBackend model.core.runnerCapabilities |> Maybe.map .models |> Maybe.withDefault []
        choice id label = option [ Html.Attributes.attribute "value" id, Html.Attributes.selected (id == model.agentModel) ] [ text label ]
    in choice "" "CLI default" :: List.map (\item -> choice item.id item.label) choices ++ [ choice "__custom__" "Custom model…" ]

submitAgent : Bool -> E.Value -> Model -> ( Model, Cmd Msg )
submitAgent fromComposer payload model =
    if not model.ready || not (String.isEmpty model.agentPending) then ( model, Cmd.none ) else
    let fields = D.decodeValue (D.dict D.value) payload |> Result.withDefault Dict.empty
        field key = Dict.get key fields |> Maybe.andThen (D.decodeValue D.string >> Result.toMaybe) |> Maybe.withDefault ""
        existing = model.core.jobs |> List.filter (\job -> job.id == field "jobId") |> List.head
        backend = if field "type" == "ResumeJob" then existing |> Maybe.map (.backend >> Jobs.backendName) |> Maybe.withDefault "agent" else field "backend"
        threadId = if field "type" == "ResumeJob" then existing |> Maybe.map .threadId |> Maybe.withDefault model.focused else field "threadId"
        modelName = if String.isEmpty (field "model") && backend == model.agentBackend then selectedAgentModel model else field "model"
        id = model.clientId ++ ":agent:" ++ String.fromInt (model.agentSeq + 1)
        outgoingFields = Dict.insert "actionId" (E.string id) fields
        request = (if field "type" == "StartJob" then Dict.insert "model" (E.string modelName) outgoingFields else outgoingFields) |> E.dict identity identity
        submission = { id = id, threadId = threadId, backend = backend, prompt = field "text", fromComposer = fromComposer }
    in if String.isEmpty (String.trim submission.prompt) then ( model, Cmd.none ) else
    ( { model | agentSubmission = Just submission, agentPending = id, agentSeq = model.agentSeq + 1, error = "" }, Cmd.batch [ action request, if fromComposer then focusChat else Cmd.none ] )

agentControls : Model -> Jobs.Job -> Html Msg
agentControls model job =
    div [ class "agent-response-actions" ]
        (if Jobs.active job.status then [ button [ onClick (Send (command "CancelJob" [ str "jobId" job.id ])) ] [ text "Cancel agent" ] ] else
            [ button [ onClick (ResumeAgent job.id), disabled (String.isEmpty job.sessionId || not (Dict.get (Jobs.backendName job.backend) model.core.runnerCapabilities |> Maybe.map .available |> Maybe.withDefault False)) ] [ text "Continue session" ]
            , button [ onClick (Send (command "ReportJob" [ str "jobId" job.id, str "target" model.focused ])), disabled (job.status /= Jobs.Completed || String.isEmpty job.output) ] [ text "Use result as context" ]
            ])

agentResponse : Model -> Jobs.Job -> Html Msg
agentResponse model job =
    div [ class ("message assistant agent-response" ++ (if Jobs.active job.status then " streaming" else "")), Html.Attributes.attribute "data-agent-job" job.id ]
        [ div [ class "message-label" ] [ text (Jobs.backendName job.backend ++ " · " ++ job.id ++ " · attempt " ++ String.fromInt job.attempt), span [ class "status" ] [ text (Jobs.statusName job.status) ] ]
        , div [ class "agent-job-prompt muted" ] [ text job.prompt ]
        , if Jobs.active job.status then div [ class "agent-progress", Html.Attributes.attribute "role" "status" ] [ span [ class "agent-spinner" ] [], text (JobView.progress job) ] else text ""
        , if String.isEmpty job.error then text "" else div [ class "error" ] [ text job.error ]
        , if String.isEmpty job.output then text "" else Rich.view job.output
        , agentControls model job
        ]

status : Model -> String -> String
status model threadId =
    let native = model.runs |> List.filter (\r -> r.threadId == threadId) |> List.reverse |> List.head |> Maybe.map .status |> Maybe.withDefault Status.Idle in
    if Status.active native then Status.name native else JobView.activity threadId model.agentSubmission model.core.jobs |> Maybe.withDefault (Status.name native)

view : Model -> Browser.Document Msg
view model =
    { title = "Elm · Agent workspace", body = [ main_ [ class "shell" ] [
        div [ class "sidebar" ] [ div [ class "brand" ] [ span [ class "brand-mark" ] [ text "λ" ], text "elm", span [ class "muted" ] [ text " workspace" ] ], button [ class "workspace-picker", onClick Workspaces, title (workspace model), Html.Attributes.attribute "aria-label" "Workspaces" ] [ span [ class "workspace-label" ] [ text "WORKSPACE" ], span [ class "workspace-name" ] [ text ("⌂ " ++ (String.split "/" (workspace model) |> List.reverse |> List.head |> Maybe.withDefault "Workspace") ++ " ▾") ] ], button [ class "new-chat", onClick NewChat, disabled (not model.ready || model.pendingNew), title "Start an empty conversation" ] [ text "+ New chat" ], div [ class "section-label" ] [ text "CONVERSATIONS" ], Keyed.node "div" [ class "thread-list" ] (Public.conversations model.core |> List.map (\thread -> ( thread.id, threadView model thread ))), div [ class "sidebar-bottom" ] [ text (if model.count < 0 then "Elm core" else String.fromInt model.count ++ " replies · Elm core"), button [ onClick (Send (command "ToggleCount" [])) ] [ text "◐" ] ], Ui.html (Ui.map UserMsg (if String.isEmpty model.pluginError then User.sidebar model.core model.user else Ui.Text "Session plugin disabled; saved data preserved")) ],
        div [ class "workspace" ] [ header [ class "topbar" ] [ div [] [ span [ class "workspace-title" ] [ text (Dict.get model.focused model.core.threads |> Maybe.map .title |> Maybe.withDefault "Main") ], span [ class "message-count" ] [ text (messageCountLabel model) ], span [ class "status" ] [ text (status model model.focused) ] ], div [] ((model.runs |> List.filter (\r -> r.threadId == model.focused && Status.active r.status) |> List.map (\r -> button [ onClick (Send (command "Cancel" [ str "runId" r.id ])) ] [ text "Stop" ])) ++ [ button [ class "run-button", onClick (Send (command "Run" [ str "threadId" model.focused ])) ] [ text "Run" ], button [ onClick Agents ] [ text ("Agents" ++ (let count = model.core.jobs |> List.filter (\job -> job.threadId == model.focused && Jobs.active job.status) |> List.length in if count == 0 then "" else " · " ++ String.fromInt count)) ], button [ onClick Inspector ] [ text "Graph & details" ], button [ class "chat-settings-button", onClick Settings, title "Settings for this chat", Html.Attributes.attribute "aria-label" "Chat settings" ] [ text "⚙" ], button [ onClick CommandsMenu ] [ text "Commands" ], button [ class "state-button", onClick ToggleState, title "Explore application state", Html.Attributes.attribute "aria-label" "View app state" ] [ text "{}" ] ]) ], if String.isEmpty model.error then text "" else div [ class "error" ] [ text model.error ],
            if model.showCommands then commandMenu model else text "", sessionMeter model, summaryPanel model,
            div [ class "chat", Html.Attributes.id "chat" ] (conversation model),
            div [ class "composer-wrap" ] [ if String.startsWith "/" model.compose && not (String.contains " " model.compose) then slashMenu model else text "", div [ class "composer" ] [ textarea [ Html.Attributes.id "chat-composer", Html.Attributes.attribute "aria-label" "Chat message", value model.compose, onInput Compose, placeholder "Ask, build, or explore your workspace…", disabled (not model.ready), preventDefaultOn "keydown" (D.map2 (\key shift -> ( Key key shift, key == "Enter" && not shift )) (D.field "key" D.string) (D.field "shiftKey" D.bool)) ] [], div [ class "composer-toolbar" ] [ span [ class "muted" ] [ text (model.modelName ++ " · " ++ workspace model) ], div [] [ button [ onClick Compact, disabled (chatBusy model), title "Generate a summary to review before applying; history is retained" ] [ text "Compact context" ], button [ class "primary", onClick Submit, disabled (not model.ready || String.isEmpty (String.trim model.compose)) ] [ text "Send ↑" ] ] ] ], div [ class "composer-hint" ] [ text "Enter to send · Shift+Enter for a new line · tool permissions are configured per chat" ] ] ],
        if model.showInspector then inspector model else text "", settingsView model, workspaceDialog model, agentsDialog model, stateDialog model
    ] ] }

stateDialog : Model -> Html Msg
stateDialog model =
    Html.node "dialog" [ Html.Attributes.id "state-dialog", class "state-dialog", Html.Attributes.attribute "aria-labelledby" "state-dialog-title", preventDefaultOn "cancel" (D.succeed ( CloseState, True )), Html.Events.on "click" (D.at [ "target", "id" ] D.string |> D.map (\id -> if id == "state-dialog" then CloseState else NoOp)) ]
        (if not model.showState then [] else
            [ div [ class "state-heading" ] [ div [] [ Html.h2 [ Html.Attributes.id "state-dialog-title" ] [ text "Application state" ], div [ class "muted" ] [ text "Read-only backend projection and browser UI state. Host credentials are excluded." ] ], button [ onClick CloseState, Html.Attributes.attribute "aria-label" "Close app state" ] [ text "×" ] ]
            , div [ class "state-actions" ] [ span [ class "muted" ] [ text "Captured snapshot · refresh to update while you explore" ], button [ onClick RefreshState ] [ text "Refresh snapshot" ], button [ onClick CopyState ] [ text "Copy JSON" ], span [ class "muted", Html.Attributes.attribute "role" "status" ] [ text model.copyStatus ] ]
            , Html.map StateViewMsg (StateViewer.view model.stateViewer)
            ])

threadView : Model -> Public.Thread -> Html Msg
threadView model thread =
    button [ class ("thread " ++ (if model.focused == thread.id then "active" else "")), onClick (Focus thread.id), title ("Workspace: " ++ thread.workspace ++ "\nLast active: " ++ DateTime.full model.zone thread.updatedAt) ]
        [ span [ class "thread-icon" ] [ text (if thread.forkedFrom == Nothing then "○" else "⑂") ]
        , div [ class "thread-content" ] [ div [ class "thread-title" ] [ text thread.title ], div [ class "thread-meta" ] [ span [] [ text (status model thread.id) ], Html.time [ Html.Attributes.attribute "datetime" thread.updatedAt, title (DateTime.full model.zone thread.updatedAt) ] [ text (DateTime.date model.zone thread.updatedAt) ] ] ]
        ]

conversationNodes : Model -> List Public.Node
conversationNodes model =
    let
        head = Dict.get model.focused model.core.threads |> Maybe.map .head |> Maybe.withDefault "n1"
        walk id = case Dict.get id model.core.nodes of
            Nothing -> []
            Just node -> (Maybe.map walk node.parentId |> Maybe.withDefault []) ++ [ node ]
    in walk head

messageCountLabel : Model -> String
messageCountLabel model =
    let
        count = conversationNodes model |> List.filter (\node -> List.member node.kind [ "UserMessage", "AgentMessage", "Handoff", "RunnerResult" ]) |> List.length
    in String.fromInt count ++ (if count == 1 then " message" else " messages")

conversation : Model -> List (Html Msg)
conversation model =
    let
        nodes = conversationNodes model
        drafts = model.runs |> List.filter (\r -> r.threadId == model.focused && r.purpose /= "compaction" && not (String.isEmpty r.draft)) |> List.map (\r -> div [ class "message assistant streaming" ] [ div [ class "message-label" ] [ text "● Assistant · streaming" ], Rich.view r.draft ])
        calls = model.runs |> List.filter (\r -> r.threadId == model.focused) |> List.concatMap .pending
        approvals = Public.pendingApprovals model.focused calls model.core |> List.filterMap (\n ->
            case D.decodeString (D.field "id" D.string) n.text of
                Ok id -> if List.member id calls then Just (div [ class "approval" ] [ div [] [ text "Permission requested" ], pre [] [ text n.text ], div [ class "muted" ] [ text "Review the full arguments before allowing this sandboxed tool call." ], button [ onClick (Send (command "Approve" [ str "threadId" model.focused, str "callId" id, ( "allowed", E.bool True ) ])) ] [ text "Allow once" ], button [ onClick (Send (command "Approve" [ str "threadId" model.focused, str "callId" id, ( "allowed", E.bool False ) ])) ] [ text "Deny" ] ]) else Nothing
                Err _ -> Nothing)
        agentJobs = model.core.jobs |> List.filter (\job -> job.threadId == model.focused && (Jobs.active job.status || not (List.any (\node -> node.kind == "RunnerResult" && JobView.matchesResult job node.text) nodes))) |> List.reverse |> List.map (agentResponse model)
        pending = model.agentSubmission |> Maybe.map (\submission -> if submission.threadId /= model.focused then text "" else div [ class "message agent-response pending", Html.Attributes.attribute "role" "status" ] [ div [ class "message-label" ] [ text ("● " ++ submission.backend) ], div [ class "agent-progress" ] [ span [ class "agent-spinner" ] [], text ("Sending " ++ submission.backend ++ " agent request…") ], div [ class "agent-job-prompt muted" ] [ text submission.prompt ] ]) |> Maybe.map List.singleton |> Maybe.withDefault []
    in List.map (messageView model) nodes ++ drafts ++ agentJobs ++ pending ++ approvals

messageView : Model -> Public.Node -> Html Msg
messageView model node =
    if List.member node.kind [ "Approval", "Activity" ] then text "" else
    if node.kind == "RunnerResult" then
        let job = model.core.jobs |> List.filter (\candidate -> JobView.matchesResult candidate node.text) |> List.head in
        div [ class "message assistant agent-response", Html.Attributes.attribute "data-result-node" node.id ]
            [ div [ class "message-label" ] [ button [ onClick (Select node.id) ] [ text (JobView.resultHeading node.text) ] ]
            , Rich.view (JobView.resultBody node.text)
            , job |> Maybe.map (agentControls model) |> Maybe.withDefault (text "")
            ] else
    if List.member node.kind [ "ToolCall", "ToolResult" ] then Html.details [ class "tool" ] [ Html.summary [ onClick (Select node.id) ] [ text ((if node.kind == "ToolCall" then "◆ Tool call" else "✓ Tool result") ++ " · " ++ node.id) ], pre [] [ text node.text ] ] else
    div [ class ("message " ++ (if node.actor == "User" then "user" else "assistant")) ] [ div [ class "message-label" ] [ button [ onClick (Select node.id) ] [ text ((if node.actor == "User" then "◉ You" else if node.kind == "Notice" then "○ System" else "● Assistant") ++ " · " ++ node.id) ] ], Rich.view node.text ]

chatBusy : Model -> Bool
chatBusy model = List.any (\run -> run.threadId == model.focused && Status.active run.status) model.runs

sessionMeter : Model -> Html Msg
sessionMeter model =
    case Dict.get model.focused model.core.threads of
        Nothing -> text ""
        Just thread ->
            let
                estimated = thread.estimatedInput
                usage = Public.usageTotals model.core thread.id
                percentage = min 100 (round (toFloat estimated * 100 / toFloat thread.contextBudget))
                cost = if usage.costReports == 0 then "Cost not reported" else Accounting.money usage.cost ++ " credits" ++ (if usage.costReports < usage.reports then " (partial)" else "")
            in div [ class "session-meter", title (Public.contextReport model.core model.focused) ]
                [ button [ class "context-chip", onClick Settings, Html.Attributes.attribute "aria-label" "Context and usage details" ] [ text ("Context ≈" ++ String.fromInt estimated ++ " / " ++ String.fromInt thread.contextBudget), Html.node "meter" [ Html.Attributes.attribute "min" "0", Html.Attributes.attribute "max" (String.fromInt thread.contextBudget), Html.Attributes.attribute "value" (String.fromInt estimated), Html.Attributes.attribute "aria-label" "Estimated input token budget" ] [], span [ class (if percentage >= 80 then "context-warning" else "muted") ] [ text (String.fromInt percentage ++ "% · estimated") ] ]
                , span [ class "muted" ] [ text (if usage.reports == 0 then "Usage not reported yet" else String.fromInt usage.total ++ " tokens reported · " ++ cost) ]
                , button [ onClick Settings ] [ text (Policy.description thread.policy) ]
                ]

permissionsSettings : Model -> Html Msg
permissionsSettings model =
    let
        field tool =
            let mode = Policy.name (Policy.decision model.policyEdit tool)
                choice ( key, label ) = option [ value key, Html.Attributes.selected (key == mode) ] [ text label ]
            in div [ class "policy-field" ] [ Html.label [] [ text tool ], select [ value mode, onInput (PolicyField tool), Html.Attributes.attribute "aria-label" (tool ++ " permission") ] (List.map choice [ ( "allow", "Allow without asking" ), ( "ask", "Ask each time" ), ( "deny", "Deny" ) ]) ]
    in div [ class "session-settings" ] [ div [ class "section-label" ] [ text "THIS CHAT · PERMISSIONS & CONTEXT" ], div [ class "policy-fields" ] (List.map field [ "read", "write", "bash" ] ++ [ button [ onClick ApplyPolicy ] [ text "Apply permissions" ] ]), div [ class "muted" ] [ text "Policies govern tools. Bash can read workspace files and can modify them unless write is denied; denied write mounts its workspace read-only. For read-only mode deny both write and bash." ], div [ class "budget-setting" ] [ Html.label [] [ text "Estimated input budget" ], input [ value model.budgetInput, onInput BudgetInput, Html.Attributes.type_ "number", Html.Attributes.min "1000", Html.Attributes.max "1000000", Html.Attributes.attribute "aria-label" "Input token budget" ] [], button [ onClick ApplyBudget ] [ text "Apply budget" ] ], pre [] [ text (Public.contextReport model.core model.focused) ] ]

summaryPanel : Model -> Html Msg
summaryPanel model =
    case Dict.get model.focused model.compactions of
        Nothing -> text ""
        Just preview ->
            div [ class "compaction-panel", Html.Attributes.attribute "role" "region", Html.Attributes.attribute "aria-label" "Context summary preview" ]
                [ div [ class "inspector-heading" ] [ text (if preview.status == "Generating" then "Summarizing context…" else if preview.status == "Ready" then "Review context summary" else "Summary could not be generated"), button [ onClick DiscardSummary ] [ text (if preview.status == "Generating" then "Cancel summary" else "Discard summary") ] ]
                , div [ class "muted" ] [ text ("Input before: ≈" ++ String.fromInt preview.before ++ " tokens" ++ (if preview.status == "Ready" then " · after generated summary: ≈" ++ String.fromInt preview.after else "") ++ ". Original history is retained. Queued messages wait until you apply or discard.") ]
                , if String.isEmpty preview.error then text "" else div [ class "context-warning" ] [ text preview.error ]
                , if preview.status == "Ready" then textarea [ value model.summaryEdit, onInput SummaryEdit, Html.Attributes.attribute "aria-label" "Summary to apply" ] [] else text ""
                , if preview.status == "Ready" then button [ class "primary", onClick ApplySummary, disabled (String.isEmpty (String.trim model.summaryEdit)) ] [ text "Apply reviewed summary" ] else text ""
                ]

slashMenu : Model -> Html Msg
slashMenu model = div [ class "slash-menu" ] (Commands.catalog |> List.filter (\entry -> String.startsWith model.compose entry.name) |> List.take 6 |> List.map (\entry -> button [ onClick (ChooseCommand entry.name) ] [ text (entry.name ++ " — " ++ entry.description) ]))

commandMenu : Model -> Html Msg
commandMenu model = div [ class "command-panel" ] [ div [ class "inspector-heading" ] [ text "Commands", button [ onClick CommandsMenu ] [ text "×" ] ], if String.isEmpty model.info then text "" else div [ class "muted" ] [ text model.info ], div [] (List.map (\entry -> button [ class "command-item", onClick (ChooseCommand entry.name) ] [ span [] [ text (entry.name ++ " " ++ entry.arguments) ], span [ class "muted" ] [ text entry.description ] ]) Commands.catalog) ]

openPanel : String -> String -> Cmd Msg
openPanel id focus = ui (command "OpenPanel" [ str "id" id, str "focus" focus ])

closePanel : String -> Bool -> Cmd Msg
closePanel id composer = ui (command "ClosePanel" [ str "id" id, str "focus" (if composer then "chat-composer" else "") ])

panel : String -> String -> String -> List (Html Msg) -> Html Msg
panel id className label children =
    Html.node "dialog" [ Html.Attributes.id id, class className, Html.Attributes.attribute "aria-label" label, preventDefaultOn "cancel" (D.succeed ( ClosePanels, True )), Html.Events.on "click" (D.at [ "target", "id" ] D.string |> D.map (\target -> if target == id then ClosePanels else NoOp)) ] children

panelHeading : String -> String -> Html Msg
panelHeading label subtitle = div [ class "panel-heading" ] [ div [] [ Html.h2 [] [ text label ], div [ class "muted" ] [ text subtitle ] ], button [ onClick ClosePanels, Html.Attributes.attribute "aria-label" ("Close " ++ String.toLower label) ] [ text "×" ] ]

settingsView : Model -> Html Msg
settingsView model = panel "chat-settings-dialog" "settings settings-dialog" "Chat settings"
    (if not model.showSettings then [] else
        [ panelHeading "Chat settings" (Dict.get model.focused model.core.threads |> Maybe.map .title |> Maybe.withDefault "")
        , div [ class "panel-body" ]
            [ div [ class "model-setting" ] [ Html.label [ Html.Attributes.for "chat-settings-model" ] [ text "Model" ], input [ Html.Attributes.id "chat-settings-model", value model.modelName, onInput ModelName ] [], button [ onClick (Send (command "SetModel" [ str "threadId" model.focused, str "model" model.modelName ])), Html.Attributes.attribute "aria-label" "Apply model" ] [ text "Apply model" ] ]
            , permissionsSettings model
            , Html.details [] [ Html.summary [] [ text "Effective system prompt · framework v3" ], pre [] [ text model.prompt ] ]
            , div [ class "chat-workspace-info" ] [ div [ class "section-label" ] [ text "WORKSPACE FOLDER" ], Html.code [] [ text (workspace model) ] ]
            ]
        ])

agentsDialog : Model -> Html Msg
agentsDialog model =
    let
        localJobs = List.filter (\job -> job.threadId == model.focused) model.core.jobs
        capability = Dict.get model.agentBackend model.core.runnerCapabilities
        available = Maybe.map .available capability |> Maybe.withDefault False
        label backend = backend ++ (Dict.get backend model.core.runnerCapabilities |> Maybe.map (\cap -> if cap.available then " · " ++ cap.version else " · unavailable") |> Maybe.withDefault " · unavailable")
        choice backend = option [ value backend, Html.Attributes.selected (backend == model.agentBackend) ] [ text (label backend) ]
        jobView job =
            div [ class "agent-job", Html.Attributes.attribute "data-job-id" job.id ]
                [ div [ class "agent-job-heading" ] [ Html.strong [] [ text (Jobs.backendName job.backend ++ " · " ++ job.id) ], span [ class "status" ] [ text (Jobs.statusName job.status) ], span [ class "muted" ] [ text ("Attempt " ++ String.fromInt job.attempt) ] ]
                , div [ class "agent-job-prompt" ] [ text job.prompt ]
                , div [ class "muted" ] [ text (JobView.usageText job) ]
                , if List.isEmpty job.observations then text "" else Html.details [] [ Html.summary [] [ text (String.fromInt (List.length job.observations) ++ " tool observations") ], pre [] [ text (String.join "\n" job.observations) ] ]
                , if String.isEmpty job.error then text "" else div [ class "error" ] [ text job.error ]
                , if String.isEmpty job.output then text "" else div [ class "agent-output" ] [ Rich.view job.output ]
                , div [ class "workspace-actions" ]
                    (if Jobs.active job.status then [ button [ onClick (Send (command "CancelJob" [ str "jobId" job.id ])) ] [ text "Cancel job" ] ] else
                        [ button [ onClick (ResumeAgent job.id), disabled (String.isEmpty job.sessionId || not (Dict.get (Jobs.backendName job.backend) model.core.runnerCapabilities |> Maybe.map .available |> Maybe.withDefault False)) ] [ text "Continue session" ]
                        , button [ onClick (Send (command "ReportJob" [ str "jobId" job.id, str "target" model.focused ])), disabled (job.status /= Jobs.Completed || String.isEmpty job.output) ] [ text "Send result to chat" ]
                        ])
                , Html.details [] [ Html.summary [] [ text "Job details" ], pre [] [ text ("Workspace: " ++ job.workspace ++ "\nModel: " ++ (if String.isEmpty job.model then "CLI default" else job.model) ++ "\nSession: " ++ (if String.isEmpty job.sessionId then "Not recorded" else job.sessionId) ++ "\nStarted: " ++ DateTime.full model.zone job.createdAt ++ "\nLast activity: " ++ DateTime.full model.zone job.updatedAt) ] ]
                ]
    in panel "agents-dialog" "agents-dialog" "Agent jobs"
        (if not model.showAgents then [] else
            [ panelHeading "Agent jobs" "Read-only inspection and review for this chat."
            , div [ class "panel-body" ]
                [ div [ class "muted" ] [ text "Jobs use this workspace and a captured copy of the conversation. Their results enter chat context when you send them. External tools use their own read-only profile." ]
                , div [ class "agent-launch" ]
                    [ if String.isEmpty model.agentResume then Html.label [] [ text "Runner", select [ value model.agentBackend, onInput AgentBackend, disabled (not (String.isEmpty model.agentPending)), Html.Attributes.attribute "aria-label" "Agent runner" ] (List.map choice [ "codex", "claude" ]) ] else div [] [ text ("Continue " ++ model.agentResume ++ " using its recorded session, model and workspace."), button [ onClick (ResumeAgent "") ] [ text "Start a different job" ] ]
                    , if String.isEmpty model.agentResume then div [ class "agent-model-picker" ] [ Html.label [] [ text "Model", select [ value model.agentModel, onInput AgentModel, disabled (not (String.isEmpty model.agentPending)), Html.Attributes.attribute "aria-label" "Agent model" ] (modelOptions model) ], if model.agentModel == "__custom__" then input [ value model.agentCustomModel, onInput AgentCustomModel, placeholder "Model ID", Html.Attributes.attribute "aria-label" "Custom agent model" ] [] else text "" ] else text ""
                    , Html.label [ Html.Attributes.for "agent-prompt" ] [ text (if String.isEmpty model.agentResume then "Job request" else "Follow-up request") ]
                    , textarea [ Html.Attributes.id "agent-prompt", value model.agentPrompt, onInput AgentPrompt, disabled (not (String.isEmpty model.agentPending)), placeholder "Review this code and explain your findings…", Html.Attributes.attribute "aria-label" "Agent request" ] []
                    , if available || not (String.isEmpty model.agentResume) then text "" else div [ class "error" ] [ text (Maybe.map .error capability |> Maybe.withDefault "Runner not installed") ]
                    , button [ class "primary", onClick StartAgent, disabled (not model.ready || not (String.isEmpty model.agentPending) || String.isEmpty (String.trim model.agentPrompt) || (String.isEmpty model.agentResume && not available)) ] [ text (if not (String.isEmpty model.agentPending) then "Starting…" else if String.isEmpty model.agentResume then "Start read-only job" else "Send follow-up") ]
                    ]
                , if String.isEmpty model.error then text "" else div [ class "error" ] [ text model.error ]
                , if List.isEmpty localJobs then div [ class "muted" ] [ text "No agent jobs in this chat yet." ] else div [ class "agent-jobs" ] (List.map jobView localJobs)
                ]
            ])

workspaceDialog : Model -> Html Msg
workspaceDialog model = panel "workspaces-dialog" "workspace-dialog" "Workspaces"
    (if not model.showWorkspace then [] else
        [ panelHeading "Workspaces" "Choose a folder for your chats."
        , div [ class "panel-body" ]
            [ div [ class "muted" ] [ text "Existing chats keep their workspace folder." ]
            , Html.label [ Html.Attributes.for "workspace-directory" ] [ text "Workspace directory" ]
            , input [ Html.Attributes.id "workspace-directory", value model.workspaceInput, onInput WorkspaceInput, placeholder "/path/to/project", Html.Attributes.attribute "aria-label" "Workspace directory" ] []
            , div [ class "workspace-actions" ] [ button [ onClick (OpenWorkspace False), disabled (not (String.isEmpty model.workspaceToken)) ] [ text "Open workspace" ], button [ onClick (OpenWorkspace True), disabled (not (String.isEmpty model.workspaceToken)) ] [ text "New chat in workspace" ] ]
            , if String.isEmpty model.error then text "" else div [ class "error" ] [ text model.error ]
            , if String.isEmpty model.workspaceToken then text "" else div [ class "muted", Html.Attributes.attribute "role" "status" ] [ text "Opening workspace…" ]
            , div [ class "section-label" ] [ text "OPENED WORKSPACES" ]
            , div [ class "workspace-list" ] (Dict.keys model.core.workspaces |> List.map (\path -> button [ onClick (SwitchWorkspace path), title path ] [ text path ]))
            ]
        ])

inspector : Model -> Html Msg
inspector model =
    let localCore = model.core
        graphCore = { localCore | filter = model.filter, nodes = conversationNodes model |> List.map (\node -> ( node.id, node )) |> Dict.fromList }
        selectedNode = Dict.get model.selected model.core.nodes
    in div [ class "inspector" ] [ div [ class "inspector-heading" ] [ text "History graph", button [ onClick Inspector ] [ text "×" ] ], select [ onInput Filter ] [ option [ value "all" ] [ text "All events" ], option [ value "messages" ] [ text "Messages" ], option [ value "tools" ] [ text "Tools" ], option [ value "errors" ] [ text "Notices" ] ], div [ class "graph-list" ] [ Graph.view graphCore model.selected Select ], div [ class "node-detail" ] [ case selectedNode of
        Nothing -> text "Select a node"
        Just node -> div [] [ div [ class "section-label" ] [ text (Graph.label node) ], Rich.view node.text, div [] (List.map (\ref -> button [ onClick (Select ref) ] [ text ("↗ " ++ ref) ]) node.refs), input [ value model.branch, onInput Branch, placeholder "Branch name" ] [], button [ onClick Fork ] [ text "Fork from here" ], select [ value model.target, onInput Target, Html.Attributes.attribute "aria-label" "Reference recipient" ] (Dict.values model.core.threads |> List.map (\t -> option [ value t.id ] [ text t.title ])), input [ value model.delivery, onInput Delivery, placeholder "Send selected context…" ] [], button [ onClick Deliver ] [ text "Send reference" ], if String.isEmpty model.notice then text "" else div [ class "muted", Html.Attributes.attribute "role" "status" ] [ text model.notice ] ] ], Ui.html (Ui.map UserMsg (if String.isEmpty model.pluginError then User.inspector model.core model.user else Ui.Text model.pluginError)) ]

main : Program E.Value Model Msg
main = Browser.document { init = init, update = update, view = view, subscriptions = \_ -> Sub.batch [ actionResult ActionResult, snapshot Snapshot, network Network, uiResult UiResult ] }
