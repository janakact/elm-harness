module Policy exposing (Decision(..), Model, default, ask, readOnly, decision, name, parseDecision, change, encode, decoder, description)

import Json.Decode as D
import Json.Encode as E

type Decision = Allow | Ask | Deny
type alias Model = { read : Decision, write : Decision, bash : Decision }
default : Model
default = { read = Allow, write = Ask, bash = Ask }
ask : Model
ask = { read = Ask, write = Ask, bash = Ask }
readOnly : Model
readOnly = { read = Allow, write = Deny, bash = Deny }
name : Decision -> String
name value = case value of
    Allow -> "allow"
    Ask -> "ask"
    Deny -> "deny"
parseDecision : String -> Maybe Decision
parseDecision value = case value of
    "allow" -> Just Allow
    "ask" -> Just Ask
    "deny" -> Just Deny
    _ -> Nothing
decision : Model -> String -> Decision
decision policy tool = case tool of
    "read" -> policy.read
    "write" -> policy.write
    "bash" -> policy.bash
    _ -> Deny
change : String -> Decision -> Model -> Maybe Model
change tool value policy = case tool of
    "read" -> Just { policy | read = value }
    "write" -> Just { policy | write = value }
    "bash" -> Just { policy | bash = value }
    _ -> Nothing
encode : Model -> E.Value
encode policy = E.object [ ( "read", E.string (name policy.read) ), ( "write", E.string (name policy.write) ), ( "bash", E.string (name policy.bash) ) ]
decoder : D.Decoder Model
decoder =
    let field key = D.field key D.string |> D.andThen (\value -> parseDecision value |> Maybe.map D.succeed |> Maybe.withDefault (D.fail "Invalid tool permission"))
    in D.map3 Model (field "read") (field "write") (field "bash")
description : Model -> String
description policy = "read: " ++ name policy.read ++ ", write: " ++ name policy.write ++ ", bash: " ++ name policy.bash
