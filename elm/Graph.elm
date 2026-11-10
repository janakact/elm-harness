module Graph exposing (view, label)

import Core
import Dict
import Html exposing (Html)
import Svg exposing (circle, g, line, svg, text, text_)
import Svg.Attributes as A
import Svg.Events

view : Core.Model -> String -> (String -> msg) -> Html msg
view model selected select =
    let
        nodes = Core.visibleNodes model
        positions = nodes |> List.indexedMap (\i n -> ( n.id, ( 18, 14 + i * 25 ) )) |> Dict.fromList
        coord n = Dict.get n.id positions |> Maybe.withDefault ( 18, 14 )
        edge node target dashed =
            case Dict.get target positions of
                Nothing -> text ""
                Just ( px, py ) -> let ( x, y ) = coord node in line [ A.x1 (String.fromInt x), A.y1 (String.fromInt y), A.x2 (String.fromInt px), A.y2 (String.fromInt py), A.stroke (if dashed then "#7eaea6" else "#536b8d"), A.strokeWidth "1.5", A.strokeDasharray (if dashed then "4 4" else "none") ] []
        draw node =
            let ( x, y ) = coord node in
            g [ Svg.Events.onClick (select node.id), A.class "svg-node" ] [ Svg.node "title" [] [ text (label node ++ " · " ++ String.left 180 node.text) ], circle [ A.cx (String.fromInt x), A.cy (String.fromInt y), A.r (if node.id == selected then "6" else "4"), A.fill (if node.kind == "ToolCall" then "#d3ad70" else if node.kind == "Handoff" then "#7eaea6" else "#9fb9e3"), A.stroke (if node.id == selected then "#fff" else "none"), A.strokeWidth "2" ] [], text_ [ A.x (String.fromInt (x+12)), A.y (String.fromInt (y+4)), A.fill "#acb8cc", A.fontSize "10" ] [ text (label node) ] ]
        edges = nodes |> List.concatMap (\node -> (Maybe.map (\parent -> edge node parent False) node.parentId |> Maybe.map List.singleton |> Maybe.withDefault []) ++ List.map (\ref -> edge node ref True) node.refs)
    in svg [ A.width "100%", A.height (String.fromInt (List.length nodes * 25 + 4)) ] (edges ++ List.map draw nodes)

label : Core.Node -> String
label node =
    case node.kind of
        "UserMessage" -> "Chat · You"
        "AgentMessage" -> "Chat · Assistant"
        "Handoff" -> "Chat · Delivered"
        "ToolCall" -> "Tool · Call"
        "ToolResult" -> "Tool · Result"
        "Approval" -> "Approval"
        "Activity" -> "Activity"
        "Summary" -> "Summary"
        "Notice" -> "System"
        _ -> "Event"
