module Commands exposing (Context, Intent(..), catalog, complete, parse, help)

import Json.Encode as E

type alias Context = { threadId : String, nodeId : String, modelName : String, workspace : String }
type Intent = Action E.Value | Workspace String Bool String | Local String String

type alias Entry = { name : String, arguments : String, description : String }

catalog : List Entry
catalog =
    [ Entry "/new" "[--workspace PATH] [TITLE]" "Start an empty chat, optionally in another directory"
    , Entry "/workspace" "[PATH]" "Show the current directory or open another workspace"
    , Entry "/workspaces" "" "List opened workspaces"
    , Entry "/chats" "" "Browse chats"
    , Entry "/rename" "TITLE" "Rename the current chat"
    , Entry "/model" "[MODEL]" "Show or change this chat's model"
    , Entry "/stop" "" "Cancel the current chat's run and pending tools"
    , Entry "/resume" "" "Run the current chat again"
    , Entry "/fork" "[TITLE]" "Branch from the selected history node"
    , Entry "/send" "THREAD MESSAGE" "Deliver selected context to another chat"
    , Entry "/compact" "SUMMARY" "Use an explicit summary for subsequent model context"
    , Entry "/history" "" "Open the current chat's history"
    , Entry "/prompt" "" "Show the effective system prompt for this workspace"
    , Entry "/status" "" "Show the current chat, workspace and model"
    , Entry "/help" "" "List commands and keyboard help"
    , Entry "/quit" "" "Exit the terminal"
    ]

help : String
help = catalog |> List.map (\entry -> entry.name ++ " " ++ entry.arguments ++ "\n  " ++ entry.description) |> String.join "\n\n"

complete : String -> String
complete draft = catalog |> List.filter (\entry -> String.startsWith draft entry.name) |> List.head |> Maybe.map (\entry -> entry.name ++ " ") |> Maybe.withDefault draft

-- Parse quoted paths and titles in Elm; the host never interprets slash commands.
tokenize : String -> Result String (List String)
tokenize source =
    let
        walk chars quote escaped current result = case chars of
            [] -> if quote /= Nothing then Err "Unclosed quote in command" else Ok (List.reverse (if String.isEmpty current then result else current :: result))
            char :: rest ->
                if escaped then walk rest quote False (current ++ String.fromChar char) result else
                if char == '\\' && quote /= Just '\'' then walk rest quote True current result else
                case quote of
                    Just delimiter -> if char == delimiter then walk rest Nothing False current result else walk rest quote False (current ++ String.fromChar char) result
                    Nothing -> if char == '"' || char == '\'' then walk rest (Just char) False current result else if char == ' ' || char == '\n' || char == '\t' then walk rest Nothing False "" (if String.isEmpty current then result else current :: result) else walk rest Nothing False (current ++ String.fromChar char) result
    in walk (String.toList source) Nothing False "" []

parse : Context -> String -> Result String Intent
parse context source =
    let
        str key value = ( key, E.string value )
        action name fields = Ok (Action (E.object (str "type" name :: fields)))
        local name argument = Ok (Local name argument)
        required name argument fields = if String.isEmpty argument then Err (name ++ " needs an argument. See /help.") else action name fields
    in
    if not (String.startsWith "/" (String.trimLeft source)) then action "Submit" [ str "threadId" context.threadId, str "text" source ] else
    tokenize source |> Result.andThen (\tokens ->
        let args = List.drop 1 tokens
            argument = String.join " " args
        in case List.head tokens of
            Just "/new" ->
                case args of
                    "--workspace" :: path :: title -> Ok (Workspace path True (String.join " " title))
                    "--workspace" :: [] -> Err "Use /new --workspace PATH [TITLE]"
                    path :: title -> if String.startsWith "/" path || String.startsWith "~" path || String.startsWith "." path then Ok (Workspace path True (String.join " " title)) else action "NewChat" [ str "title" argument, str "model" context.modelName, str "workspace" context.workspace ]
                    [] -> action "NewChat" [ str "title" "", str "model" context.modelName, str "workspace" context.workspace ]
            Just "/clear" -> action "NewChat" [ str "title" "", str "model" context.modelName, str "workspace" context.workspace ]
            Just "/workspace" -> if String.isEmpty argument then local "workspace" "" else Ok (Workspace argument False "")
            Just "/cd" -> if String.isEmpty argument then local "workspace" "" else Ok (Workspace argument False "")
            Just "/rename" -> required "Rename" argument [ str "threadId" context.threadId, str "title" argument ]
            Just "/model" -> if String.isEmpty argument then local "model" "" else action "SetModel" [ str "threadId" context.threadId, str "model" argument ]
            Just "/stop" -> action "StopThread" [ str "threadId" context.threadId ]
            Just "/resume" -> action "Run" [ str "threadId" context.threadId ]
            Just "/run" -> action "Run" [ str "threadId" context.threadId ]
            Just "/fork" -> action "Fork" [ str "nodeId" context.nodeId, str "title" argument, str "task" "" ]
            Just "/compact" -> required "Compact" argument [ str "threadId" context.threadId, str "text" argument ]
            Just "/send" -> case args of
                target :: message -> if List.isEmpty message then Err "Use /send THREAD MESSAGE" else action "Send" [ str "from" context.threadId, str "target" target, str "text" (String.join " " message), ( "refs", E.list E.string [ context.nodeId ] ) ]
                _ -> Err "Use /send THREAD MESSAGE"
            Just "/approve" -> required "Approve" argument [ str "callId" argument, ( "allowed", E.bool True ) ]
            Just "/deny" -> required "Approve" argument [ str "callId" argument, ( "allowed", E.bool False ) ]
            Just "/cancel" -> if String.isEmpty argument then action "StopThread" [ str "threadId" context.threadId ] else action "Cancel" [ str "runId" argument ]
            Just "/focus" -> local "focus" argument
            Just "/select" -> local "select" argument
            Just "/workspaces" -> local "workspaces" ""
            Just "/chats" -> local "chats" ""
            Just "/history" -> local "history" ""
            Just "/prompt" -> local "prompt" ""
            Just "/status" -> local "status" ""
            Just "/help" -> local "help" ""
            Just "/quit" -> local "quit" ""
            _ -> Err "Unknown command. Type /help to see available commands.")
