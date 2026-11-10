port module Main exposing (main)

import Browser
import Core
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
type alias Model = { core : Core.Model, runs : List Run, selected : String, focused : String, compose : String, branch : String, target : String, delivery : String, modelName : String, filter : String, error : String, ready : Bool, pendingNew : Bool, prompt : String, showSettings : Bool, showInspector : Bool, count : Int }
type Msg = Snapshot E.Value | Network String | Select String | Focus String | Compose String | Branch String | Target String | Delivery String | ModelName String | Filter String | Settings | Inspector | Send E.Value | Submit | NewChat | Fork | Deliver | Compact | Key String Bool

init : () -> ( Model, Cmd Msg )
init _ = ( { core = Core.init, runs = [], selected = "n1", focused = "t1", compose = "", branch = "", target = "t1", delivery = "", modelName = "deepseek/deepseek-v4-flash", filter = "all", error = "", ready = False, pendingNew = False, prompt = "", showSettings = False, showInspector = False, count = 0 }, Cmd.none )

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
                        created = if model.pendingNew then Dict.values projection.core.threads |> List.filter (\t -> not (Dict.member t.id model.core.threads)) |> List.head else Nothing
                    in
                    ( { model | core = projection.core, runs = projection.runs, prompt = projection.prompt, error = projection.error, count = projection.count, ready = String.isEmpty projection.error, pendingNew = model.pendingNew && created == Nothing, focused = Maybe.map .id created |> Maybe.withDefault model.focused, selected = Maybe.map .head created |> Maybe.withDefault model.selected }, Cmd.none )
        Network problem -> ( { model | error = problem }, Cmd.none )
        Select id -> ( { model | selected = id, showInspector = True }, Cmd.none )
        Focus id -> ( { model | focused = id, modelName = Dict.get id model.core.threads |> Maybe.map .model |> Maybe.withDefault model.modelName }, Cmd.none )
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
            if not model.ready || String.isEmpty (String.trim model.compose) then ( model, Cmd.none ) else ( { model | compose = "" }, action (command "Submit" [ str "threadId" model.focused, str "text" model.compose ]) )
        NewChat ->
            if not model.ready || model.pendingNew then ( model, Cmd.none ) else ( { model | pendingNew = True, compose = "", showInspector = False }, action (command "NewChat" [ str "title" "", str "model" model.modelName ]) )
        Fork -> ( { model | branch = "" }, action (command "Fork" [ str "nodeId" model.selected, str "title" model.branch, str "task" "" ]) )
        Deliver -> ( { model | delivery = "" }, action (command "Send" [ str "from" model.focused, str "target" model.target, str "text" model.delivery, ( "refs", E.list E.string [ model.selected ] ) ]) )
        Compact -> ( { model | compose = "" }, action (command "Compact" [ str "threadId" model.focused, str "text" model.compose ]) )
        Key key shift -> if key == "Enter" && not shift then update Submit model else ( model, Cmd.none )

status : Model -> String -> String
status model threadId = model.runs |> List.filter (\r -> r.threadId == threadId) |> List.reverse |> List.head |> Maybe.map .status |> Maybe.withDefault "Idle"

