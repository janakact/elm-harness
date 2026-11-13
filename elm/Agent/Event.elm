module Agent.Event exposing (Event(..))

{-| Provider-neutral native-agent stream events. A new provider emits these same
values; the application composition does not inspect its wire JSON.
-}
import Accounting

type Event
    = Text String
    | ToolFragment Int String String String
    | Usage Accounting.Report
    | FinishReason String
    | ProviderError String
