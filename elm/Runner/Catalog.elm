module Runner.Catalog exposing (Model, decoder, cacheDecoder, options, encode)

{-| Model choices are normalized in Elm. The host reads only the CLI's local
catalog; selecting a model never requires a paid request.
-}
import Dict
import Json.Decode as D
import Json.Encode as E

type alias Model = { id : String, label : String }

decoder : D.Decoder Model
decoder = D.map2 Model (D.field "id" D.string) (D.field "label" D.string)

cacheDecoder : D.Decoder (List Model)
cacheDecoder = D.field "models" (D.list (D.map3 (\id label visibility -> ( { id = id, label = label }, visibility ))
    (D.field "slug" D.string)
    (D.oneOf [ D.field "display_name" D.string, D.field "slug" D.string ])
    (D.oneOf [ D.field "visibility" D.string, D.succeed "list" ])))
    |> D.map (List.filter (Tuple.second >> (==) "list") >> List.map Tuple.first)

options : String -> List Model -> List Model
options backend discovered =
    let candidates = if List.isEmpty discovered && backend == "claude" then [ Model "sonnet" "Sonnet", Model "opus" "Opus", Model "haiku" "Haiku" ] else discovered
        add choice ( seen, result ) =
            if String.isEmpty choice.id || String.startsWith "-" choice.id || String.length choice.id > 200 || Dict.member choice.id seen then ( seen, result ) else ( Dict.insert choice.id () seen, result ++ [ choice ] )
    in List.foldl add ( Dict.empty, [] ) candidates |> Tuple.second

encode : Model -> E.Value
encode model = E.object [ ( "id", E.string model.id ), ( "label", E.string model.label ) ]
