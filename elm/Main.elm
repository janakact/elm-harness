port module Main exposing (main)

import Browser
import Core
import Commands
import Dict
import Graph
import Html exposing (Html, button, div, header, input, main_, option, pre, select, span, text, textarea)
import Html.Attributes exposing (class, disabled, placeholder, title, value)
import Html.Events exposing (onClick, onInput, preventDefaultOn)
import Json.Decode as D
import Json.Encode as E
import Protocol
import Rich
import User

port snapshot : (E.Value -> msg) -> Sub msg
port network : (String -> msg) -> Sub msg
port action : E.Value -> Cmd msg

type alias Run = { id : String, threadId : String, status : String, draft : String, pending : List String }
type alias Model = { core : Core.Model, runs : List Run, selected : String, focused : String, compose : String, branch : String, target : String, delivery : String, modelName : String, filter : String, error : String, ready : Bool, pendingNew : Bool, prompt : String, showSettings : Bool, showInspector : Bool, count : Int, clientId : String, workspaceToken : String, workspaceSeq : Int, workspaceInput : String, showCommands : Bool, info : String }
type Msg = Snapshot E.Value | Network String | Select String | Focus String | Compose String | Branch String | Target String | Delivery String | ModelName String | Filter String | Settings | Inspector | Send E.Value | Submit | NewChat | Fork | Deliver | Compact | Key String Bool | WorkspaceInput String | OpenWorkspace Bool | SwitchWorkspace String | CommandsMenu | ChooseCommand String

init : E.Value -> ( Model, Cmd Msg )
init flags = ( { core = Core.init, runs = [], selected = "n1", focused = "t1", compose = "", branch = "", target = "t1", delivery = "", modelName = "deepseek/deepseek-v4-flash", filter = "all", error = "", ready = False, pendingNew = False, prompt = "", showSettings = False, showInspector = False, count = 0, clientId = D.decodeValue (D.field "clientId" D.string) flags |> Result.withDefault "", workspaceToken = "", workspaceSeq = 0, workspaceInput = "", showCommands = False, info = "" }, Cmd.none )

