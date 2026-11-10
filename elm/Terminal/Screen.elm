module Terminal.Screen exposing (clean, crop, width, pad, wrap, paint, joinColumns, markdown)

import Char

clean : String -> String
clean source = String.filter (\char -> let code = Char.toCode char in code == 10 || code == 9 || (code >= 32 && code /= 127 && (code < 128 || code > 159))) source |> String.replace "\t" "    "

charWidth : Char -> Int
charWidth char =
    let c = Char.toCode char in
    if (c >= 768 && c <= 879) || (c >= 65024 && c <= 65039) || c == 8205 then 0
    else if (c >= 4352 && c <= 4607) || (c >= 11904 && c <= 42191) || (c >= 44032 && c <= 55203) || (c >= 63744 && c <= 64255) || (c >= 65040 && c <= 65055) || (c >= 65072 && c <= 65376) || (c >= 65504 && c <= 65510) || c >= 127744 then 2
    else 1

width : String -> Int
width source = String.toList source |> List.map charWidth |> List.sum

crop : Int -> String -> String
crop columns source =
    let
        step chars remaining acc = case chars of
            [] -> String.fromList (List.reverse acc)
            char :: rest -> if charWidth char > remaining then String.fromList (List.reverse acc) else step rest (remaining - charWidth char) (char :: acc)
    in step (String.toList source) (max 0 columns) []

pad : Int -> String -> String
pad columns source = let clipped = crop columns (clean source |> String.replace "\n" " ") in clipped ++ String.repeat (max 0 (columns - width clipped)) " "

wrap : Int -> String -> List String
wrap columns source =
    let
        limit = max 1 columns
        line text =
            let
                walk chars used current result =
                    case chars of
                        [] -> List.reverse (String.fromList (List.reverse current) :: result)
                        char :: rest ->
                            let
                                displayed = if charWidth char > limit then '?' else char
                                size = charWidth displayed
                            in
                            if used + size > limit then walk chars 0 [] (String.fromList (List.reverse current) :: result)
                            else walk rest (used + size) (displayed :: current) result
            in walk (String.toList text) 0 [] []
    in clean source |> String.lines |> List.concatMap line

paint : String -> String -> String
paint style source = "\u{001B}[" ++ style ++ "m" ++ source ++ "\u{001B}[0m"

joinColumns : Int -> List String -> Int -> List String -> Int -> List String -> Int -> List String
joinColumns leftWidth left centerWidth center rightWidth right height =
    let
        at index lines = List.drop index lines |> List.head |> Maybe.withDefault ""
        row i = (if leftWidth > 0 then pad leftWidth (at i left) ++ " │ " else "") ++ pad centerWidth (at i center) ++ (if rightWidth > 0 then " │ " ++ pad rightWidth (at i right) else "")
    in List.range 0 (max 0 (height - 1)) |> List.map row

-- Markdown remains readable in monochrome; code and LaTeX source are preserved.
markdown : Int -> String -> List String
markdown columns source =
    clean source |> String.lines |> List.concatMap (\line ->
        let text = if String.startsWith "### " line then String.dropLeft 4 line else if String.startsWith "## " line then String.dropLeft 3 line else if String.startsWith "# " line then String.toUpper (String.dropLeft 2 line) else if String.startsWith "> " line then "│ " ++ String.dropLeft 2 line else line
        in wrap columns text)
