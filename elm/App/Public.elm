module App.Public exposing (Model, Node, Thread, Run, SummaryDraft, Action(..), ActionResult(..), resultDecoder, Event(..), init, snapshotDecoder, runDecoder, summaryDecoder, visibleNodes, ancestry, pendingApprovals, contextReport, usageTotals, encodeAction, conversations)

{-| Shared, read-only application types. Clients and plugins depend on this module,
not Core or the saved-document format. Public actions are requests, not mutations.
-}
import Runner.Types as Jobs
import Accounting
import App.DateTime as DateTime
import App.RunStatus as Status exposing (Status)
import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Policy

type alias Node = { id : String, parentId : Maybe String, refs : List String, threadId : String, actor : String, kind : String, text : String, at : String }
type alias Thread = { id : String, head : String, forkedFrom : Maybe String, title : String, model : String, workspace : String, policy : Policy.Model, contextBudget : Int, estimatedInput : Int, prompt : String, report : String, usage : Accounting.Totals, createdAt : String, updatedAt : String }
type alias Run = { id : String, threadId : String, status : Status, draft : String, pending : List String, purpose : String }
type alias SummaryDraft = { requestId : String, sourceHead : String, text : String, status : String, error : String, before : Int, after : Int }
type alias Model = { jobs : List Jobs.Job, runnerCapabilities : Dict String Jobs.Capability, nodes : Dict String Node, threads : Dict String Thread, defaultWorkspace : String, workspaces : Dict String String, focused : String, selected : String, filter : String }
type Action = NewChat String String String | SetPermissions String Policy.Model
type ActionResult = Accepted String | Rejected String String

resultDecoder : D.Decoder ActionResult
resultDecoder = D.map3 (\id ok error -> if ok then Accepted id else Rejected id error) (D.field "actionId" D.string) (D.field "ok" D.bool) (D.field "error" D.string)

type Event = NodeCommitted Node

init : Model
init = { jobs = [], runnerCapabilities = Dict.empty, nodes = Dict.empty, threads = Dict.empty, defaultWorkspace = "", workspaces = Dict.empty, focused = "t1", selected = "n1", filter = "all" }

encodeAction : Action -> E.Value
encodeAction action = case action of
    NewChat title model workspace -> E.object [ ( "type", E.string "NewChat" ), ( "title", E.string title ), ( "model", E.string model ), ( "workspace", E.string workspace ) ]
    SetPermissions thread policy -> E.object [ ( "type", E.string "SetPolicy" ), ( "threadId", E.string thread ), ( "policy", Policy.encode policy ) ]

nodeDecoder : D.Decoder Node
nodeDecoder = D.map8 Node (D.field "id" D.string) (D.field "parentId" (D.nullable D.string)) (D.field "refs" (D.list D.string)) (D.field "threadId" D.string) (D.field "actor" D.string) (D.field "kind" D.string) (D.field "text" D.string) (D.field "at" D.string)

totalsDecoder : D.Decoder Accounting.Totals
totalsDecoder = D.map6 Accounting.Totals (D.field "input" D.int) (D.field "output" D.int) (D.field "total" D.int) (D.field "cost" D.float) (D.field "reports" D.int) (D.field "costReports" D.int)

threadDecoder : D.Decoder Thread
threadDecoder =
    D.map8 Thread (D.field "id" D.string) (D.field "head" D.string) (D.field "forkedFrom" (D.nullable D.string)) (D.field "title" D.string) (D.field "model" D.string) (D.field "workspace" D.string) (D.field "policy" Policy.decoder) (D.field "contextBudget" D.int)
        |> D.andThen (\partial -> D.map4 partial (D.field "estimatedInput" D.int) (D.field "prompt" D.string) (D.field "report" D.string) (D.field "usage" totalsDecoder))
        |> D.andThen (\partial -> D.map2 partial (D.oneOf [ D.field "createdAt" D.string, D.succeed "" ]) (D.oneOf [ D.field "updatedAt" D.string, D.succeed "" ]))

runDecoder : D.Decoder Run
runDecoder = D.map6 Run (D.field "id" D.string) (D.field "threadId" D.string) (D.field "status" Status.decoder) (D.field "draft" D.string) (D.field "pending" (D.list D.string)) (D.field "purpose" D.string)

