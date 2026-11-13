module Agent.Message exposing (Message(..), Call)

{-| Provider-neutral input to the native Elm agent. -}
type alias Call = { id : String, name : String, arguments : String }
type Message = System String | User String | Assistant String | ToolCalls (List Call) | ToolResult String String
