module StateViewer exposing (Model, Msg(..), init, refresh, update, view)

import Html exposing (Html, button, div, input, pre, span, text)
import Html.Attributes as A
import Html.Events exposing (onClick, onInput)
import Json.Decode as D
import Json.Encode as E
import Set exposing (Set)

type Tree = Object (List ( String, Tree )) | Array (List Tree) | Scalar String String

type alias Model = { source : E.Value, tree : Tree, expanded : Set String, query : String }
type Msg = Toggle String | Query String | ExpandAll | CollapseAll

decoder : D.Decoder Tree
decoder = D.oneOf
    [ D.map Object (D.keyValuePairs (D.lazy (\_ -> decoder)))
    , D.map Array (D.list (D.lazy (\_ -> decoder)))
    , D.map (\value -> Scalar "string" (E.encode 0 (E.string value))) D.string
    , D.map (\value -> Scalar "number" (E.encode 0 (E.float value))) D.float
    , D.map (\value -> Scalar "boolean" (if value then "true" else "false")) D.bool
    , D.null (Scalar "null" "null")
    ]

init : E.Value -> Model
init source = { source = source, tree = D.decodeValue decoder source |> Result.withDefault (Scalar "null" "null"), expanded = Set.fromList [ "$", "$/backend", "$/client" ], query = "" }

refresh : E.Value -> Model -> Model
refresh source model = { model | source = source, tree = D.decodeValue decoder source |> Result.withDefault (Scalar "null" "null") }

childPath : String -> String -> String
childPath path name = path ++ "/" ++ (name |> String.replace "~" "~0" |> String.replace "/" "~1")

children : Tree -> List ( String, Tree )
children tree = case tree of
    Object fields -> fields
    Array items -> List.indexedMap (\index item -> ( String.fromInt index, item )) items
    Scalar _ _ -> []

paths : String -> Tree -> List String
paths path tree = path :: (children tree |> List.concatMap (\( name, child ) -> paths (childPath path name) child))

update : Msg -> Model -> Model
update msg model = case msg of
    Toggle path -> { model | expanded = if Set.member path model.expanded then Set.remove path model.expanded else Set.insert path model.expanded }
    Query query -> { model | query = query }
    ExpandAll -> { model | expanded = Set.fromList (paths "$" model.tree) }
    CollapseAll -> { model | expanded = Set.singleton "$" }

matches : String -> String -> Tree -> Bool
matches query name tree =
    String.contains query (String.toLower name) || (case tree of
        Scalar _ value -> String.contains query (String.toLower value)
        _ -> List.any (\( key, child ) -> matches query key child) (children tree))

view : Model -> Html Msg
view model =
    div [ A.class "json-explorer" ]
        [ div [ A.class "json-toolbar" ]
            [ input [ A.class "json-search", A.placeholder "Find a key or value…", A.attribute "aria-label" "Search app state", A.value model.query, onInput Query ] []
            , button [ onClick ExpandAll ] [ text "Expand all" ]
            , button [ onClick CollapseAll ] [ text "Collapse all" ]
            ]
        , div [ A.class "json-tree", A.attribute "role" "tree", A.attribute "aria-label" "Application state JSON" ]
            (if String.isEmpty (String.trim model.query) || matches (String.toLower model.query) "$" model.tree then [ nodeView model "$" "$" 0 model.tree ] else [ div [ A.class "json-empty" ] [ text "No matching keys or values." ] ])
        ]

nodeView : Model -> String -> String -> Int -> Tree -> Html Msg
nodeView model path name depth tree =
    let
        fields = children tree
        query = String.toLower (String.trim model.query)
        expanded = Set.member path model.expanded || not (String.isEmpty query)
        filterChildren = if String.isEmpty query || String.contains query (String.toLower name) then fields else List.filter (\( fieldName, value ) -> matches query fieldName value) fields
        key = span [ A.class "json-key" ] [ text name ]
        indent = A.style "padding-left" (String.fromInt (min 20 depth * 16) ++ "px")
        container opening closing =
            div [ A.class "json-branch" ]
                (button [ A.class "json-branch-toggle", indent, A.attribute "role" "treeitem", A.attribute "aria-expanded" (if expanded then "true" else "false"), A.title path, onClick (Toggle path) ]
                    [ span [ A.class "json-disclosure" ] [ text (if expanded then "▾" else "▸") ], key, text (": " ++ opening), span [ A.class "json-meta" ] [ text (" " ++ String.fromInt (List.length fields) ++ (if List.length fields == 1 then " item " else " items ")) ], text closing ]
                    :: (if expanded then List.map (\( childName, child ) -> nodeView model (childPath path childName) childName (depth + 1) child) filterChildren else []))
    in case tree of
        Object _ -> container "{" "}"
        Array _ -> container "[" "]"
        Scalar kind value ->
            div [ A.class "json-row", indent, A.title path, A.attribute "role" "treeitem" ]
                [ key, text ": ", if kind == "string" && String.length value > 180 then
                    Html.details [ A.class "json-long-value" ] [ Html.summary [] [ span [ A.class "json-string" ] [ text (String.left 180 value ++ "…") ] ], pre [ A.class "json-full-value" ] [ text value ] ]
                  else span [ A.class ("json-" ++ kind) ] [ text value ]
                ]
