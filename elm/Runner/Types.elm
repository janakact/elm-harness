module Runner.Types exposing (Backend(..), Status(..), Job, Usage, Capability, backendName, backendDecoder, statusName, active, emptyUsage, jobDecoder, encodeJob, capabilitiesDecoder)

{-| Public runner values shared by Elm clients. Process transport and private
deduplication state are kept outside this projection.
-}
import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Runner.Catalog as Catalog

type Backend = Codex | Claude
type Status = Queued | Running | Completed | Failed | Cancelled | Interrupted
type alias Usage = { input : Int, output : Int, cost : Maybe Float, scope : String }
type alias Job =
    { id : String, threadId : String, sourceHead : String, backend : Backend
    , workspace : String, model : String, prompt : String, status : Status
    , attempt : Int, sessionId : String, output : String, error : String
    , observations : List String, usage : Maybe Usage, createdAt : String, updatedAt : String
    }
type alias Capability = { available : Bool, version : String, error : String, models : List Catalog.Model }

backendName : Backend -> String
backendName backend = case backend of
    Codex -> "codex"
    Claude -> "claude"

backendDecoder : D.Decoder Backend
backendDecoder = D.string |> D.andThen (\name -> case name of
    "codex" -> D.succeed Codex
    "claude" -> D.succeed Claude
    _ -> D.fail "Choose codex or claude")

statusName : Status -> String
statusName status = case status of
    Queued -> "Queued"
    Running -> "Running"
    Completed -> "Completed"
    Failed -> "Failed"
    Cancelled -> "Cancelled"
    Interrupted -> "Interrupted"

statusDecoder : D.Decoder Status
statusDecoder = D.string |> D.andThen (\name -> case name of
    "Queued" -> D.succeed Queued
    "Running" -> D.succeed Running
    "Completed" -> D.succeed Completed
    "Failed" -> D.succeed Failed
    "Cancelled" -> D.succeed Cancelled
    "Interrupted" -> D.succeed Interrupted
    _ -> D.fail "Unknown external job status")

active : Status -> Bool
active status = status == Queued || status == Running

emptyUsage : Usage
emptyUsage = { input = 0, output = 0, cost = Nothing, scope = "attempt" }

usageDecoder : D.Decoder Usage
usageDecoder = D.map4 Usage (D.field "input" D.int) (D.field "output" D.int) (D.field "cost" (D.nullable D.float)) (D.field "scope" D.string)

jobDecoder : D.Decoder Job
jobDecoder = D.map8 Job (D.field "id" D.string) (D.field "threadId" D.string) (D.field "sourceHead" D.string) (D.field "backend" backendDecoder) (D.field "workspace" D.string) (D.field "model" D.string) (D.field "prompt" D.string) (D.field "status" statusDecoder)
    |> D.andThen (\partial -> D.map8 partial (D.field "attempt" D.int) (D.field "sessionId" D.string) (D.field "output" D.string) (D.field "error" D.string) (D.field "observations" (D.list D.string)) (D.field "usage" (D.nullable usageDecoder)) (D.field "createdAt" D.string) (D.field "updatedAt" D.string))

encodeJob : Job -> E.Value
encodeJob job = E.object
    [ ( "id", E.string job.id ), ( "threadId", E.string job.threadId ), ( "sourceHead", E.string job.sourceHead )
    , ( "backend", E.string (backendName job.backend) ), ( "workspace", E.string job.workspace ), ( "model", E.string job.model )
    , ( "prompt", E.string job.prompt ), ( "status", E.string (statusName job.status) ), ( "attempt", E.int job.attempt )
    , ( "sessionId", E.string job.sessionId ), ( "output", E.string job.output ), ( "error", E.string job.error )
    , ( "observations", E.list E.string job.observations ), ( "createdAt", E.string job.createdAt ), ( "updatedAt", E.string job.updatedAt )
    , ( "usage", job.usage |> Maybe.map (\usage -> E.object [ ( "input", E.int usage.input ), ( "output", E.int usage.output ), ( "cost", Maybe.map E.float usage.cost |> Maybe.withDefault E.null ), ( "scope", E.string usage.scope ) ]) |> Maybe.withDefault E.null )
    ]

capabilitiesDecoder : D.Decoder (Dict String Capability)
capabilitiesDecoder = D.dict (D.map4 Capability (D.field "available" D.bool) (D.field "version" D.string) (D.field "error" D.string)
    (D.oneOf [ D.field "models" (D.list Catalog.decoder), D.field "modelCache" Catalog.cacheDecoder, D.succeed [] ]))
    |> D.map (Dict.map (\backend capability -> { capability | models = Catalog.options backend capability.models }))
