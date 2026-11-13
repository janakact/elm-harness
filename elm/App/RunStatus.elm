module App.RunStatus exposing (Status(..), name, decoder, active, receiving, occupiesSlot)

import Json.Decode as D

type Status = Idle | Queued | RequestingModel | Streaming | ExecutingTool | AwaitingApproval | Compacting | AwaitingSummary | Completed | Failed | Cancelled

name : Status -> String
name status = case status of
    Idle -> "Idle"
    Queued -> "Queued"
    RequestingModel -> "RequestingModel"
    Streaming -> "Streaming"
    ExecutingTool -> "ExecutingTool"
    AwaitingApproval -> "AwaitingApproval"
    Compacting -> "Compacting"
    AwaitingSummary -> "AwaitingSummary"
    Completed -> "Completed"
    Failed -> "Failed"
    Cancelled -> "Cancelled"

decoder : D.Decoder Status
decoder = D.string |> D.andThen (\value -> case value of
    "Idle" -> D.succeed Idle
    "Queued" -> D.succeed Queued
    "RequestingModel" -> D.succeed RequestingModel
    "Streaming" -> D.succeed Streaming
    "ExecutingTool" -> D.succeed ExecutingTool
    "AwaitingApproval" -> D.succeed AwaitingApproval
    "Compacting" -> D.succeed Compacting
    "AwaitingSummary" -> D.succeed AwaitingSummary
    "Completed" -> D.succeed Completed
    "Failed" -> D.succeed Failed
    "Cancelled" -> D.succeed Cancelled
    _ -> D.fail "Unknown run status")

active : Status -> Bool
active status = List.member status [ Queued, RequestingModel, Streaming, ExecutingTool, AwaitingApproval, Compacting, AwaitingSummary ]

receiving : Status -> Bool
receiving status = List.member status [ RequestingModel, Streaming, Compacting ]

occupiesSlot : Status -> Bool
occupiesSlot status = List.member status [ RequestingModel, Streaming, ExecutingTool, AwaitingApproval, Compacting ]
