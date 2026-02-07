(** AppleScript Transport - Execute AppleScript via osascript

    Pure OCaml wrapper for macOS osascript command.
    Used for controlling Logic Pro, MainStage, and other macOS apps.
*)

(** Result of AppleScript execution *)
type result = {
  success : bool;
  output : string;
  error : string option;
}

let read_all_lines ic =
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_string buf (input_line ic);
       Buffer.add_char buf '\n'
     done
   with End_of_file -> ());
  Buffer.contents buf

(** Execute AppleScript code and return result *)
let execute script =
  (* Run osascript without going through a shell. *)
  let env = Unix.environment () in
  let stdout_ic, stdin_oc, stderr_ic =
    Unix.open_process_args_full "osascript" [| "osascript"; "-e"; script |] env
  in
  let stdout = read_all_lines stdout_ic in
  let stderr = read_all_lines stderr_ic in
  let status = Unix.close_process_full (stdout_ic, stdin_oc, stderr_ic) in
  let output =
    String.trim
      (stdout ^ if stdout <> "" && stderr <> "" then "\n" ^ stderr else stderr)
  in

  match status with
  | Unix.WEXITED 0 ->
    { success = true; output; error = None }
  | Unix.WEXITED code ->
    { success = false; output = ""; error = Some (Printf.sprintf "Exit code %d: %s" code output) }
  | Unix.WSIGNALED sig_num ->
    { success = false; output = ""; error = Some (Printf.sprintf "Killed by signal %d" sig_num) }
  | Unix.WSTOPPED _ ->
    { success = false; output = ""; error = Some "Process stopped" }

(** Execute AppleScript from file *)
let execute_file path =
  let env = Unix.environment () in
  let stdout_ic, stdin_oc, stderr_ic =
    Unix.open_process_args_full "osascript" [| "osascript"; path |] env
  in
  let stdout = read_all_lines stdout_ic in
  let stderr = read_all_lines stderr_ic in
  let status = Unix.close_process_full (stdout_ic, stdin_oc, stderr_ic) in
  let output =
    String.trim
      (stdout ^ if stdout <> "" && stderr <> "" then "\n" ^ stderr else stderr)
  in
  match status with
  | Unix.WEXITED 0 -> { success = true; output; error = None }
  | _ -> { success = false; output = ""; error = Some output }

(** Check if an application is running *)
let is_app_running app_name =
  let script = Printf.sprintf {|
    tell application "System Events"
      return (name of processes) contains "%s"
    end tell
  |} app_name in
  let result = execute script in
  result.success && String.trim result.output = "true"

(** Activate (bring to front) an application *)
let activate_app app_name =
  let script = Printf.sprintf {|
    tell application "%s"
      activate
    end tell
  |} app_name in
  execute script

(** Quit an application *)
let quit_app app_name =
  let script = Printf.sprintf {|
    tell application "%s"
      quit
    end tell
  |} app_name in
  execute script

(** Modifier keys for keystrokes *)
type modifier = [ `Command | `Shift | `Option | `Control ]

(** Send keystroke to application *)
let send_keystroke app_name key ?modifiers () =
  let mod_str = match modifiers with
    | None -> ""
    | Some mods ->
      let mod_list = List.map (fun m ->
        match m with
        | `Command -> "command down"
        | `Shift -> "shift down"
        | `Option -> "option down"
        | `Control -> "control down"
      ) mods in
      " using {" ^ String.concat ", " mod_list ^ "}"
  in
  let script = Printf.sprintf {|
    tell application "System Events"
      tell process "%s"
        keystroke "%s"%s
      end tell
    end tell
  |} app_name key mod_str in
  execute script

(** Send key code to application *)
let send_keycode app_name code ?modifiers () =
  let mod_str = match modifiers with
    | None -> ""
    | Some mods ->
      let mod_list = List.map (fun m ->
        match m with
        | `Command -> "command down"
        | `Shift -> "shift down"
        | `Option -> "option down"
        | `Control -> "control down"
      ) mods in
      " using {" ^ String.concat ", " mod_list ^ "}"
  in
  let script = Printf.sprintf {|
    tell application "System Events"
      tell process "%s"
        key code %d%s
      end tell
    end tell
  |} app_name code mod_str in
  execute script

(** Common key codes *)
module KeyCode = struct
  let space = 49
  let return_key = 36
  let escape = 53
  let tab = 48
  let delete = 51
  let left = 123
  let right = 124
  let up = 126
  let down = 125
  let home = 115
  let end_key = 119
  let page_up = 116
  let page_down = 121

  (* Function keys *)
  let f1 = 122
  let f2 = 120
  let f3 = 99
  let f4 = 118
  let f5 = 96
  let f6 = 97
  let f7 = 98
  let f8 = 100
  let f9 = 101
  let f10 = 109
  let f11 = 103
  let f12 = 111
end

(** Click menu item (path separated by /) *)
let click_menu app_name menu_path =
  let menu_items = String.split_on_char '/' menu_path in
  let menu_script = match menu_items with
    | [] -> failwith "Empty menu path"
    | [menu] -> Printf.sprintf {|click menu item "%s"|} menu
    | menu :: rest ->
      (* Build nested menu path: Menu/Submenu/Item *)
      Printf.sprintf {|click menu item "%s" of menu 1 of menu bar item "%s" of menu bar 1|}
        (List.hd (List.rev rest)) menu
  in
  let script = Printf.sprintf {|
    tell application "System Events"
      tell process "%s"
        %s
      end tell
    end tell
  |} app_name menu_script in
  execute script
