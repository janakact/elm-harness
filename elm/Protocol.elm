module Protocol exposing (action, document, documentDecoder)

import Core
import Json.Decode as D
import Json.Encode as E
import User

action : D.Decoder Core.Msg
action =
    let
        str key = D.field key D.string
        at = D.oneOf [ str "at", D.succeed "" ]
    in
    str "type" |> D.andThen (\tag ->
        case tag of
            "NewChat" -> D.map3 Core.NewChat (str "title") (str "model") at
            "Submit" -> D.map3 Core.Submit (str "threadId") (str "text") at
            "Fork" -> D.map4 Core.Fork (str "nodeId") (str "title") (str "task") at
            "Send" -> D.map5 Core.Send (str "from") (str "target") (str "text") (D.field "refs" (D.list D.string)) at
            "SetModel" -> D.map2 Core.SetModel (str "threadId") (str "model")
            "Run" -> D.map Core.RunThread (str "threadId")
            "Cancel" -> D.map Core.Cancel (str "runId")
            "Approve" -> D.map3 Core.Approve (str "callId") (D.field "allowed" D.bool) at
            "Compact" -> D.map3 Core.Compact (str "threadId") (str "text") at
            _ -> D.fail "Unknown action")

document : Core.Model -> User.Model -> E.Value
document core user = E.object [ ( "documentVersion", E.int 1 ), ( "core", E.object [ ( "schemaVersion", E.int 1 ), ( "data", Core.encode core ) ] ), ( "user", E.object [ ( "schemaVersion", E.int 2 ), ( "data", User.encode user ) ] ) ]

documentDecoder : D.Decoder ( Core.Model, User.Model )
documentDecoder =
    D.map4 (\v c u data -> ( v == 1 && c == 1 && List.member u [ 1, 2 ], data ))
        (D.field "documentVersion" D.int) (D.at [ "core", "schemaVersion" ] D.int) (D.at [ "user", "schemaVersion" ] D.int)
        (D.map2 Tuple.pair (D.at [ "core", "data" ] Core.decoder) (D.at [ "user", "data" ] User.decoder))
        |> D.andThen (\( versions, ( core, user ) ) -> if versions && Core.valid core then D.succeed ( core, user ) else D.fail "Unsupported schema or invalid graph; original preserved")
