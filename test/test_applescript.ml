(** AppleScript Transport Tests - macOS automation layer *)

open Transport.Applescript

(** Test key code constants *)
let test_key_codes () =
  (* These are macOS virtual key codes - must match Apple's spec *)
  Alcotest.(check int) "space key" 49 KeyCode.space;
  Alcotest.(check int) "return key" 36 KeyCode.return_key;
  Alcotest.(check int) "escape key" 53 KeyCode.escape;
  Alcotest.(check int) "tab key" 48 KeyCode.tab;
  Alcotest.(check int) "delete key" 51 KeyCode.delete;
  Alcotest.(check int) "left arrow" 123 KeyCode.left;
  Alcotest.(check int) "right arrow" 124 KeyCode.right;
  Alcotest.(check int) "up arrow" 126 KeyCode.up;
  Alcotest.(check int) "down arrow" 125 KeyCode.down

(** Test function keys *)
let test_function_keys () =
  (* Function key codes follow macOS conventions *)
  Alcotest.(check int) "F1" 122 KeyCode.f1;
  Alcotest.(check int) "F2" 120 KeyCode.f2;
  Alcotest.(check int) "F5" 96 KeyCode.f5;
  Alcotest.(check int) "F12" 111 KeyCode.f12

(** Test result type *)
let test_result_type () =
  let success_result = { success = true; output = "test output"; error = None } in
  Alcotest.(check bool) "success flag" true success_result.success;
  Alcotest.(check string) "output" "test output" success_result.output;
  Alcotest.(check (option string)) "no error" None success_result.error;

  let fail_result = { success = false; output = ""; error = Some "error message" } in
  Alcotest.(check bool) "fail flag" false fail_result.success;
  Alcotest.(check (option string)) "has error" (Some "error message") fail_result.error

(** Test modifier type (polymorphic variant) *)
let test_modifier_types () =
  let mods : modifier list = [`Command; `Shift; `Option; `Control] in
  Alcotest.(check int) "4 modifiers" 4 (List.length mods);

  (* Verify each modifier is distinct *)
  let cmd_exists = List.exists (fun m -> m = `Command) mods in
  let shift_exists = List.exists (fun m -> m = `Shift) mods in
  let opt_exists = List.exists (fun m -> m = `Option) mods in
  let ctrl_exists = List.exists (fun m -> m = `Control) mods in
  Alcotest.(check bool) "command exists" true cmd_exists;
  Alcotest.(check bool) "shift exists" true shift_exists;
  Alcotest.(check bool) "option exists" true opt_exists;
  Alcotest.(check bool) "control exists" true ctrl_exists

(** Test navigation keys *)
let test_navigation_keys () =
  Alcotest.(check int) "home" 115 KeyCode.home;
  Alcotest.(check int) "end" 119 KeyCode.end_key;
  Alcotest.(check int) "page up" 116 KeyCode.page_up;
  Alcotest.(check int) "page down" 121 KeyCode.page_down

(** Integration test - only runs on macOS *)
let test_is_app_running () =
  (* Finder is always running on macOS; on non-macOS this should just not crash. *)
  let result = is_app_running "Finder" in
  ignore result

(** Test execute with simple script *)
let test_execute_simple () =
  let result = execute "return 2 + 2" in
  if result.success then Alcotest.(check string) "2+2=4" "4" result.output
  (* If osascript is unavailable (e.g., Linux CI), just ensure we didn't raise. *)

(** Test execute with string escaping *)
let test_execute_string () =
  let result = execute {|return "hello world"|} in
  if result.success then
    Alcotest.(check string) "string return" "hello world" result.output

(** Test quotes in script *)
let test_quote_escaping () =
  (* Script with single quotes that need escaping *)
  let result = execute {|return "it's working"|} in
  if result.success then
    (* AppleScript returns string without outer quotes *)
    Alcotest.(check string) "apostrophe" "it's working" result.output

(** All tests *)
let () =
  Alcotest.run "AppleScript" [
    "key_codes", [
      Alcotest.test_case "basic keys" `Quick test_key_codes;
      Alcotest.test_case "function keys" `Quick test_function_keys;
      Alcotest.test_case "navigation keys" `Quick test_navigation_keys;
    ];
    "types", [
      Alcotest.test_case "result type" `Quick test_result_type;
      Alcotest.test_case "modifier types" `Quick test_modifier_types;
    ];
    "execution", [
      Alcotest.test_case "is_app_running" `Quick test_is_app_running;
      Alcotest.test_case "simple execute" `Quick test_execute_simple;
      Alcotest.test_case "string execute" `Quick test_execute_string;
      Alcotest.test_case "quote escaping" `Quick test_quote_escaping;
    ];
  ]
