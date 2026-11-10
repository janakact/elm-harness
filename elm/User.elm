module User exposing (Model, Msg(..), init, update, onEvent, view, encode, decoder)

import Json.Decode as D
import Json.Encode as E

type alias Model = { showCount : Bool, replies : Int }
type Msg = ToggleCount

init : Model
init = { showCount = True, replies = 0 }

update : Msg -> Model -> Model
update msg model =
    case msg of
        ToggleCount -> { model | showCount = not model.showCount }

onEvent : String -> Model -> Model
onEvent event model =
    if event == "AgentMessage" then { model | replies = model.replies + 1 } else model

view : Model -> E.Value
view model =
    E.object [ ( "type", E.string "CustomRegion" ), ( "id", E.string "user" ), ( "title", E.string "Extension" )
    , ( "text", E.string (if model.showCount then "Agent replies: " ++ String.fromInt model.replies else "Count hidden") )
    , ( "action", E.string "ToggleCount" ) ]

encode : Model -> E.Value
encode model = E.object [ ( "showCount", E.bool model.showCount ), ( "replies", E.int model.replies ) ]

decoder : D.Decoder Model
decoder = D.map2 Model (D.field "showCount" D.bool |> D.maybe |> D.map (Maybe.withDefault True)) (D.field "replies" D.int |> D.maybe |> D.map (Maybe.withDefault 0))
