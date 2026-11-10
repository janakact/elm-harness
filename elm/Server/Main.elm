port module Server.Main exposing (main)

import Core
import Dict
import Json.Decode as D
import Json.Encode as E
import Platform
import Prompt
import Protocol
import User

port incoming : (E.Value -> msg) -> Sub msg
port outgoing : E.Value -> Cmd msg

type alias PendingWorkspace = { path : String, fresh : Bool, title : String, modelName : String, clientId : String, token : String }
type alias Model = { core : Core.Model, user : User.Model, error : String, notice : String, serial : Int, pending : Dict.Dict String PendingWorkspace, navigations : Dict.Dict String E.Value }
type Msg = Incoming E.Value

init : E.Value -> ( Model, Cmd Msg )
init flags =
    let
        get key = D.decodeValue (D.field key D.string) flags |> Result.withDefault ""
        saved = D.decodeValue (D.field "document" (D.nullable Protocol.documentDecoder)) flags
        prompt = Prompt.build (get "root") (get "system") (get "append") (get "project")
        initial = case saved of
            Ok (Just ( core, user )) -> { core = Core.recover core, user = user, error = "", notice = "", serial = 0, pending = Dict.empty, navigations = Dict.empty }
            Ok Nothing -> { core = Core.init, user = User.init, error = "", notice = "", serial = 0, pending = Dict.empty, navigations = Dict.empty }
            Err problem -> { core = Core.init, user = User.init, error = D.errorToString problem, notice = "", serial = 0, pending = Dict.empty, navigations = Dict.empty }
        interrupted = D.decodeValue (D.at [ "document", "core", "data", "interrupted" ] (D.list D.string)) flags |> Result.withDefault []
        repaired = List.foldl (\id core -> Core.update (Core.RecoverInterrupted id) core |> (\( c, _, _ ) -> c)) initial.core interrupted
        limit = D.decodeValue (D.field "maxConcurrency" D.int) flags |> Result.withDefault 4
        configured = Core.update (Core.Configure limit) repaired |> (\( c, _, _ ) -> c)
        model = { initial | core = Core.update (Core.BindWorkspace (get "root") prompt) configured |> (\( c, _, _ ) -> c) }
    in ( model, Cmd.batch [ publish model [], if String.isEmpty model.error then Dict.keys model.core.workspaces |> List.filter ((/=) (get "root")) |> List.map (\root -> outgoing (E.object [ ( "type", E.string "ReadWorkspace" ), ( "path", E.string root ), ( "requestId", E.string "restore" ) ])) |> Cmd.batch else Cmd.none ] )

-- All model-specific response interpretation and tool fragments stay in Elm.
chunk : String -> E.Value -> Core.Model -> ( Core.Model, List Core.Effect )
chunk requestId value core =
    let
        get decoder fallback = D.decodeValue decoder value |> Result.withDefault fallback
        text = get (D.at [ "choices" ] (D.index 0 (D.at [ "delta", "content" ] D.string))) ""
        calls = get (D.at [ "choices" ] (D.index 0 (D.at [ "delta", "tool_calls" ] (D.list D.value)))) []
        ( withText, _, _ ) = Core.update (Core.Delta requestId text) core
        add call current =
            let
                str path = D.decodeValue (D.at path D.string) call |> Result.withDefault ""
                index = D.decodeValue (D.field "index" D.int) call |> Result.withDefault 0
                ( next, _, _ ) = Core.update (Core.ToolDelta requestId index (str [ "id" ]) (str [ "function", "name" ]) (str [ "function", "arguments" ])) current
            in next
    in ( List.foldl add withText calls, [] )

