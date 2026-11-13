port module Server.Main exposing (main)

import Agent.Event as Event
import Core
import Runner
import Runner.Types as Jobs
import Runner.Protocol as RunnerProtocol
import App.Public as Public
import App.DateTime as DateTime
import App.Projection as Projection
import App.RunStatus as Status
import Providers.OpenRouter as OpenRouter
import Policy
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
type alias Prepared = { effect : Core.Effect, payload : E.Value }
type alias Model = { core : Core.Model, user : User.Model, error : String, notice : String, serial : Int, pending : Dict.Dict String PendingWorkspace, navigations : Dict.Dict String E.Value, awaitingSave : Dict.Dict Int (List Prepared), preservedUser : Maybe E.Value, pluginError : String }
type Msg = Incoming E.Value

init : E.Value -> ( Model, Cmd Msg )
init flags =
    let
        get key = D.decodeValue (D.field key D.string) flags |> Result.withDefault ""
        saved = D.decodeValue (D.field "document" (D.nullable Protocol.documentDecoder)) flags
        prompt = Prompt.build (get "root") (get "system") (get "append") (get "project")
        initial = case saved of
            Ok (Just restored) -> { core = Core.recover restored.core |> (\core -> { core | runners = Runner.recover core.runners }), user = restored.user, error = "", notice = "", serial = 0, pending = Dict.empty, navigations = Dict.empty, awaitingSave = Dict.empty, preservedUser = restored.preservedUser, pluginError = restored.pluginError }
            Ok Nothing -> { core = Core.initAt (get "startedAt"), user = User.init, error = "", notice = "", serial = 0, pending = Dict.empty, navigations = Dict.empty, awaitingSave = Dict.empty, preservedUser = Nothing, pluginError = "" }
            Err problem -> { core = Core.initAt (get "startedAt"), user = User.init, error = D.errorToString problem, notice = "", serial = 0, pending = Dict.empty, navigations = Dict.empty, awaitingSave = Dict.empty, preservedUser = Nothing, pluginError = "" }
        interrupted = D.decodeValue (D.at [ "document", "core", "data", "interrupted" ] (D.list D.string)) flags |> Result.withDefault []
        repaired = List.foldl (\id core -> Core.update (Core.RecoverInterrupted id) core |> (\( c, _, _ ) -> c)) initial.core interrupted
        limit = D.decodeValue (D.field "maxConcurrency" D.int) flags |> Result.withDefault 4
        configured = Core.update (Core.Configure limit) repaired |> (\( c, _, _ ) -> c)
        capabilities = D.decodeValue (D.field "runners" Jobs.capabilitiesDecoder) flags |> Result.withDefault Dict.empty
        withRunners = { configured | runnerCapabilities = capabilities }
        model = { initial | core = Core.update (Core.BindWorkspace (get "root") prompt) withRunners |> (\( c, _, _ ) -> c) }
    in ( model, Cmd.batch [ broadcast model, save model, if String.isEmpty model.error then Dict.keys model.core.workspaces |> List.filter ((/=) (get "root")) |> List.map (\root -> outgoing (E.object [ ( "type", E.string "ReadWorkspace" ), ( "path", E.string root ), ( "requestId", E.string "restore" ) ])) |> Cmd.batch else Cmd.none ] )

-- Provider codecs emit typed events; the native agent alone decides transitions.
chunk : String -> String -> E.Value -> Core.Model -> ( Core.Model, Maybe String )
chunk requestId at value core =
    let apply event ( current, problem ) = case event of
            Event.ProviderError reason -> ( current, Just reason )
            _ ->
                let msg = case event of
                        Event.Text text -> Core.Delta requestId text
                        Event.ToolFragment index id name args -> Core.ToolDelta requestId index id name args
                        Event.Usage usage -> Core.UsageChunk requestId usage at
                        Event.FinishReason reason -> Core.FinishReason requestId reason
                        Event.ProviderError _ -> Core.Delta requestId ""
                in Core.update msg current |> (\( updated, _, _ ) -> ( updated, problem ))
    in List.foldl apply ( core, Nothing ) (OpenRouter.decodeEvents value)

