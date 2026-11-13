module App.Ui exposing (Ui(..), map, html, lines, actions)

{-| Small shared view vocabulary. Extend it when a real plugin needs more. -}
import Html exposing (Html)
import Html.Attributes as A
import Html.Events as Events

type Ui msg = Text String | Column (List (Ui msg)) | Button String msg

map : (a -> b) -> Ui a -> Ui b
map fn ui = case ui of
    Text content -> Text content
    Column children -> Column (List.map (map fn) children)
    Button label msg -> Button label (fn msg)

html : Ui msg -> Html msg
html ui = case ui of
    Text content -> Html.div [ A.class "plugin-text" ] [ Html.text content ]
    Column children -> Html.div [ A.class "plugin-panel" ] (List.map html children)
    Button label msg -> Html.button [ Events.onClick msg ] [ Html.text label ]

lines : Ui msg -> List String
lines ui = case ui of
    Text content -> String.lines content
    Column children -> List.concatMap lines children
    Button label _ -> [ "[" ++ label ++ "]" ]

actions : Ui msg -> List ( String, msg )
actions ui = case ui of
    Text _ -> []
    Column children -> List.concatMap actions children
    Button label msg -> [ ( label, msg ) ]