update : Msg -> Model -> ( Model, Cmd Msg )
update (Incoming value) model =
    let
        tag = D.decodeValue (D.field "type" D.string) value |> Result.withDefault ""
        str key = D.decodeValue (D.field key D.string) value |> Result.withDefault ""
        at = str "at"
        apply msg =
            let
                ( updatedCore, emitted, event ) = Core.update msg model.core
                ( core, queuedEffects ) = Core.schedule updatedCore
                effects = emitted ++ queuedEffects
                next = { model | core = core, user = Maybe.map (\e -> User.onEvent e model.user) event |> Maybe.withDefault model.user, serial = model.serial + 1 }
            in ( next, publish next effects )
    in
    if not (String.isEmpty model.error) then ( model, publish model [] ) else
    case tag of
        "OpenWorkspace" ->
            if String.isEmpty (String.trim (str "path")) then
                let next = { model | notice = "Provide a workspace directory path" } in ( next, broadcast next )
            else
                let
                    id = "workspace-" ++ String.fromInt (model.serial + 1)
                    pending = { path = str "path", fresh = D.decodeValue (D.field "newChat" D.bool) value |> Result.withDefault False, title = str "title", modelName = str "model", clientId = str "clientId", token = str "token" }
                    next = { model | pending = Dict.insert id pending model.pending, serial = model.serial + 1, notice = "" }
                in ( next, Cmd.batch [ broadcast next, outgoing (E.object [ ( "type", E.string "ReadWorkspace" ), ( "requestId", E.string id ), ( "path", E.string pending.path ) ]) ] )
        "WorkspaceLoaded" ->
            let
                root = str "root"
                prompt = Prompt.build root (str "system") (str "append") (str "project")
                ( registered, _, _ ) = Core.update (Core.RegisterWorkspace root prompt) model.core
            in
            if str "requestId" == "restore" then
                let next = { model | core = registered, serial = model.serial + 1 } in ( next, publish next [] )
            else case Dict.get (str "requestId") model.pending of
                Nothing -> ( model, Cmd.none )
                Just pending ->
                    let
                        existing = Dict.values registered.threads |> List.filter (\thread -> thread.workspace == root) |> List.sortBy (\thread -> String.dropLeft 1 thread.id |> String.toInt |> Maybe.withDefault 0) |> List.reverse |> List.head
                        ( core, _, _ ) = if pending.fresh || existing == Nothing then Core.update (Core.NewChatIn root pending.title pending.modelName at) registered else ( registered, [], Nothing )
                        threadId = if pending.fresh || existing == Nothing then core.focused else Maybe.map .id existing |> Maybe.withDefault core.focused
                        navigation = E.object [ ( "token", E.string pending.token ), ( "threadId", E.string threadId ), ( "root", E.string root ), ( "error", E.string "" ) ]
                        next = { model | core = core, pending = Dict.remove (str "requestId") model.pending, navigations = Dict.insert pending.clientId navigation model.navigations, notice = "", serial = model.serial + 1 }
                    in ( next, publish next [] )
        "WorkspaceFailed" ->
            case Dict.get (str "requestId") model.pending of
                Nothing -> let next = { model | notice = "Cannot reopen workspace: " ++ str "error" } in ( next, broadcast next )
                Just pending ->
                    let
                        navigation = E.object [ ( "token", E.string pending.token ), ( "threadId", E.string "" ), ( "root", E.string "" ), ( "error", E.string (str "error") ) ]
                        next = { model | pending = Dict.remove (str "requestId") model.pending, navigations = Dict.insert pending.clientId navigation model.navigations, notice = str "error" }
                    in ( next, broadcast next )
        "Chunk" ->
            let
                data = D.decodeValue (D.field "data" D.value) value |> Result.withDefault E.null
                problem = D.decodeValue (D.at [ "error", "message" ] D.string) data |> Result.toMaybe
                ( core, _ ) = chunk (str "requestId") data model.core
                next = { model | core = core }
            in case problem of
                Just reason -> apply (Core.Failed (str "requestId") reason at)
                Nothing -> ( next, broadcast next )
        "Finished" -> apply (Core.Finished (str "requestId") at)
        "Failed" -> apply (Core.Failed (str "requestId") (str "error") at)
        "ToolFinished" -> apply (Core.ToolFinished (str "callId") (str "text") (D.decodeValue (D.field "ok" D.bool) value |> Result.withDefault False) at)
        "StorageFailed" -> let next = { model | error = str "error" } in ( next, broadcast next )
        "ToggleCount" -> let next = { model | user = User.update User.ToggleCount model.user, serial = model.serial + 1 } in ( next, publish next [] )
        "NewChat" ->
            if not (String.isEmpty (str "workspace")) && not (Dict.member (str "workspace") model.core.workspaces) then
                update (Incoming (E.object [ ( "type", E.string "OpenWorkspace" ), ( "path", E.string (str "workspace") ), ( "newChat", E.bool True ), ( "title", E.string (str "title") ), ( "model", E.string (str "model") ), ( "clientId", E.string (str "clientId") ), ( "token", E.string (str "token") ) ])) model
            else case D.decodeValue Protocol.action value of
                Ok msg -> apply msg
                Err _ -> ( model, Cmd.none )
        _ -> case D.decodeValue Protocol.action value of
            Ok msg -> apply msg
            Err _ -> ( model, Cmd.none )