str : String -> String -> ( String, E.Value )
str key content = ( key, E.string content )
command : String -> List ( String, E.Value ) -> E.Value
command kind fields = E.object (str "type" kind :: fields)

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Snapshot data ->
            let
                decoder = D.map4 (\( core, user ) runs prompt error -> { core = core, runs = runs, prompt = prompt, error = error, count = if user.showCount then user.replies else -1 }) (D.field "document" Protocol.documentDecoder) (D.field "runs" (D.list (D.map5 Run (D.field "id" D.string) (D.field "threadId" D.string) (D.field "status" D.string) (D.field "draft" D.string) (D.field "pending" (D.list D.string))))) (D.field "prompt" D.string) (D.field "error" D.string)
            in case D.decodeValue decoder data of
                Err e -> ( { model | error = D.errorToString e }, Cmd.none )
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
                    in
                    ( { model | core = projection.core, runs = projection.runs, prompt = Dict.get root projection.core.workspaces |> Maybe.withDefault projection.prompt, error = if String.isEmpty projection.error then problem else projection.error, count = projection.count, ready = String.isEmpty projection.error, pendingNew = model.pendingNew && created == Nothing, focused = focused, selected = if changed then Maybe.map .head thread |> Maybe.withDefault model.selected else model.selected, workspaceToken = if matched then "" else model.workspaceToken, workspaceInput = if changed || String.isEmpty model.workspaceInput then root else model.workspaceInput, modelName = if changed then Maybe.map .model thread |> Maybe.withDefault model.modelName else model.modelName }, Cmd.none )
        Network problem -> ( { model | error = problem }, Cmd.none )
        Select id -> ( { model | selected = id, showInspector = True }, Cmd.none )
        Focus id -> ( { model | focused = id, workspaceInput = Dict.get id model.core.threads |> Maybe.map .workspace |> Maybe.withDefault model.workspaceInput, prompt = Dict.get id model.core.threads |> Maybe.andThen (\thread -> Dict.get thread.workspace model.core.workspaces) |> Maybe.withDefault model.prompt, selected = Dict.get id model.core.threads |> Maybe.map .head |> Maybe.withDefault model.selected, modelName = Dict.get id model.core.threads |> Maybe.map .model |> Maybe.withDefault model.modelName }, Cmd.none )
        Compose content -> ( { model | compose = content }, Cmd.none )
        Branch content -> ( { model | branch = content }, Cmd.none )
        Target id -> ( { model | target = id }, Cmd.none )
        Delivery content -> ( { model | delivery = content }, Cmd.none )
        ModelName content -> ( { model | modelName = content }, Cmd.none )
        Filter content -> ( { model | filter = content }, Cmd.none )
        Settings -> ( { model | showSettings = not model.showSettings }, Cmd.none )
        Inspector -> ( { model | showInspector = not model.showInspector }, Cmd.none )
        Send payload -> ( model, if model.ready then action payload else Cmd.none )
        Submit ->
            if not model.ready || String.isEmpty (String.trim model.compose) then ( model, Cmd.none ) else
                case Commands.parse (commandContext model) model.compose of
                    Err problem -> ( { model | error = problem }, Cmd.none )
                    Ok intent -> executeIntent intent model
        NewChat ->
            if not model.ready || model.pendingNew then ( model, Cmd.none ) else ( { model | pendingNew = True, compose = "", showInspector = False }, action (command "NewChat" [ str "title" "", str "model" model.modelName, str "workspace" (workspace model) ]) )
        Fork -> ( { model | branch = "", pendingNew = True }, action (command "Fork" [ str "nodeId" model.selected, str "title" model.branch, str "task" "" ]) )
        Deliver -> ( { model | delivery = "" }, action (command "Send" [ str "from" model.focused, str "target" model.target, str "text" model.delivery, ( "refs", E.list E.string [ model.selected ] ) ]) )
        Compact -> ( { model | compose = "" }, action (command "Compact" [ str "threadId" model.focused, str "text" model.compose ]) )
        WorkspaceInput path -> ( { model | workspaceInput = path }, Cmd.none )
        OpenWorkspace fresh -> executeIntent (Commands.Workspace model.workspaceInput fresh "") model
        SwitchWorkspace path -> executeIntent (Commands.Workspace path False "") model
        CommandsMenu -> ( { model | showCommands = not model.showCommands, info = "" }, Cmd.none )
        ChooseCommand name -> ( { model | compose = name ++ " ", showCommands = False }, Cmd.none )
        Key key shift -> if key == "Enter" && not shift then update Submit model else ( model, Cmd.none )

workspace : Model -> String
workspace model = Dict.get model.focused model.core.threads |> Maybe.map .workspace |> Maybe.withDefault model.core.defaultWorkspace

commandContext : Model -> Commands.Context
commandContext model = { threadId = model.focused, nodeId = model.selected, modelName = model.modelName, workspace = workspace model }

