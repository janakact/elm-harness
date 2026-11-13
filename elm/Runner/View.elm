module Runner.View exposing (Pending, usageText, jobText, overview, progress, resultHeading, resultBody, matchesResult, pendingText, activity)

import Runner.Types as Jobs exposing (Job)

type alias Pending = { id : String, threadId : String, backend : String, prompt : String, fromComposer : Bool }

pendingText : Pending -> String
pendingText pending = "Sending " ++ pending.backend ++ " agent request…\n\n" ++ pending.prompt

activity : String -> Maybe Pending -> List Job -> Maybe String
activity threadId pending jobs =
    let local = List.filter (\job -> job.threadId == threadId) jobs in
    if (pending |> Maybe.map .threadId) == Just threadId then Just "Sending agent…"
    else if List.any (\job -> job.status == Jobs.Running) local then Just "Agent running"
    else if List.any (\job -> job.status == Jobs.Queued) local then Just "Agent queued"
    else Nothing

progress : Job -> String
progress job =
    if job.status == Jobs.Queued then "Queued · waiting for an execution slot…"
    else if job.status /= Jobs.Running then Jobs.statusName job.status
    else if not (String.isEmpty job.output) then "Responding…"
    else if not (List.isEmpty job.observations) then "Working… " ++ (List.reverse job.observations |> List.head |> Maybe.withDefault "")
    else if String.isEmpty job.sessionId then "Starting " ++ Jobs.backendName job.backend ++ "…"
    else "Waiting for " ++ Jobs.backendName job.backend ++ " response…"

resultHeading : String -> String
resultHeading result = String.lines result |> List.head |> Maybe.withDefault "Agent response"

resultBody : String -> String
resultBody result = String.split "\n\n" result |> List.drop 1 |> String.join "\n\n"

matchesResult : Job -> String -> Bool
matchesResult job result =
    let words = String.words (resultHeading result)
        id = List.drop 2 words |> List.head |> Maybe.withDefault ""
        attempt = List.drop 5 words |> List.head |> Maybe.andThen String.toInt |> Maybe.withDefault 1
    in id == job.id && attempt == job.attempt

usageText : Job -> String
usageText job = case job.usage of
    Nothing -> "Usage not reported"
    Just usage -> String.fromInt usage.input ++ " input · " ++ String.fromInt usage.output ++ " output tokens" ++ (usage.cost |> Maybe.map (\cost -> " · $" ++ String.fromFloat cost) |> Maybe.withDefault "") ++ " (" ++ usage.scope ++ ")"

jobText : Job -> String
jobText job = String.toUpper (Jobs.backendName job.backend) ++ " " ++ job.id ++ " · " ++ Jobs.statusName job.status ++ " · attempt " ++ String.fromInt job.attempt
    ++ "\nWorkspace: " ++ job.workspace ++ "\nModel: " ++ (if String.isEmpty job.model then "CLI default" else job.model)
    ++ "\n" ++ progress job ++ "\n" ++ usageText job ++ "\n\nRequest: " ++ job.prompt ++ "\n\n" ++ String.join "\n" job.observations
    ++ (if String.isEmpty job.error then "" else "\n\n" ++ job.error) ++ "\n\n" ++ job.output

overview : String -> List Job -> String
overview threadId jobs =
    "EXTERNAL AGENT JOBS · READ ONLY\n\n" ++ (jobs |> List.filter (\job -> job.threadId == threadId) |> List.map jobText |> String.join "\n\n────────\n\n")
    ++ "\n\n/agent codex PROMPT\n/agent claude PROMPT\n/agent resume JOB PROMPT\n/agent cancel JOB\n/agent report JOB [THREAD]\n\nResults enter model context only when you report them. Native chat tool permissions do not control external tools."