update : Msg -> Model -> ( Model, Cmd Msg )
update (Incoming value) model =
    let
        tag = D.decodeValue (D.field "type" D.string) value |> Result.withDefault ""
        str key = D.decodeValue (D.field key D.string) value |> Result.withDefault ""
        at = str "at"
        respond ok error = outgoing (E.object [ ( "type", E.string "ActionResult" ), ( "actionId", E.string (str "actionId") ), ( "clientId", E.string (str "clientId") ), ( "ok", E.bool ok ), ( "error", E.string error ) ])
        acknowledged ( next, commands ) = ( next, Cmd.batch [ commands, if String.isEmpty (str "actionId") then Cmd.none else respond True "" ] )
        apply msg =
            case Protocol.validate msg model.core of
                Err reason -> ( model, respond False reason )
                Ok () -> applyValidated msg
        applyValidated msg =
            let
                ( updatedCore, emitted, event ) = Core.update msg model.core
                ( core, queuedEffects ) = Core.schedule updatedCore
                effects = emitted ++ queuedEffects
                next = { model | core = core, user = if model.preservedUser /= Nothing then model.user else Dict.values core.nodes |> List.filter (\node -> not (Dict.member node.id model.core.nodes)) |> List.sortBy (\node -> String.dropLeft 1 node.id |> String.toInt |> Maybe.withDefault 0) |> List.foldl (\node user -> User.onEvent (Public.NodeCommitted (Projection.node node)) user) model.user, serial = model.serial + 1 }
            in acknowledged (publish next effects)
    in
    if not (String.isEmpty model.error) then ( model, Cmd.batch [ broadcast model, if String.isEmpty (str "actionId") then Cmd.none else respond False model.error ] ) else
    case tag of
        "OpenWorkspace" ->
            if String.isEmpty (String.trim (str "path")) then
                let next = { model | notice = "Provide a workspace directory path" } in ( next, broadcast next )
            else
                let
                    id = "workspace-" ++ String.fromInt (model.serial + 1)
                    pending = { path = str "path", fresh = D.decodeValue (D.field "newChat" D.bool) value |> Result.withDefault False, title = str "title", modelName = str "model", clientId = str "clientId", token = str "token" }
                    next = { model | pending = Dict.insert id pending model.pending, serial = model.serial + 1, notice = "" }
                in acknowledged ( next, Cmd.batch [ broadcast next, outgoing (E.object [ ( "type", E.string "ReadWorkspace" ), ( "requestId", E.string id ), ( "path", E.string pending.path ) ]) ] )
        "WorkspaceLoaded" ->
            let
                root = str "root"
                prompt = Prompt.build root (str "system") (str "append") (str "project")
                ( registered, _, _ ) = Core.update (Core.RegisterWorkspace root prompt) model.core
            in
            if str "requestId" == "restore" then
                let next = { model | core = registered, serial = model.serial + 1 } in publish next []
            else case Dict.get (str "requestId") model.pending of
                Nothing -> ( model, Cmd.none )
                Just pending ->
                    let
                        existing = Dict.values registered.threads |> List.filter (\thread -> thread.workspace == root) |> DateTime.newestFirst |> List.head
                        ( core, _, _ ) = if pending.fresh || existing == Nothing then Core.update (Core.NewChatIn root pending.title pending.modelName at) registered else ( registered, [], Nothing )
                        threadId = if pending.fresh || existing == Nothing then core.focused else Maybe.map .id existing |> Maybe.withDefault core.focused
                        navigation = E.object [ ( "token", E.string pending.token ), ( "threadId", E.string threadId ), ( "root", E.string root ), ( "error", E.string "" ) ]
                        next = { model | core = core, pending = Dict.remove (str "requestId") model.pending, navigations = Dict.insert pending.clientId navigation model.navigations, notice = "", serial = model.serial + 1 }
                    in publish next []
        "WorkspaceFailed" ->
            case Dict.get (str "requestId") model.pending of
                Nothing -> let next = { model | notice = "Cannot reopen workspace: " ++ str "error" } in ( next, broadcast next )
                Just pending ->
                    let
                        navigation = E.object [ ( "token", E.string pending.token ), ( "threadId", E.string "" ), ( "root", E.string "" ), ( "error", E.string (str "error") ) ]
                        next = { model | pending = Dict.remove (str "requestId") model.pending, navigations = Dict.insert pending.clientId navigation model.navigations, notice = str "error" }
                    in ( next, broadcast next )
        "RunnerFrame" -> apply (Core.RunnerFrame (str "jobId") (D.decodeValue (D.field "attempt" D.int) value |> Result.withDefault 0) (D.decodeValue (D.field "sequence" D.int) value |> Result.withDefault 0) (D.decodeValue (D.field "data" D.value) value |> Result.withDefault E.null) at)
        "RunnerExit" -> apply (Core.RunnerExit (str "jobId") (D.decodeValue (D.field "attempt" D.int) value |> Result.withDefault 0) (D.decodeValue (D.field "ok" D.bool) value |> Result.withDefault False) (str "error") at)
        "Chunk" ->
            let
                data = D.decodeValue (D.field "data" D.value) value |> Result.withDefault E.null
                ( core, problem ) = chunk (str "requestId") at data model.core
                next = { model | core = core }
            in case problem of
                Just reason -> update (Incoming (E.object [ ( "type", E.string "Failed" ), ( "requestId", E.string (str "requestId") ), ( "error", E.string reason ), ( "at", E.string at ) ])) { model | core = core }
                Nothing -> ( next, broadcast next )
        "Finished" -> apply (Core.Finished (str "requestId") at)
        "Failed" -> apply (Core.Failed (str "requestId") (str "error") at)
        "ToolFinished" ->
            let
                matches = String.isEmpty (str "runId") || (Dict.get (str "runId") model.core.runs |> Maybe.map (\run -> run.threadId == str "threadId" && List.member (str "callId") run.pending) |> Maybe.withDefault False)
                ok = D.decodeValue (D.field "ok" D.bool) value |> Result.withDefault False
            in if not matches then ( model, Cmd.none ) else if String.isEmpty (str "threadId") then apply (Core.ToolFinished (str "callId") (str "text") ok at) else apply (Core.ToolFinishedIn (str "threadId") (str "callId") (str "text") ok at)
        "Saved" ->
            let
                serial = D.decodeValue (D.field "serial" D.int) value |> Result.withDefault -1
                ready = Dict.toList model.awaitingSave |> List.filter (\( revision, _ ) -> revision <= serial && serial <= model.serial) |> List.concatMap Tuple.second
                next = { model | awaitingSave = Dict.filter (\revision _ -> revision > serial) model.awaitingSave }
            in if serial < 0 || serial > model.serial then ( model, Cmd.none ) else ( next, ready |> List.filter (\prepared -> stillCurrent model.core prepared) |> List.map (.payload >> outgoing) |> Cmd.batch )
        "StorageFailed" -> let next = { model | error = str "error", awaitingSave = Dict.empty } in ( next, broadcast next )
        "ToggleCount" -> update (Incoming (E.object [ ( "type", E.string "UserAction" ), ( "action", E.string "ToggleCount" ), ( "threadId", E.string (str "threadId") ), ( "actionId", E.string (str "actionId") ), ( "clientId", E.string (str "clientId") ) ])) model
        "UserAction" ->
            if model.preservedUser /= Nothing then ( model, respond False "Session plugin is disabled; its original saved data is preserved" ) else
            case D.decodeValue User.msgDecoder value of
                Err problem -> ( model, respond False (D.errorToString problem) )
                Ok msg ->
                    let
                        pluginApp = Projection.state model.core
                        context = { pluginApp | focused = if Dict.member (str "threadId") pluginApp.threads then str "threadId" else pluginApp.focused }
                        ( user, actions ) = User.update context msg model.user
                        applyAction action ( current, accumulated ) =
                            let coreMsg = case action of
                                    Public.NewChat title modelName workspace -> Core.NewChatIn workspace title modelName at
                                    Public.SetPermissions thread policy -> Core.SetPolicy thread policy at
                                ( nextCore, commands, _ ) = Core.update coreMsg current
                            in ( nextCore, accumulated ++ commands )
                        ( core, effects ) = List.foldl applyAction ( model.core, [] ) actions
                        next = { model | user = user, core = core, serial = model.serial + 1 }
                    in acknowledged (publish next effects)
        "NewChat" ->
            if not (String.isEmpty (str "workspace")) && not (Dict.member (str "workspace") model.core.workspaces) then
                update (Incoming (E.object [ ( "type", E.string "OpenWorkspace" ), ( "path", E.string (str "workspace") ), ( "actionId", E.string (str "actionId") ), ( "newChat", E.bool True ), ( "title", E.string (str "title") ), ( "model", E.string (str "model") ), ( "clientId", E.string (str "clientId") ), ( "token", E.string (str "token") ) ])) model
            else case D.decodeValue Protocol.action value of
                Ok msg -> apply msg
                Err problem -> ( model, respond False (D.errorToString problem) )
        _ -> case D.decodeValue Protocol.action value of
            Ok msg -> apply msg
            Err problem -> ( model, respond False (D.errorToString problem) )