executeIntent : Commands.Intent -> Model -> ( Model, Cmd Msg )
executeIntent intent model =
    if not model.ready then ( model, Cmd.none ) else
    case intent of
        Commands.Workspace path fresh title ->
            if String.isEmpty (String.trim path) then ( { model | error = "Enter a workspace directory" }, Cmd.none ) else
            let token = String.fromInt (model.workspaceSeq + 1) in
            ( { model | workspaceToken = token, workspaceSeq = model.workspaceSeq + 1, error = "", compose = "", showCommands = False }, action (command "OpenWorkspace" [ str "path" path, ( "newChat", E.bool fresh ), str "title" title, str "model" model.modelName, str "token" token ]) )
        Commands.Action payload ->
            let kind = D.decodeValue (D.field "type" D.string) payload |> Result.withDefault "" in
            ( { model | compose = "", error = "", pendingNew = List.member kind [ "NewChat", "Fork" ], showCommands = False }, action payload )
        Commands.Local name argument ->
            case name of
                "history" -> ( { model | showInspector = True, compose = "" }, Cmd.none )
                "chats" -> ( { model | showCommands = False, compose = "" }, Cmd.none )
                "workspace" -> ( { model | showSettings = True, workspaceInput = workspace model, compose = "" }, Cmd.none )
                "workspaces" -> ( { model | showSettings = True, compose = "" }, Cmd.none )
                "model" -> ( { model | showSettings = True, compose = "" }, Cmd.none )
                "prompt" -> ( { model | showSettings = True, compose = "" }, Cmd.none )
                "focus" ->
                    case Dict.values model.core.threads |> List.filter (\thread -> thread.id == argument || thread.title == argument) |> List.head of
                        Just thread -> update (Focus thread.id) { model | compose = "" }
                        Nothing -> ( { model | error = "Chat not found" }, Cmd.none )
                "select" -> if List.any (\node -> node.id == argument) (conversationNodes model) then update (Select argument) { model | compose = "" } else ( { model | error = "Node is outside this chat" }, Cmd.none )
                "status" -> ( { model | showCommands = True, compose = "", info = workspace model ++ " · " ++ model.modelName ++ " · " ++ messageCountLabel model }, Cmd.none )
                "quit" -> ( { model | error = "Close this browser tab to exit the browser client." }, Cmd.none )
                _ -> ( { model | showCommands = True, compose = "", info = "" }, Cmd.none )

status : Model -> String -> String
status model threadId = model.runs |> List.filter (\r -> r.threadId == threadId) |> List.reverse |> List.head |> Maybe.map .status |> Maybe.withDefault "Idle"

view : Model -> Browser.Document Msg
view model =
    { title = "Elm · Agent workspace", body = [ main_ [ class "shell" ] [
        div [ class "sidebar" ] [ div [ class "brand" ] [ span [ class "brand-mark" ] [ text "λ" ], text "elm", span [ class "muted" ] [ text " workspace" ] ], button [ class "workspace-picker", onClick Settings, title (workspace model) ] [ text ("⌂ " ++ (String.split "/" (workspace model) |> List.reverse |> List.head |> Maybe.withDefault "Workspace")) ], button [ class "new-chat", onClick NewChat, disabled (not model.ready || model.pendingNew), title "Start an empty conversation" ] [ text "+ New chat" ], div [ class "section-label" ] [ text "CONVERSATIONS" ], div [ class "thread-list" ] (Dict.values model.core.threads |> List.map (threadView model)), div [ class "sidebar-bottom" ] [ text (if model.count < 0 then "Elm core" else String.fromInt model.count ++ " replies · Elm core"), button [ onClick (Send (command "ToggleCount" [])) ] [ text "◐" ] ] ],
        div [ class "workspace" ] [ header [ class "topbar" ] [ div [] [ span [ class "workspace-title" ] [ text (Dict.get model.focused model.core.threads |> Maybe.map .title |> Maybe.withDefault "Main") ], span [ class "message-count" ] [ text (messageCountLabel model) ], span [ class "status" ] [ text (status model model.focused) ] ], div [] ((model.runs |> List.filter (\r -> r.threadId == model.focused && List.member r.status [ "Queued", "RequestingModel", "Streaming", "ExecutingTool", "AwaitingApproval" ]) |> List.map (\r -> button [ onClick (Send (command "Cancel" [ str "runId" r.id ])) ] [ text "Stop" ])) ++ [ button [ onClick (Send (command "Run" [ str "threadId" model.focused ])) ] [ text "Run" ], button [ onClick Inspector ] [ text "Graph & details" ], button [ onClick Settings ] [ text "Settings" ], button [ onClick CommandsMenu ] [ text "Commands" ] ]) ], if String.isEmpty model.error then text "" else div [ class "error" ] [ text model.error ],
            if model.showSettings then settingsView model else text "",
            if model.showCommands then commandMenu model else text "",
            div [ class "chat", Html.Attributes.id "chat" ] (conversation model),
            div [ class "composer-wrap" ] [ if String.startsWith "/" model.compose && not (String.contains " " model.compose) then slashMenu model else text "", div [ class "composer" ] [ textarea [ value model.compose, onInput Compose, placeholder "Ask, build, or explore your workspace…", disabled (not model.ready), preventDefaultOn "keydown" (D.map2 (\key shift -> ( Key key shift, key == "Enter" && not shift )) (D.field "key" D.string) (D.field "shiftKey" D.bool)) ] [], div [ class "composer-toolbar" ] [ span [ class "muted" ] [ text (model.modelName ++ " · " ++ workspace model) ], div [] [ button [ onClick Compact, title "Use the text above as an explicit context summary" ] [ text "Compact" ], button [ class "primary", onClick Submit, disabled (not model.ready || String.isEmpty (String.trim model.compose)) ] [ text "Send ↑" ] ] ] ], div [ class "composer-hint" ] [ text "Enter to send · Shift+Enter for a new line · writes and shell commands ask for approval" ] ] ],
        if model.showInspector then inspector model else text ""
    ] ] }