snapshot : Model -> E.Value
snapshot model = E.object [ ( "protocolVersion", E.int 1 ), ( "document", Protocol.document model.core model.user ), ( "view", Core.view model.core ), ( "extension", User.view model.user ), ( "error", E.string model.error ), ( "runs", E.list (\r -> E.object [ ( "id", E.string r.id ), ( "threadId", E.string r.threadId ), ( "status", E.string r.status ), ( "draft", E.string r.draft ), ( "pending", E.list E.string r.pending ) ]) (Dict.values model.core.runs |> List.sortBy (\r -> String.dropLeft 1 r.id |> String.toInt |> Maybe.withDefault 0)) ), ( "prompt", E.string model.core.systemPrompt ), ( "workspaceNotice", E.string model.notice ), ( "navigations", E.dict identity identity model.navigations ) ]

broadcast : Model -> Cmd Msg
broadcast model = outgoing (E.object [ ( "type", E.string "Snapshot" ), ( "data", snapshot model ) ])

publish : Model -> List Core.Effect -> Cmd Msg
publish model effects =
    Cmd.batch [ broadcast model, if String.isEmpty model.error then outgoing (E.object [ ( "type", E.string "Persist" ), ( "serial", E.int model.serial ), ( "document", Protocol.document model.core model.user ) ]) else Cmd.none, Cmd.batch (List.map (effect model) effects) ]

effect : Model -> Core.Effect -> Cmd Msg
effect model command =
    outgoing (case command of
        Core.Request requestId threadId modelName messages -> E.object [ ( "type", E.string "Request" ), ( "requestId", E.string requestId ), ( "threadId", E.string threadId ), ( "body", E.object [ ( "model", E.string modelName ), ( "messages", messages ), ( "tools", Prompt.tools ), ( "stream", E.bool True ), ( "parallel_tool_calls", E.bool False ), ( "max_tokens", E.int 8192 ) ] ) ]
        Core.Abort requestId -> E.object [ ( "type", E.string "Abort" ), ( "requestId", E.string requestId ) ]
        Core.Execute callId name args approved ->
            let
                root = Dict.values model.core.runs |> List.filter (\run -> List.member callId run.pending) |> List.head |> Maybe.andThen (\run -> Dict.get run.threadId model.core.threads) |> Maybe.map .workspace |> Maybe.withDefault model.core.defaultWorkspace
            in E.object [ ( "root", E.string root ), ( "type", E.string "Execute" ), ( "callId", E.string callId ), ( "name", E.string name ), ( "args", args ), ( "approved", E.bool approved ) ])

main : Program E.Value Model Msg
main = Platform.worker { init = init, update = update, subscriptions = \_ -> incoming Incoming }
