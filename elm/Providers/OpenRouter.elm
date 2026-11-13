module Providers.OpenRouter exposing (decodeEvents, encodeMessages, request)

import Agent.Event exposing (Event(..))
import Agent.Message exposing (Message(..))
import Json.Decode as D
import Json.Encode as E
import Policy
import Prompt

encodeMessages : List Message -> E.Value
encodeMessages messages =
    let text role content = E.object [ ( "role", E.string role ), ( "content", E.string content ) ]
        message item = case item of
            System content -> text "system" content
            User content -> text "user" content
            Assistant content -> text "assistant" content
            ToolCalls calls -> E.object [ ( "role", E.string "assistant" ), ( "content", E.null ), ( "tool_calls", E.list (\call -> E.object [ ( "id", E.string call.id ), ( "type", E.string "function" ), ( "function", E.object [ ( "name", E.string call.name ), ( "arguments", E.string call.arguments ) ] ) ]) calls ) ]
            ToolResult id content -> E.object [ ( "role", E.string "tool" ), ( "tool_call_id", E.string id ), ( "content", E.string content ) ]
    in E.list message messages

request : String -> Bool -> Policy.Model -> List Message -> E.Value
request model summary policy messages = E.object [ ( "model", E.string model ), ( "messages", encodeMessages messages ), ( "tools", if summary then E.list identity [] else Prompt.toolsFor policy ), ( "stream", E.bool True ), ( "parallel_tool_calls", E.bool False ), ( "max_tokens", E.int (if summary then 4096 else 8192) ) ]

decodeEvents : E.Value -> List Event
decodeEvents value =
    let get decoder fallback = D.decodeValue decoder value |> Result.withDefault fallback
        text = get (D.at [ "choices" ] (D.index 0 (D.at [ "delta", "content" ] D.string))) ""
        callDecoder = D.map4 ToolFragment (D.oneOf [ D.field "index" D.int, D.succeed 0 ]) (D.oneOf [ D.field "id" D.string, D.succeed "" ]) (D.oneOf [ D.at [ "function", "name" ] D.string, D.succeed "" ]) (D.oneOf [ D.at [ "function", "arguments" ] D.string, D.succeed "" ])
        calls = get (D.at [ "choices" ] (D.index 0 (D.at [ "delta", "tool_calls" ] (D.list callDecoder)))) []
        optional key decoder fallback = D.keyValuePairs D.value |> D.andThen (\fields -> if List.any (\( field, _ ) -> field == key) fields then D.field key decoder else D.succeed fallback)
        reportDecoder = D.map4 (\input output total cost -> { input = input, output = output, total = Maybe.withDefault (input + output) total, cost = cost }) (D.field "prompt_tokens" D.int) (D.field "completion_tokens" D.int) (optional "total_tokens" (D.nullable D.int) Nothing) (optional "cost" (D.nullable D.float) Nothing)
        usage = D.decodeValue (D.field "usage" reportDecoder) value |> Result.toMaybe |> Maybe.map Usage
        reason = D.decodeValue (D.at [ "choices" ] (D.index 0 (D.field "finish_reason" D.string))) value |> Result.toMaybe |> Maybe.map FinishReason
        error = D.decodeValue (D.at [ "error", "message" ] D.string) value |> Result.toMaybe |> Maybe.map ProviderError
    in (if String.isEmpty text then [] else [ Text text ]) ++ calls ++ List.filterMap identity [ usage, reason, error ]