threadView : Model -> Core.Thread -> Html Msg
threadView model thread = button [ class ("thread " ++ (if model.focused == thread.id then "active" else "")), onClick (Focus thread.id) ] [ span [ class "thread-icon" ] [ text (if thread.forkedFrom == Nothing then "○" else "⑂") ], div [] [ div [] [ text thread.title ], span [ class "muted" ] [ text (status model thread.id ++ " · " ++ (String.split "/" thread.workspace |> List.reverse |> List.head |> Maybe.withDefault "")) ] ] ]

conversationNodes : Model -> List Core.Node
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
        count = conversationNodes model |> List.filter (\node -> List.member node.kind [ "UserMessage", "AgentMessage", "Handoff" ]) |> List.length
    in String.fromInt count ++ (if count == 1 then " message" else " messages")

conversation : Model -> List (Html Msg)
conversation model =
    let
        nodes = conversationNodes model
        drafts = model.runs |> List.filter (\r -> r.threadId == model.focused && not (String.isEmpty r.draft)) |> List.map (\r -> div [ class "message assistant streaming" ] [ div [ class "message-label" ] [ text "● Assistant · streaming" ], Rich.view r.draft ])
        calls = model.runs |> List.filter (\r -> r.threadId == model.focused) |> List.concatMap .pending
        approvals = nodes |> List.filter (\n -> n.kind == "Approval") |> List.filterMap (\n ->
            case D.decodeString (D.field "id" D.string) n.text of
                Ok id -> if List.member id calls && not (List.any (\x -> x.kind == "Activity" && String.startsWith (id ++ ":") x.text) nodes) then Just (div [ class "approval" ] [ div [] [ text "Permission requested" ], pre [] [ text n.text ], div [ class "muted" ] [ text "Shell approval runs with your OS permissions. Review the full command." ], button [ onClick (Send (command "Approve" [ str "callId" id, ( "allowed", E.bool True ) ])) ] [ text "Allow once" ], button [ onClick (Send (command "Approve" [ str "callId" id, ( "allowed", E.bool False ) ])) ] [ text "Deny" ] ]) else Nothing
                Err _ -> Nothing)
    in List.map (messageView model) nodes ++ drafts ++ approvals

messageView : Model -> Core.Node -> Html Msg
messageView model node =
    if List.member node.kind [ "Approval", "Activity" ] then text "" else
    if List.member node.kind [ "ToolCall", "ToolResult" ] then Html.details [ class "tool" ] [ Html.summary [ onClick (Select node.id) ] [ text ((if node.kind == "ToolCall" then "◆ Tool call" else "✓ Tool result") ++ " · " ++ node.id) ], pre [] [ text node.text ] ] else
    div [ class ("message " ++ (if node.actor == "User" then "user" else "assistant")) ] [ div [ class "message-label" ] [ button [ onClick (Select node.id) ] [ text ((if node.actor == "User" then "◉ You" else if node.kind == "Notice" then "○ System" else "● Assistant") ++ " · " ++ node.id) ] ], Rich.view node.text ]

