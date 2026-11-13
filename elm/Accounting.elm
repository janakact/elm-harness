module Accounting exposing (Report, Usage, Totals, decoder, encode, totals, estimate, money)

import Char
import Json.Decode as D
import Json.Encode as E

type alias Report = { input : Int, output : Int, total : Int, cost : Maybe Float }

type alias Usage = { requestId : String, threadId : String, model : String, purpose : String, input : Int, output : Int, total : Int, cost : Maybe Float, at : String }
type alias Totals = { input : Int, output : Int, total : Int, cost : Float, reports : Int, costReports : Int }

-- A local sizing heuristic, never a claim to match the selected model's tokenizer.
estimate : String -> Int
estimate source =
    let ( ascii, other ) = String.foldl (\char ( a, b ) -> if Char.toCode char < 128 then ( a + 1, b ) else ( a, b + 1 )) ( 0, 0 ) source
    in ceiling (toFloat ascii / 4) + other

optional : String -> D.Decoder a -> a -> D.Decoder a
optional key value fallback = D.keyValuePairs D.value |> D.andThen (\fields -> if List.any (\( field, _ ) -> field == key) fields then D.field key value else D.succeed fallback)

decoder : D.Decoder Usage
decoder =
    D.map8 (\id thread model purpose input output total rest -> { requestId = id, threadId = thread, model = model, purpose = purpose, input = input, output = output, total = total, cost = Tuple.first rest, at = Tuple.second rest })
        (D.field "requestId" D.string) (D.field "threadId" D.string) (D.field "model" D.string) (D.field "purpose" D.string)
        (D.field "input" D.int) (D.field "output" D.int) (D.field "total" D.int)
        (D.map2 Tuple.pair (D.field "cost" (D.nullable D.float)) (D.field "at" D.string))
        |> D.andThen (\usage -> if usage.input < 0 || usage.output < 0 || usage.total < 0 || (usage.cost |> Maybe.map ((>) 0) |> Maybe.withDefault False) then D.fail "Invalid usage accounting" else D.succeed usage)

encode : Usage -> E.Value
encode usage = E.object [ ( "requestId", E.string usage.requestId ), ( "threadId", E.string usage.threadId ), ( "model", E.string usage.model ), ( "purpose", E.string usage.purpose ), ( "input", E.int usage.input ), ( "output", E.int usage.output ), ( "total", E.int usage.total ), ( "cost", Maybe.map E.float usage.cost |> Maybe.withDefault E.null ), ( "at", E.string usage.at ) ]

totals : List Usage -> Totals
totals records = List.foldl (\usage acc -> { input = acc.input + usage.input, output = acc.output + usage.output, total = acc.total + usage.total, cost = acc.cost + Maybe.withDefault 0 usage.cost, reports = acc.reports + 1, costReports = acc.costReports + (if usage.cost == Nothing then 0 else 1) }) { input = 0, output = 0, total = 0, cost = 0, reports = 0, costReports = 0 } records

money : Float -> String
money value = if value > 0 && value < 0.000001 then String.fromFloat value else String.fromFloat (toFloat (round (value * 1000000)) / 1000000)