snapshot : Model -> E.Value
snapshot model = E.object [ ( "public", Projection.encode model.core (if model.user.showCount then model.user.replies else -1) model.error ), ( "protocolVersion", E.int 1 ), ( "document", Protocol.document model.core model.user model.preservedUser ), ( "view", Core.view model.core ), ( "extension", User.encode model.user ), ( "pluginError", E.string model.pluginError ), ( "error", E.string model.error ), ( "runs", E.list (\r -> E.object [ ( "id", E.string r.id ), ( "threadId", E.string r.threadId ), ( "status", E.string (Status.name r.status) ), ( "draft", E.string r.draft ), ( "pending", E.list E.string r.pending ), ( "purpose", E.string r.purpose ) ]) (Dict.values model.core.runs |> List.sortBy (\r -> String.dropLeft 1 r.id |> String.toInt |> Maybe.withDefault 0)) ), ( "prompt", E.string model.core.systemPrompt ), ( "workspaceNotice", E.string model.notice ), ( "navigations", E.dict identity identity model.navigations ), ( "compactions", E.dict identity (\draft -> E.object [ ( "requestId", E.string draft.requestId ), ( "sourceHead", E.string draft.sourceHead ), ( "text", E.string draft.text ), ( "status", E.string draft.status ), ( "error", E.string draft.error ), ( "before", E.int draft.before ), ( "after", E.int draft.after ) ]) model.core.compactions ) ]

