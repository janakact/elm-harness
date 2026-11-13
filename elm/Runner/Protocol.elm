module Runner.Protocol exposing (Event(..), Spec, specification, decode)

{-| Vendor argv and JSON event semantics live in Elm. The host only frames
JSONL, supervises a process and enforces the read-only mount profile.
-}
import Runner.Types as Types exposing (Backend(..), Job, Usage)
import Json.Decode as D
import Json.Encode as E

type Event = Session String | Snapshot String String | Delta String | Observation String String | Done (Maybe String) (Maybe Usage) | Failure String
type alias Spec = { backend : String, args : List String, input : String, root : String, profile : String }

specification : Job -> String -> Spec
specification job capturedInput =
    let model = if String.isEmpty job.model then [] else [ "--model", job.model ]
        resume = not (String.isEmpty job.sessionId)
        args = case job.backend of
            Codex ->
                [ "--sandbox", "read-only", "--ask-for-approval", "never"
                , "-c", "mcp_servers={}"
                , "-c", "features.multi_agent=false"
                , "-c", "features.hooks=false"
                , "-c", "shell_environment_policy.inherit=\"none\""
                , "exec", "--ignore-user-config", "--ignore-rules", "--json", "--skip-git-repo-check"
                ] ++ model ++ (if resume then [ "resume", job.sessionId, "-" ] else [ "-" ])
            Claude ->
                [ "--print", "--safe-mode", "--restricted", "--disable-slash-commands"
                , "--output-format", "stream-json", "--verbose", "--include-partial-messages"
                , "--tools", "Read,Glob,Grep", "--allowedTools", "Read,Glob,Grep"
                , "--permission-mode", "dontAsk", "--permission-prompts", "none"
                , "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"
                , "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}"
                ] ++ model ++ (if resume then [ "--resume", job.sessionId ] else [])
    in { backend = Types.backendName job.backend, args = args, input = capturedInput, root = job.workspace, profile = "read-only-v1" }

decode : Backend -> E.Value -> Result String (List Event)
decode backend value =
    let str path = D.at path D.string
        optional fieldDecoder fallback = D.oneOf [ fieldDecoder, D.succeed fallback ]
        usage scope = D.map3 (\input output cost -> { input = max 0 input, output = max 0 output, cost = cost, scope = scope })
            (optional (D.field "input_tokens" D.int) 0) (optional (D.field "output_tokens" D.int) 0) (D.succeed Nothing)
        codex tag = case tag of
            "thread.started" -> D.map (Session >> List.singleton) (str [ "thread_id" ])
            "item.started" -> codexItem
            "item.updated" -> codexItem
            "item.completed" -> codexItem
            "turn.completed" -> D.map (\report -> [ Done Nothing (Just report) ]) (D.field "usage" (usage "attempt"))
            "turn.failed" -> D.map (Failure >> List.singleton) (str [ "error", "message" ])
            "error" -> D.map (Failure >> List.singleton) (str [ "message" ])
            _ -> D.succeed []
        codexItem = D.map3 (\id kind text ->
                if kind == "agent_message" then [ Snapshot id text ]
                else if List.member kind [ "command_execution", "file_change", "mcp_tool_call", "web_search" ] then [ Observation id (kind ++ ": " ++ String.left 400 text) ] else [])
            (str [ "item", "id" ]) (str [ "item", "type" ])
            (optional (D.oneOf [ str [ "item", "text" ], str [ "item", "command" ], D.at [ "item" ] D.value |> D.map (E.encode 0) ]) "")
        claude tag = case tag of
            "system" -> D.map2 (\subtype id -> if subtype == "init" then [ Session id ] else []) (optional (str [ "subtype" ]) "") (optional (str [ "session_id" ]) "")
            "stream_event" -> D.map (Delta >> List.singleton) (str [ "event", "delta", "text" ]) |> optionalDecoder []
            "assistant" -> D.map (List.concatMap identity) (D.at [ "message", "content" ] (D.list (D.field "type" D.string |> D.andThen (\kind ->
                if kind == "tool_use" then D.map2 (\id name -> [ Observation id ("tool: " ++ name) ]) (D.field "id" D.string) (D.field "name" D.string) else D.succeed []))))
            "result" -> D.map5 (\isError result session report cost ->
                    [ Session session ] ++ (if isError then [ Failure (if String.isEmpty result then "Claude job failed" else result) ] else [ Done (Just result) (Maybe.map (\u -> { u | cost = cost }) report) ]))
                (optional (D.field "is_error" D.bool) False) (optional (D.field "result" D.string) "")
                (str [ "session_id" ]) (optional (D.field "usage" (usage "runner report; session cost" ) |> D.map Just) Nothing)
                (optional (D.field "total_cost_usd" D.float |> D.map Just) Nothing)
            _ -> D.succeed []
        decoder = D.field "type" D.string |> D.andThen (case backend of
            Codex -> codex
            Claude -> claude)
    in D.decodeValue decoder value |> Result.mapError D.errorToString

optionalDecoder : a -> D.Decoder a -> D.Decoder a
optionalDecoder fallback decoder = D.oneOf [ decoder, D.succeed fallback ]
