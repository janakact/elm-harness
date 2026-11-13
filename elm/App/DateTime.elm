module App.DateTime exposing (parse, latest, date, full, newestFirst)

{-| Host timestamps are UTC ISO-8601. Formatting stays in Elm and uses the
viewer's local zone. Unknown legacy dates remain explicitly unknown.
-}
import Time exposing (Month(..), Posix, Zone)

parse : String -> Maybe Posix
parse source =
    let
        part start end = String.slice start end source |> String.toInt
        leap year = modBy 4 year == 0 && (modBy 100 year /= 0 || modBy 400 year == 0)
        daysInMonth year month = if month == 2 then (if leap year then 29 else 28) else if List.member month [ 4, 6, 9, 11 ] then 30 else 31
        years year = 365 * (year - 1970) + (year - 1) // 4 - 1969 // 4 - (year - 1) // 100 + 1969 // 100 + (year - 1) // 400 - 1969 // 400
    in case ( part 0 4, part 5 7, part 8 10 ) of
        ( Just year, Just month, Just day ) ->
            case ( part 11 13, part 14 16, part 17 19 ) of
                ( Just hour, Just minute, Just second ) ->
                    if year < 1 || month < 1 || month > 12 || day < 1 || day > daysInMonth year month || hour > 23 || minute > 59 || second > 59 || hour < 0 || minute < 0 || second < 0 || not (String.endsWith "Z" source) then Nothing else
                    let days = years year + (List.range 1 (month - 1) |> List.map (daysInMonth year) |> List.sum) + day - 1
                        millis = if String.slice 19 20 source == "." then String.slice 20 (String.length source - 1) source |> String.padRight 3 '0' |> String.left 3 |> String.toInt |> Maybe.withDefault 0 else 0
                    in Just (Time.millisToPosix (((days * 24 + hour) * 60 + minute) * 60000 + second * 1000 + millis))
                _ -> Nothing
        _ -> Nothing

latest : String -> String -> String
latest previous candidate = case parse candidate of
    Nothing -> previous
    Just stamp -> if parse previous |> Maybe.map (\old -> Time.posixToMillis old > Time.posixToMillis stamp) |> Maybe.withDefault False then previous else candidate

monthName : Month -> String
monthName month = case month of
    Jan -> "Jan"
    Feb -> "Feb"
    Mar -> "Mar"
    Apr -> "Apr"
    May -> "May"
    Jun -> "Jun"
    Jul -> "Jul"
    Aug -> "Aug"
    Sep -> "Sep"
    Oct -> "Oct"
    Nov -> "Nov"
    Dec -> "Dec"

date : Zone -> String -> String
date zone source = parse source |> Maybe.map (\stamp -> String.fromInt (Time.toDay zone stamp) ++ " " ++ monthName (Time.toMonth zone stamp) ++ " " ++ String.fromInt (Time.toYear zone stamp)) |> Maybe.withDefault "Date unavailable"

full : Zone -> String -> String
full zone source = parse source |> Maybe.map (\stamp -> date zone source ++ ", " ++ (String.fromInt (Time.toHour zone stamp) |> String.padLeft 2 '0') ++ ":" ++ (String.fromInt (Time.toMinute zone stamp) |> String.padLeft 2 '0')) |> Maybe.withDefault "No recorded date"

newestFirst : List { thread | id : String, updatedAt : String } -> List { thread | id : String, updatedAt : String }
newestFirst threads = threads |> List.sortBy (\thread -> ( parse thread.updatedAt |> Maybe.map Time.posixToMillis |> Maybe.withDefault 0, String.dropLeft 1 thread.id |> String.toInt |> Maybe.withDefault 0 )) |> List.reverse