broadcast : Model -> Cmd Msg
broadcast model = outgoing (E.object [ ( "type", E.string "Snapshot" ), ( "data", snapshot model ) ])

save : Model -> Cmd Msg
save model = if String.isEmpty model.error then outgoing (E.object [ ( "type", E.string "Persist" ), ( "serial", E.int model.serial ), ( "document", Protocol.document model.core model.user model.preservedUser ) ]) else Cmd.none

publish : Model -> List Core.Effect -> ( Model, Cmd Msg )
publish model effects =
    let
        deferred command = case command of
            Core.Request _ _ _ _ -> True
            Core.Execute _ _ _ _ _ -> True
            Core.External (Runner.Launch _ _) -> True
            _ -> False
        pending = effects |> List.filter deferred |> List.map (\command -> { effect = command, payload = effect model command })
        next = if List.isEmpty pending then model else { model | awaitingSave = Dict.insert model.serial pending model.awaitingSave }
        immediate = List.filter (deferred >> not) effects |> List.map (effect model >> outgoing)
    in ( next, Cmd.batch (broadcast next :: save next :: immediate) )

stillCurrent : Core.Model -> Prepared -> Bool
stillCurrent core prepared = case prepared.effect of
    Core.External (Runner.Launch job _) -> Runner.current job.id job.attempt core.runners
    Core.Request requestId _ _ _ -> Dict.values core.runs |> List.any (\run -> run.requestId == requestId && Status.receiving run.status)
    Core.Execute threadId callId _ _ _ ->
        D.decodeValue (D.field "runId" D.string) prepared.payload |> Result.toMaybe |> Maybe.andThen (\id -> Dict.get id core.runs) |> Maybe.map (\run -> run.threadId == threadId && Status.active run.status && List.member callId run.pending) |> Maybe.withDefault False
    _ -> True