slashMenu : Model -> Html Msg
slashMenu model = div [ class "slash-menu" ] (Commands.catalog |> List.filter (\entry -> String.startsWith model.compose entry.name) |> List.take 6 |> List.map (\entry -> button [ onClick (ChooseCommand entry.name) ] [ text (entry.name ++ " — " ++ entry.description) ]))

commandMenu : Model -> Html Msg
commandMenu model = div [ class "command-panel" ] [ div [ class "inspector-heading" ] [ text "Commands", button [ onClick CommandsMenu ] [ text "×" ] ], if String.isEmpty model.info then text "" else div [ class "muted" ] [ text model.info ], div [] (List.map (\entry -> button [ class "command-item", onClick (ChooseCommand entry.name) ] [ span [] [ text (entry.name ++ " " ++ entry.arguments) ], span [ class "muted" ] [ text entry.description ] ]) Commands.catalog) ]

settingsView : Model -> Html Msg
settingsView model = div [ class "settings" ] [
    div [ class "workspace-settings" ] [ div [ class "section-label" ] [ text "WORKSPACE" ], div [ class "muted" ] [ text ("This chat: " ++ workspace model) ], input [ value model.workspaceInput, onInput WorkspaceInput, placeholder "/path/to/project", Html.Attributes.attribute "aria-label" "Workspace directory" ] [], button [ onClick (OpenWorkspace False), disabled (not (String.isEmpty model.workspaceToken)) ] [ text "Open workspace" ], button [ onClick (OpenWorkspace True), disabled (not (String.isEmpty model.workspaceToken)) ] [ text "New chat in workspace" ], div [ class "workspace-list" ] (Dict.keys model.core.workspaces |> List.map (\path -> button [ onClick (SwitchWorkspace path), title path ] [ text path ])) ],
    div [] [ text "Model", input [ value model.modelName, onInput ModelName ] [], button [ onClick (Send (command "SetModel" [ str "threadId" model.focused, str "model" model.modelName ])) ] [ text "Apply" ] ], Html.details [] [ Html.summary [] [ text "Effective system prompt · framework v3" ], pre [] [ text model.prompt ] ] ]

inspector : Model -> Html Msg
inspector model =
    let localCore = model.core
        graphCore = { localCore | filter = model.filter, nodes = conversationNodes model |> List.map (\node -> ( node.id, node )) |> Dict.fromList }
        selectedNode = Dict.get model.selected model.core.nodes
    in div [ class "inspector" ] [ div [ class "inspector-heading" ] [ text "History graph", button [ onClick Inspector ] [ text "×" ] ], select [ onInput Filter ] [ option [ value "all" ] [ text "All events" ], option [ value "messages" ] [ text "Messages" ], option [ value "tools" ] [ text "Tools" ], option [ value "errors" ] [ text "Notices" ] ], div [ class "graph-list" ] [ Graph.view graphCore model.selected Select ], div [ class "node-detail" ] [ case selectedNode of
        Nothing -> text "Select a node"
        Just node -> div [] [ div [ class "section-label" ] [ text (Graph.label node) ], Rich.view node.text, div [] (List.map (\ref -> button [ onClick (Select ref) ] [ text ("↗ " ++ ref) ]) node.refs), input [ value model.branch, onInput Branch, placeholder "Branch name" ] [], button [ onClick Fork ] [ text "Fork from here" ], select [ onInput Target ] (Dict.values model.core.threads |> List.map (\t -> option [ value t.id ] [ text t.title ])), input [ value model.delivery, onInput Delivery, placeholder "Send selected context…" ] [], button [ onClick Deliver ] [ text "Send reference" ] ] ] ]

main : Program E.Value Model Msg
main = Browser.document { init = init, update = update, view = view, subscriptions = \_ -> Sub.batch [ snapshot Snapshot, network Network ] }