summaryDecoder : D.Decoder SummaryDraft
summaryDecoder = D.map7 SummaryDraft (D.field "requestId" D.string) (D.field "sourceHead" D.string) (D.field "text" D.string) (D.field "status" D.string) (D.field "error" D.string) (D.field "before" D.int) (D.field "after" D.int)

modelDecoder : D.Decoder Model
modelDecoder = D.map7 (\nodes threads root workspaces focused selected filter -> { jobs = [], runnerCapabilities = Dict.empty, nodes = nodes, threads = threads, defaultWorkspace = root, workspaces = workspaces, focused = focused, selected = selected, filter = filter }) (D.field "nodes" (D.dict nodeDecoder)) (D.field "threads" (D.dict threadDecoder)) (D.field "defaultWorkspace" D.string) (D.field "workspaces" (D.dict D.string)) (D.field "focused" D.string) (D.field "selected" D.string) (D.field "filter" D.string)

    |> D.andThen (\model -> D.map2 (\jobs capabilities -> { model | jobs = jobs, runnerCapabilities = capabilities }) (D.oneOf [ D.field "jobs" (D.list Jobs.jobDecoder), D.succeed [] ]) (D.oneOf [ D.field "runnerCapabilities" Jobs.capabilitiesDecoder, D.succeed Dict.empty ]))

snapshotDecoder : D.Decoder { core : Model, runs : List Run, prompt : String, error : String, count : Int }
snapshotDecoder = D.field "public" (D.field "apiVersion" D.int |> D.andThen (\version ->
    if version /= 1 then D.fail "Unsupported public projection version" else
    D.map5 (\core runs error count prompt -> { core = core, runs = runs, error = error, count = count, prompt = prompt }) (D.field "state" modelDecoder) (D.field "runs" (D.list runDecoder)) (D.field "error" D.string) (D.field "replyCount" D.int) (D.field "prompt" D.string)))

ancestry : Model -> String -> List Node
ancestry model head =
    let walk id seen acc = if List.member id seen then acc else case Dict.get id model.nodes of
            Nothing -> acc
            Just node -> Maybe.map (\parent -> walk parent (id :: seen) (node :: acc)) node.parentId |> Maybe.withDefault (node :: acc)
    in walk head [] []

visibleNodes : Model -> List Node
visibleNodes model = Dict.values model.nodes |> List.sortBy (\node -> String.dropLeft 1 node.id |> String.toInt |> Maybe.withDefault 0) |> List.reverse |> List.filter (\node -> model.filter == "all" || (model.filter == "messages" && List.member node.kind [ "UserMessage", "AgentMessage", "Handoff", "RunnerResult" ]) || (model.filter == "tools" && List.member node.kind [ "ToolCall", "ToolResult" ]) || (model.filter == "errors" && node.kind == "Notice"))

pendingApprovals : String -> List String -> Model -> List Node
pendingApprovals threadId pending model =
    let step node approvals =
            if node.kind == "ToolCall" then [] else if node.kind == "Approval" then approvals ++ [ node ] else if node.kind == "Activity" then List.filter (\approval -> D.decodeString (D.field "id" D.string) approval.text |> Result.map (\id -> not (String.startsWith (id ++ ":") node.text)) |> Result.withDefault False) approvals else approvals
    in Dict.get threadId model.threads |> Maybe.map (\thread -> List.foldl step [] (ancestry model thread.head) |> List.filter (\node -> D.decodeString (D.field "id" D.string) node.text |> Result.map (\id -> List.member id pending) |> Result.withDefault False)) |> Maybe.withDefault []

contextReport : Model -> String -> String
contextReport model id = Dict.get id model.threads |> Maybe.map .report |> Maybe.withDefault "Chat not found"
usageTotals : Model -> String -> Accounting.Totals
usageTotals model id = Dict.get id model.threads |> Maybe.map .usage |> Maybe.withDefault (Accounting.totals [])

conversations : Model -> List Thread
conversations model = Dict.values model.threads |> DateTime.newestFirst
