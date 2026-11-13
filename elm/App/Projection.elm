module App.Projection exposing (state, encode, node)

{-| Backend-only mapping. The public contract has no dependency on Core. -}
import App.Public as Public
import App.RunStatus as Status
import Runner
import Runner.Catalog as Catalog
import Runner.Types as Jobs
import Core
import Dict
import Json.Encode as E
import Policy

node : Core.Node -> Public.Node
node source = { id = source.id, parentId = source.parentId, refs = source.refs, threadId = source.threadId, actor = source.actor, kind = source.kind, text = source.text, at = source.at }

state : Core.Model -> Public.Model
state core =
    { jobs = Runner.jobs core.runners, runnerCapabilities = core.runnerCapabilities, nodes = Dict.map (\_ source -> node source) core.nodes
    , threads = Dict.map (\_ thread -> { id = thread.id, head = thread.head, forkedFrom = thread.forkedFrom, title = thread.title, model = thread.model, workspace = thread.workspace, policy = thread.policy, contextBudget = thread.contextBudget, estimatedInput = Core.contextEstimate core thread, prompt = Core.effectivePrompt core thread, report = Core.contextReport core thread.id, usage = Core.usageTotals core thread.id, createdAt = thread.createdAt, updatedAt = thread.updatedAt }) core.threads
    , defaultWorkspace = core.defaultWorkspace, workspaces = Dict.map (\root _ -> root) core.workspaces
    , focused = core.focused, selected = core.selected, filter = core.filter }

encode : Core.Model -> Int -> String -> E.Value
encode core count error =
    let public = state core
        nullable value = Maybe.map E.string value |> Maybe.withDefault E.null
        encodeNode n = E.object [ ( "id", E.string n.id ), ( "parentId", nullable n.parentId ), ( "refs", E.list E.string n.refs ), ( "threadId", E.string n.threadId ), ( "actor", E.string n.actor ), ( "kind", E.string n.kind ), ( "text", E.string n.text ), ( "at", E.string n.at ) ]
        totals u = E.object [ ( "input", E.int u.input ), ( "output", E.int u.output ), ( "total", E.int u.total ), ( "cost", E.float u.cost ), ( "reports", E.int u.reports ), ( "costReports", E.int u.costReports ) ]
        thread t = E.object [ ( "id", E.string t.id ), ( "head", E.string t.head ), ( "forkedFrom", nullable t.forkedFrom ), ( "title", E.string t.title ), ( "model", E.string t.model ), ( "workspace", E.string t.workspace ), ( "policy", Policy.encode t.policy ), ( "contextBudget", E.int t.contextBudget ), ( "createdAt", E.string t.createdAt ), ( "updatedAt", E.string t.updatedAt ), ( "estimatedInput", E.int t.estimatedInput ), ( "prompt", E.string t.prompt ), ( "report", E.string t.report ), ( "usage", totals t.usage ) ]
    in E.object [ ( "apiVersion", E.int 1 ), ( "error", E.string error ), ( "replyCount", E.int count ), ( "prompt", E.string core.systemPrompt )
        , ( "state", E.object [ ( "jobs", E.list Jobs.encodeJob public.jobs ), ( "runnerCapabilities", E.dict identity (\cap -> E.object [ ( "available", E.bool cap.available ), ( "version", E.string cap.version ), ( "error", E.string cap.error ), ( "models", E.list Catalog.encode cap.models ) ]) public.runnerCapabilities ), ( "nodes", E.dict identity encodeNode public.nodes ), ( "threads", E.dict identity thread public.threads ), ( "defaultWorkspace", E.string public.defaultWorkspace ), ( "workspaces", E.dict identity E.string public.workspaces ), ( "focused", E.string public.focused ), ( "selected", E.string public.selected ), ( "filter", E.string public.filter ) ] )
        , ( "runs", E.list (\r -> E.object [ ( "id", E.string r.id ), ( "threadId", E.string r.threadId ), ( "status", E.string (Status.name r.status) ), ( "draft", E.string r.draft ), ( "pending", E.list E.string r.pending ), ( "purpose", E.string r.purpose ) ]) (Dict.values core.runs |> List.sortBy (\r -> String.dropLeft 1 r.id |> String.toInt |> Maybe.withDefault 0)) ) ]
