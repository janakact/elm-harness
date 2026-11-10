module Rich exposing (Part(..), parse, view, terminal)

import Html exposing (Html)
import Html.Attributes as A
import Markdown

type Part = Markdown String | InlineMath String | DisplayMath String

-- Keep fenced and inline code opaque while recognizing explicit TeX delimiters.
parse : String -> List Part
parse source =
    let
        walk remaining buffer parts fence inline =
            if String.isEmpty remaining then List.reverse (Markdown buffer :: parts) else
            if String.startsWith "```" remaining then walk (String.dropLeft 3 remaining) (buffer ++ "```") parts (not fence) False else
            if String.startsWith "~~~" remaining then walk (String.dropLeft 3 remaining) (buffer ++ "~~~") parts (not fence) False else
            if not fence && String.startsWith "`" remaining then walk (String.dropLeft 1 remaining) (buffer ++ "`") parts fence (not inline) else
            if fence || inline then walk (String.dropLeft 1 remaining) (buffer ++ String.left 1 remaining) parts fence inline else
            let
                delimiter = if String.startsWith "\\[" remaining then Just ( "\\[", "\\]", True ) else if String.startsWith "\\(" remaining then Just ( "\\(", "\\)", False ) else if String.startsWith "$$" remaining then Just ( "$$", "$$", True ) else Nothing
            in
            case delimiter of
                Nothing -> walk (String.dropLeft 1 remaining) (buffer ++ String.left 1 remaining) parts fence inline
                Just ( opening, closing, display ) ->
                    let rest = String.dropLeft (String.length opening) remaining in
                    case List.head (String.indexes closing rest) of
                        Nothing -> walk (String.dropLeft 1 remaining) (buffer ++ String.left 1 remaining) parts fence inline
                        Just index ->
                            let formula = String.left index rest
                                part = if display then DisplayMath formula else InlineMath formula
                            in walk (String.dropLeft (index + String.length closing) rest) "" (part :: Markdown buffer :: parts) fence inline
    in walk source "" [] False False

view : String -> Html msg
view source =
    Html.div [ A.class "rich" ] (parse source |> List.map (\part ->
        case part of
            Markdown content -> Markdown.toHtmlWith { githubFlavored = Just { tables = True, breaks = False }, defaultHighlighting = Just "text", sanitize = True, smartypants = False } [] content
            InlineMath latex -> Html.node "math-view" [ A.attribute "latex" latex ] []
            DisplayMath latex -> Html.node "math-view" [ A.attribute "latex" latex, A.attribute "display" "" ] []))

terminal : String -> String
terminal source = parse source |> List.map (\part -> case part of
    Markdown content -> content
    InlineMath latex -> "\\(" ++ latex ++ "\\)"
    DisplayMath latex -> "\n  \\[" ++ latex ++ "\\]\n") |> String.join ""