effect : Model -> Core.Effect -> E.Value
effect model command =
    case command of
        Core.External (Runner.Launch job input) ->
            let spec = RunnerProtocol.specification job input in
            E.object [ ( "type", E.string "LaunchRunner" ), ( "jobId", E.string job.id ), ( "attempt", E.int job.attempt ), ( "backend", E.string spec.backend ), ( "args", E.list E.string spec.args ), ( "input", E.string spec.input ), ( "root", E.string spec.root ), ( "profile", E.string spec.profile ) ]
        Core.External (Runner.Stop id attempt) -> E.object [ ( "type", E.string "StopRunner" ), ( "jobId", E.string id ), ( "attempt", E.int attempt ) ]
        Core.Request requestId threadId modelName messages ->
            let
                isCompaction = Dict.values model.core.runs |> List.any (\run -> run.requestId == requestId && run.purpose == "compaction")
                policy = Dict.get threadId model.core.threads |> Maybe.map .policy |> Maybe.withDefault Policy.default
            in E.object [ ( "type", E.string "Request" ), ( "requestId", E.string requestId ), ( "threadId", E.string threadId ), ( "body", OpenRouter.request modelName isCompaction policy messages ) ]
        Core.Abort requestId -> E.object [ ( "type", E.string "Abort" ), ( "requestId", E.string requestId ) ]
        Core.AbortTool threadId callId -> E.object [ ( "type", E.string "Abort" ), ( "requestId", E.string (threadId ++ ":tool:" ++ callId) ) ]
        Core.PublishPolicy threadId ->
            let thread = Dict.get threadId model.core.threads
            in E.object [ ( "type", E.string "ToolPolicy" ), ( "threadId", E.string threadId ), ( "revision", E.int model.core.revision ), ( "policy", thread |> Maybe.map (.policy >> Policy.encode) |> Maybe.withDefault (Policy.encode Policy.readOnly) ) ]
        Core.Execute threadId callId name args approved ->
            let
                thread = Dict.get threadId model.core.threads
                root = thread |> Maybe.map .workspace |> Maybe.withDefault model.core.defaultWorkspace
                runId = Dict.values model.core.runs |> List.filter (\run -> run.threadId == threadId && List.member callId run.pending) |> List.head |> Maybe.map .id |> Maybe.withDefault ""
            in E.object [ ( "runId", E.string runId ), ( "root", E.string root ), ( "threadId", E.string (thread |> Maybe.map .id |> Maybe.withDefault "") ), ( "policyRevision", E.int model.core.revision ), ( "policy", thread |> Maybe.map (.policy >> Policy.encode) |> Maybe.withDefault (Policy.encode Policy.readOnly) ), ( "type", E.string "Execute" ), ( "callId", E.string callId ), ( "name", E.string name ), ( "args", args ), ( "approved", E.bool approved ) ]

main : Program E.Value Model Msg
main = Platform.worker { init = init, update = update, subscriptions = \_ -> incoming Incoming }
