(** Integration Tests - MCP Server with Eio context *)

open Daw_mcp

(** Test integration manager creation *)
let test_create () =
  let integration = Daw_integration.create () in
  Alcotest.(check bool) "is not connected" false (Daw_integration.is_connected integration)

(** Test get_status when disconnected *)
let test_status_disconnected () =
  let integration = Daw_integration.create () in
  let (state, daw_name, error_msg) = Daw_integration.get_status integration in
  Alcotest.(check string) "state is disconnected" "disconnected" state;
  Alcotest.(check (option string)) "no daw name" None daw_name;
  Alcotest.(check (option string)) "no error" None error_msg

(** Test get_driver when disconnected *)
let test_get_driver_disconnected () =
  let integration = Daw_integration.create () in
  let driver = Daw_integration.get_driver integration in
  Alcotest.(check bool) "no driver" true (Option.is_none driver)

(** Test detect_running_daws - may return empty list if no DAWs running *)
let test_detect_running_daws () =
  Daw_integration.register_all_drivers ();
  let daws = Daw_integration.detect_running_daws () in
  (* Just check it doesn't crash - the list may be empty *)
  Alcotest.(check bool) "returns list" true (List.length daws >= 0)

(** Test daw_name function *)
let test_daw_name () =
  let open Daw_driver.Driver in
  Alcotest.(check string) "Reaper" "Reaper" (Daw_integration.daw_name Reaper);
  Alcotest.(check string) "Ableton" "Ableton Live" (Daw_integration.daw_name Ableton);
  Alcotest.(check string) "LogicPro" "Logic Pro" (Daw_integration.daw_name LogicPro);
  Alcotest.(check string) "MainStage" "MainStage" (Daw_integration.daw_name MainStage);
  Alcotest.(check string) "Cubase" "Cubase" (Daw_integration.daw_name Cubase);
  Alcotest.(check string) "ProTools" "Pro Tools" (Daw_integration.daw_name ProTools);
  Alcotest.(check string) "FLStudio" "FL Studio" (Daw_integration.daw_name FLStudio)

(** Test create_context with Eio *)
let test_create_context () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let ctx = Mcp_server.create_context ~sw ~net ~clock in
  (* Just check the context was created - more detailed tests would require a running DAW *)
  let integration = ctx.Mcp_server.integration in
  Alcotest.(check bool) "not connected initially" false (Daw_integration.is_connected integration)

(** Test process_json_with_context for daw_status *)
let test_process_daw_status () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let ctx = Mcp_server.create_context ~sw ~net ~clock in
  let request = {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"daw_status","arguments":{}}}|} in
  let response = Mcp_server.process_json_with_context ~ctx request in
  let open Yojson.Safe.Util in

  (* Should return result with content *)
  let content = response |> member "result" |> member "content" |> to_list in
  Alcotest.(check bool) "has content" true (List.length content > 0);

  let text = List.hd content |> member "text" |> to_string in
  let inner = Yojson.Safe.from_string text in
  let state = inner |> member "state" |> to_string in
  Alcotest.(check string) "state is disconnected" "disconnected" state

(** Test process_json_with_context for tools/list *)
let test_process_tools_list_with_context () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let ctx = Mcp_server.create_context ~sw ~net ~clock in
  let request = {|{"jsonrpc":"2.0","id":1,"method":"tools/list"}|} in
  let response = Mcp_server.process_json_with_context ~ctx request in
  let open Yojson.Safe.Util in

  let tools = response |> member "result" |> member "tools" |> to_list in
  (* 7 base + 5 Phase 6 + 5 Phase 5 tools = 17 total *)
  Alcotest.(check bool) "has 17 tools" true (List.length tools = 17)

(** Test connection error handling *)
let test_connection_error_handling () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let ctx = Mcp_server.create_context ~sw ~net ~clock in
  (* Try to play without connecting - should return error *)
  let request = {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"daw_transport","arguments":{"action":"play"}}}|} in
  let response = Mcp_server.process_json_with_context ~ctx request in
  let open Yojson.Safe.Util in

  let content = response |> member "result" |> member "content" |> to_list in
  let text = List.hd content |> member "text" |> to_string in
  let inner = Yojson.Safe.from_string text in
  let success = inner |> member "success" |> to_bool in
  Alcotest.(check bool) "should fail without connection" false success

(** All tests *)
let () =
  Alcotest.run "Integration" [
    "manager", [
      Alcotest.test_case "create" `Quick test_create;
      Alcotest.test_case "status disconnected" `Quick test_status_disconnected;
      Alcotest.test_case "get_driver disconnected" `Quick test_get_driver_disconnected;
      Alcotest.test_case "daw_name" `Quick test_daw_name;
    ];
    "detection", [
      Alcotest.test_case "detect_running_daws" `Quick test_detect_running_daws;
    ];
    "context", [
      Alcotest.test_case "create_context" `Quick test_create_context;
      Alcotest.test_case "process daw_status" `Quick test_process_daw_status;
      Alcotest.test_case "process tools/list" `Quick test_process_tools_list_with_context;
      Alcotest.test_case "connection error" `Quick test_connection_error_handling;
    ];
  ]
