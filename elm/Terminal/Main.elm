port module Terminal.Main exposing (main)

import Core
import Dict
import Json.Decode as D
import Json.Encode as E
import Platform
import Protocol
import Rich

port incoming : (E.Value -> msg) -> Sub msg
port outgoing : E.Value -> Cmd msg

type alias Model = { core : Core.Model, selected : String, focused : String, runs : List E.Value, error : String, pendingNew : Bool }
type Msg = Incoming E.Value

init : () -> ( Model, Cmd Msg )
init _ = ( { core = Core.init, selected = "n1", focused = "t1", runs = [], error = "", pendingNew = False }, Cmd.none )

update : Msg -> Model -> ( Model, Cmd Msg )
update (Incoming event) model =
    let
        tag = D.decodeValue (D.field "type" D.string) event |> Result.withDefault ""
        line = D.decodeValue (D.field "line" D.string) event |> Result.withDefault ""
        words = String.words line
        argument = List.drop 1 words |> String.join " "
        send kind fields = outgoing (E.object [ ( "type", E.string "Action" ), ( "data", E.object (( "type", E.string kind ) :: fields) ) ])
        str key content = ( key, E.string content )
        unchanged cmd = ( model, cmd )
    in
    if tag == "Snapshot" then
        case D.decodeValue (D.field "data" (D.map2 Tuple.pair (D.field "document" Protocol.documentDecoder) (D.field "runs" (D.list D.value)))) event of
            Ok ( ( core, _ ), runs ) ->
                let
                    created = if model.pendingNew then Dict.values core.threads |> List.filter (\t -> not (Dict.member t.id model.core.threads)) |> List.head else Nothing
                    next = { model | core = core, runs = runs, pendingNew = model.pendingNew && created == Nothing, focused = Maybe.map .id created |> Maybe.withDefault model.focused, selected = Maybe.map .head created |> Maybe.withDefault model.selected }
                in ( next, render next )
            Err error -> unchanged (outgoing (E.object [ ( "type", E.string "Draw" ), ( "text", E.string (D.errorToString error) ) ]))
    else case List.head words of
        Just "/new" -> ( { model | pendingNew = True }, send "NewChat" [ str "title" argument, str "model" (Dict.get model.focused model.core.threads |> Maybe.map .model |> Maybe.withDefault "deepseek/deepseek-v4-flash") ] )
        Just "/focus" -> let next = { model | focused = argument } in ( next, render next )
        Just "/select" -> let next = { model | selected = argument } in ( next, render next )
        Just "/fork" -> unchanged (send "Fork" [ str "nodeId" model.selected, str "title" argument, str "task" "" ])
        Just "/model" -> unchanged (send "SetModel" [ str "threadId" model.focused, str "model" argument ])
        Just "/approve" -> unchanged (send "Approve" [ str "callId" argument, ( "allowed", E.bool True ) ])
        Just "/deny" -> unchanged (send "Approve" [ str "callId" argument, ( "allowed", E.bool False ) ])
        Just "/cancel" -> unchanged (send "Cancel" [ str "runId" argument ])
        Just "/compact" -> unchanged (send "Compact" [ str "threadId" model.focused, str "text" argument ])
        Just "/send" -> unchanged (send "Send" [ str "from" model.focused, str "target" (List.drop 1 words |> List.head |> Maybe.withDefault "t1"), str "text" (List.drop 2 words |> String.join " "), ( "refs", E.list E.string [ model.selected ] ) ])
        Just _ -> unchanged (send "Submit" [ str "threadId" model.focused, str "text" line ])
        Nothing -> unchanged Cmd.none

render : Model -> Cmd Msg
render model =
    let
        nodes = Core.visibleNodes model.core |> List.reverse
        nodeLine n = (if n.id == model.selected then "› " else "  ") ++ n.id ++ " [" ++ n.threadId ++ "] " ++ n.kind ++ " " ++ String.left 80 (String.lines n.text |> List.head |> Maybe.withDefault "")
        detail = Dict.get model.selected model.core.nodes |> Maybe.map (\n -> Rich.terminal n.text) |> Maybe.withDefault ""
        drafts = model.runs |> List.filterMap (\v -> D.decodeValue (D.field "draft" D.string) v |> Result.toMaybe) |> String.join "\n"
        threads = Dict.values model.core.threads |> List.map (\t -> t.id ++ " " ++ t.title) |> String.join " · "
    in outgoing (E.object [ ( "type", E.string "Draw" ), ( "text", E.string ("λ ELM HARNESS  |  " ++ threads ++ "\n" ++ String.join "\n" (List.map nodeLine nodes) ++ "\n\nSelected " ++ model.selected ++ ":\n" ++ detail ++ "\n" ++ drafts ++ "\n\n/new [TITLE]  /focus ID  /select NODE  /fork TITLE  /model ID  /approve CALL  /deny CALL\n/cancel RUN  /compact SUMMARY  /send THREAD MESSAGE · plain text sends a prompt\n") ) ])

main : Program () Model Msg
main = Platform.worker { init = init, update = update, subscriptions = \_ -> incoming Incoming }