view : Model -> Browser.Document Msg
view model =
    { title = "Elm · Agent workspace", body = [ main_ [ class "shell" ] [
        div [ class "sidebar" ] [ div [ class "brand" ] [ span [ class "brand-mark" ] [ text "λ" ], text "elm", span [ class "muted" ] [ text " workspace" ] ], button [ class "new-chat", onClick NewChat, disabled (not model.ready || model.pendingNew), title "Start an empty conversation" ] [ text "+ New chat" ], div [ class "section-label" ] [ text "CONVERSATIONS" ], div [ class "thread-list" ] (Dict.values model.core.threads |> List.map (threadView model)), div [ class "sidebar-bottom" ] [ text (if model.count < 0 then "Elm core" else String.fromInt model.count ++ " replies · Elm core"), button [ onClick (Send (command "ToggleCount" [])) ] [ text "◐" ] ] ],
        div [ class "workspace" ] [ header [ class "topbar" ] [ div [] [ span [ class "workspace-title" ] [ text (Dict.get model.focused model.core.threads |> Maybe.map .title |> Maybe.withDefault "Main") ], span [ class "status" ] [ text (status model model.focused) ] ], div [] ((model.runs |> List.filter (\r -> r.threadId == model.focused && List.member r.status [ "Queued", "RequestingModel", "Streaming", "ExecutingTool", "AwaitingApproval" ]) |> List.map (\r -> button [ onClick (Send (command "Cancel" [ str "runId" r.id ])) ] [ text "Stop" ])) ++ [ button [ onClick (Send (command "Run" [ str "threadId" model.focused ])) ] [ text "Run" ], button [ onClick Inspector ] [ text "Graph & details" ], button [ onClick Settings ] [ text "Settings" ] ]) ], if String.isEmpty model.error then text "" else div [ class "error" ] [ text model.error ],
            if model.showSettings then settingsView model else text "",
            div [ class "chat", Html.Attributes.id "chat" ] (conversation model),
            div [ class "composer-wrap" ] [ div [ class "composer" ] [ textarea [ value model.compose, onInput Compose, placeholder "Ask, build, or explore your workspace…", disabled (not model.ready), preventDefaultOn "keydown" (D.map2 (\key shift -> ( Key key shift, key == "Enter" && not shift )) (D.field "key" D.string) (D.field "shiftKey" D.bool)) ] [], div [ class "composer-toolbar" ] [ span [ class "muted" ] [ text (model.modelName ++ " · read / write / bash") ], div [] [ button [ onClick Compact, title "Use the text above as an explicit context summary" ] [ text "Compact" ], button [ class "primary", onClick Submit, disabled (not model.ready || String.isEmpty (String.trim model.compose)) ] [ text "Send ↑" ] ] ] ], div [ class "composer-hint" ] [ text "Enter to send · Shift+Enter for a new line · writes and shell commands ask for approval" ] ] ],
        if model.showInspector then inspector model else text ""
    ] ] }

threadView : Model -> Core.Thread -> Html Msg
threadView model thread = button [ class ("thread " ++ (if model.focused == thread.id then "active" else "")), onClick (Focus thread.id) ] [ span [ class "thread-icon" ] [ text (if thread.forkedFrom == Nothing then "○" else "⑂") ], div [] [ div [] [ text thread.title ], span [ class "muted" ] [ text (status model thread.id) ] ] ]

conversation : Model -> List (Html Msg)
conversation model =
    let
        head = Dict.get model.focused model.core.threads |> Maybe.map .head |> Maybe.withDefault "n1"
        walk id = case Dict.get id model.core.nodes of
            Nothing -> []
            Just node -> (Maybe.map walk node.parentId |> Maybe.withDefault []) ++ [ node ]
        nodes = walk head
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

settingsView : Model -> Html Msg
settingsView model = div [ class "settings" ] [ div [] [ text "Model", input [ value model.modelName, onInput ModelName ] [], button [ onClick (Send (command "SetModel" [ str "threadId" model.focused, str "model" model.modelName ])) ] [ text "Apply" ] ], Html.details [] [ Html.summary [] [ text "Effective system prompt · framework v3" ], pre [] [ text model.prompt ] ] ]

inspector : Model -> Html Msg
inspector model =
    let localCore = model.core
        graphCore = { localCore | filter = model.filter }
        selectedNode = Dict.get model.selected model.core.nodes
    in div [ class "inspector" ] [ div [ class "inspector-heading" ] [ text "History graph", button [ onClick Inspector ] [ text "×" ] ], select [ onInput Filter ] [ option [ value "all" ] [ text "All events" ], option [ value "messages" ] [ text "Messages" ], option [ value "tools" ] [ text "Tools" ], option [ value "errors" ] [ text "Notices" ] ], div [ class "graph-list" ] [ Graph.view graphCore model.selected Select ], div [ class "node-detail" ] [ case selectedNode of
        Nothing -> text "Select a node"
        Just node -> div [] [ div [ class "section-label" ] [ text (node.id ++ " · " ++ node.kind) ], Rich.view node.text, div [] (List.map (\ref -> button [ onClick (Select ref) ] [ text ("↗ " ++ ref) ]) node.refs), input [ value model.branch, onInput Branch, placeholder "Branch name" ] [], button [ onClick Fork ] [ text "Fork from here" ], select [ onInput Target ] (Dict.values model.core.threads |> List.map (\t -> option [ value t.id ] [ text t.title ])), input [ value model.delivery, onInput Delivery, placeholder "Send selected context…" ] [], button [ onClick Deliver ] [ text "Send reference" ] ] ] ]

main : Program () Model Msg
main = Browser.document { init = init, update = update, view = view, subscriptions = \_ -> Sub.batch [ snapshot Snapshot, network Network ] }
