module Agent.Context exposing (build, serialize)

import Agent.Message exposing (Message(..), Call)
import Json.Decode as D
import Json.Encode as E

build : String -> List { node | id : String, kind : String, text : String } -> List Message
build prompt nodes =
    let
        lastSummary = nodes |> List.filter (\n -> n.kind == "Summary") |> List.reverse |> List.head
        number id = String.dropLeft 1 id |> String.toInt |> Maybe.withDefault 0
        relevant = case lastSummary of
            Nothing -> nodes
            Just summary -> List.filter (\node -> number node.id >= number summary.id) nodes
        callDecoder = D.map3 Call (D.field "id" D.string) (D.at [ "function", "name" ] D.string) (D.at [ "function", "arguments" ] D.string)
        message node = case node.kind of
            "ToolCall" -> D.decodeString (D.list callDecoder) node.text |> Result.toMaybe |> Maybe.map ToolCalls
            "ToolResult" -> D.decodeString (D.map2 ToolResult (D.field "tool_call_id" D.string) (D.field "content" D.string)) node.text |> Result.toMaybe
            "AgentMessage" -> Just (Assistant node.text)
            _ -> if List.member node.kind [ "UserMessage", "Handoff", "Summary" ] then Just (User node.text) else Nothing
    in System prompt :: List.filterMap message relevant

serialize : List Message -> String
serialize messages =
    let text role content = E.object [ ( "role", E.string role ), ( "text", E.string content ) ]
        encode message = case message of
            System content -> text "system" content
            User content -> text "user" content
            Assistant content -> text "assistant" content
            ToolCalls calls -> E.object [ ( "role", E.string "tool-calls" ), ( "calls", E.list (\call -> E.object [ ( "id", E.string call.id ), ( "name", E.string call.name ), ( "arguments", E.string call.arguments ) ]) calls ) ]
            ToolResult id content -> E.object [ ( "role", E.string "tool-result" ), ( "id", E.string id ), ( "text", E.string content ) ]
    in E.encode 0 (E.list encode messages)
