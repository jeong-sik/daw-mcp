(** MCP Server Tests - JSON-RPC protocol handling *)

open Daw_mcp

(** JSON equality test - unused but kept for future use *)
let _json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

(** Test initialize response *)
let test_initialize () =
  let request = {|{"jsonrpc":"2.0","id":1,"method":"initialize"}|} in
  let response = Mcp_server.process_json request in
  let open Yojson.Safe.Util in

  (* Check protocol version *)
  let version = response |> member "result" |> member "protocolVersion" |> to_string in
  Alcotest.(check string) "protocol version" "2024-11-05" version;

  (* Check server info *)
  let name = response |> member "result" |> member "serverInfo" |> member "name" |> to_string in
  Alcotest.(check string) "server name" "daw-mcp" name

(** Test tools/list *)
let test_tools_list () =
  let request = {|{"jsonrpc":"2.0","id":2,"method":"tools/list"}|} in
  let response = Mcp_server.process_json request in
  let open Yojson.Safe.Util in

  let tools = response |> member "result" |> member "tools" |> to_list in
  Alcotest.(check bool) "has tools" true (List.length tools > 0);

  (* Check for expected tools *)
  let tool_names = List.map (fun t -> t |> member "name" |> to_string) tools in
  Alcotest.(check bool) "has daw_detect" true (List.mem "daw_detect" tool_names);
  Alcotest.(check bool) "has daw_transport" true (List.mem "daw_transport" tool_names);
  Alcotest.(check bool) "has daw_tempo" true (List.mem "daw_tempo" tool_names);
  Alcotest.(check bool) "has daw_mixer" true (List.mem "daw_mixer" tool_names);
  Alcotest.(check bool) "has daw_tracks" true (List.mem "daw_tracks" tool_names);
  Alcotest.(check bool) "has daw_status" true (List.mem "daw_status" tool_names)

(** Test tool call requires context - stateless API returns error *)
let test_tool_call_requires_context () =
  let request = {|{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"daw_detect","arguments":{"daw":"reaper"}}}|} in
  let response = Mcp_server.process_json request in
  let open Yojson.Safe.Util in

  (* Stateless API should return an error for tool calls *)
  let error = response |> member "error" in
  Alcotest.(check bool) "has error" true (error <> `Null);

  let code = error |> member "code" |> to_int in
  Alcotest.(check int) "error code" (-32603) code  (* Internal error - use process_json_with_context *)

(** Test unknown method *)
let test_unknown_method () =
  let request = {|{"jsonrpc":"2.0","id":6,"method":"unknown/method"}|} in
  let response = Mcp_server.process_json request in
  let open Yojson.Safe.Util in

  let error = response |> member "error" in
  Alcotest.(check bool) "has error" true (error <> `Null);

  let code = error |> member "code" |> to_int in
  Alcotest.(check int) "error code" (-32601) code

(** Test invalid JSON *)
let test_invalid_json () =
  let request = "not valid json {" in
  let response = Mcp_server.process_json request in
  let open Yojson.Safe.Util in

  let error = response |> member "error" in
  Alcotest.(check bool) "has error" true (error <> `Null);

  let code = error |> member "code" |> to_int in
  Alcotest.(check int) "parse error code" (-32700) code

(** Test ping *)
let test_ping () =
  let request = {|{"jsonrpc":"2.0","id":7,"method":"ping"}|} in
  let response = Mcp_server.process_json request in
  let open Yojson.Safe.Util in

  let result = response |> member "result" in
  Alcotest.(check bool) "has result" true (result <> `Null)

(** Test missing params for tool call *)
let test_missing_params () =
  let request = {|{"jsonrpc":"2.0","id":10,"method":"tools/call"}|} in
  let response = Mcp_server.process_json request in
  let open Yojson.Safe.Util in

  let error = response |> member "error" in
  Alcotest.(check bool) "has error" true (error <> `Null);

  let code = error |> member "code" |> to_int in
  Alcotest.(check int) "error code" (-32602) code  (* Invalid params *)

(** Test initialized notification *)
let test_initialized () =
  let request = {|{"jsonrpc":"2.0","method":"initialized"}|} in
  let response = Mcp_server.process_json request in
  let open Yojson.Safe.Util in

  (* Should return empty result *)
  let result = response |> member "result" in
  Alcotest.(check bool) "has result" true (result <> `Null)

(** Test process_line returns string *)
let test_process_line () =
  let request = {|{"jsonrpc":"2.0","id":1,"method":"ping"}|} in
  let response_str = Mcp_server.process_line request in
  let response = Yojson.Safe.from_string response_str in
  let open Yojson.Safe.Util in

  let result = response |> member "result" in
  Alcotest.(check bool) "has result" true (result <> `Null)

(** All tests *)
let () =
  Alcotest.run "MCP Server" [
    "protocol", [
      Alcotest.test_case "initialize" `Quick test_initialize;
      Alcotest.test_case "initialized" `Quick test_initialized;
      Alcotest.test_case "ping" `Quick test_ping;
      Alcotest.test_case "process_line" `Quick test_process_line;
    ];
    "tools", [
      Alcotest.test_case "tools/list" `Quick test_tools_list;
      Alcotest.test_case "tool call requires context" `Quick test_tool_call_requires_context;
      Alcotest.test_case "missing params" `Quick test_missing_params;
    ];
    "errors", [
      Alcotest.test_case "unknown method" `Quick test_unknown_method;
      Alcotest.test_case "invalid JSON" `Quick test_invalid_json;
    ];
  ]
