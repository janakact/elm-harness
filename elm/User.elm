module User exposing (Model, Msg(..), init, update, onEvent, sidebar, inspector, encode, decoder, encodeMsg, msgDecoder)

{-| Example compiled plugin. Its concrete Model/Msg belong here; all app access
uses shared public types. The legacy user namespace is independently migrated.
-}
import App.Public as App
import App.Ui exposing (Ui(..))
import Dict
import Json.Decode as D
import Json.Encode as E

type alias Model = { showCount : Bool, replies : Int, extra : Dict.Dict String E.Value }
type Msg = ToggleCount | ResetCount | StartChat

init : Model
init = { showCount = True, replies = 0, extra = Dict.empty }

update : App.Model -> Msg -> Model -> ( Model, List App.Action )
update app msg model = case msg of
    ToggleCount -> ( { model | showCount = not model.showCount }, [] )
    ResetCount -> ( { model | replies = 0 }, [] )
    StartChat ->
        let thread = Dict.get app.focused app.threads
        in ( model, [ App.NewChat "" (thread |> Maybe.map .model |> Maybe.withDefault "deepseek/deepseek-v4-flash") (thread |> Maybe.map .workspace |> Maybe.withDefault app.defaultWorkspace) ] )

onEvent : App.Event -> Model -> Model
onEvent event model = case event of
    App.NodeCommitted node -> if node.kind == "AgentMessage" then { model | replies = model.replies + 1 } else model

sidebar : App.Model -> Model -> Ui Msg
sidebar app model = Column
    [ Text "Session plugin"
    , Text (if model.showCount then String.fromInt model.replies ++ " assistant replies" else "Reply count hidden")
    , Button (if model.showCount then "Hide reply count" else "Show reply count") ToggleCount
    ]

inspector : App.Model -> Model -> Ui Msg
inspector app model = Column
    [ Text "Session plugin"
    , Text (Dict.get app.focused app.threads |> Maybe.map (\thread -> "Chat: " ++ thread.title) |> Maybe.withDefault "No chat selected")
    , Text ("Saved replies: " ++ String.fromInt model.replies)
    , Button "Reset reply count" ResetCount
    , Button "New chat from plugin" StartChat
    ]

encode : Model -> E.Value
encode model = E.object (Dict.toList model.extra ++ [ ( "showCount", E.bool model.showCount ), ( "replies", E.int model.replies ) ])

decoder : D.Decoder Model
decoder =
    let optional key decoderForField fallback = D.keyValuePairs D.value |> D.andThen (\fields -> if List.any (\( name, _ ) -> name == key) fields then D.field key decoderForField else D.succeed fallback)
    in D.map3 Model (optional "showCount" D.bool True) (optional "replies" D.int 0) (D.keyValuePairs D.value |> D.map (List.filter (\( key, _ ) -> not (List.member key [ "showCount", "replies" ])) >> Dict.fromList))
        |> D.andThen (\model -> if model.replies < 0 then D.fail "Invalid reply count" else D.succeed model)

encodeMsg : String -> Msg -> E.Value
encodeMsg threadId msg = E.object [ ( "threadId", E.string threadId ), ( "type", E.string "UserAction" ), ( "action", E.string (case msg of
    ToggleCount -> "ToggleCount"
    ResetCount -> "ResetCount"
    StartChat -> "StartChat") ) ]

msgDecoder : D.Decoder Msg
msgDecoder = D.field "action" D.string |> D.andThen (\name -> case name of
    "ToggleCount" -> D.succeed ToggleCount
    "ResetCount" -> D.succeed ResetCount
    "StartChat" -> D.succeed StartChat
    _ -> D.fail "Unknown user plugin action")
