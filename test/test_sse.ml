(** SSE Streaming Tests *)

open Sse

(** {1 Event Type Tests} *)

let test_event_type_to_string () =
  Alcotest.(check string) "meter" "meter" (event_type_to_string Meter);
  Alcotest.(check string) "automation" "automation" (event_type_to_string Automation);
  Alcotest.(check string) "transport" "transport" (event_type_to_string Transport);
  Alcotest.(check string) "error" "error" (event_type_to_string Error);
  Alcotest.(check string) "ping" "ping" (event_type_to_string Ping)

(** {1 Event Formatting Tests} *)

let contains_string s sub =
  try ignore (Str.search_forward (Str.regexp_string sub) s 0); true
  with Not_found -> false

let test_format_basic_event () =
  let event = create_event
    ~event_type:Ping
    ~data:(`Assoc [("test", `Int 1)])
    ()
  in
  let formatted = format_event event in
  Alcotest.(check bool) "contains event type" true (contains_string formatted "event: ping");
  Alcotest.(check bool) "contains data" true (contains_string formatted "data:");
  Alcotest.(check bool) "ends with double newline" true
    (String.sub formatted (String.length formatted - 2) 2 = "\n\n")

let test_format_event_with_id () =
  let event = create_event
    ~event_type:Meter
    ~data:(`Assoc [])
    ~id:"12345"
    ()
  in
  let formatted = format_event event in
  Alcotest.(check bool) "contains id" true (contains_string formatted "id: 12345")

let test_format_event_with_retry () =
  let event = create_event
    ~event_type:Error
    ~data:(`Assoc [("message", `String "test error")])
    ~retry:5000
    ()
  in
  let formatted = format_event event in
  Alcotest.(check bool) "contains retry" true (contains_string formatted "retry: 5000")

(** {1 Config Tests} *)

let test_default_config () =
  let config = default_config in
  Alcotest.(check int) "frame_rate" 30 config.frame_rate;
  Alcotest.(check bool) "include_input" false config.include_input;
  Alcotest.(check bool) "track_indices none" true (Option.is_none config.track_indices)

let test_config_of_json () =
  let json = Yojson.Safe.from_string {|{
    "frame_rate": 60,
    "include_input": true,
    "track_indices": [0, 1, 2]
  }|} in
  let config = config_of_json json in
  Alcotest.(check int) "frame_rate" 60 config.frame_rate;
  Alcotest.(check bool) "include_input" true config.include_input;
  Alcotest.(check bool) "has track_indices" true (Option.is_some config.track_indices);
  Alcotest.(check int) "track count" 3
    (List.length (Option.get config.track_indices))

let test_config_of_json_defaults () =
  let json = Yojson.Safe.from_string "{}" in
  let config = config_of_json json in
  Alcotest.(check int) "default frame_rate" 30 config.frame_rate;
  Alcotest.(check bool) "default include_input" false config.include_input

let test_frame_interval () =
  let config30 = { default_config with frame_rate = 30 } in
  let config60 = { default_config with frame_rate = 60 } in
  let eps = 0.001 in
  Alcotest.(check bool) "30fps interval" true
    (Float.abs (frame_interval config30 -. (1.0 /. 30.0)) < eps);
  Alcotest.(check bool) "60fps interval" true
    (Float.abs (frame_interval config60 -. (1.0 /. 60.0)) < eps)

(** {1 Stream State Tests} *)

let test_create_stream () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let state = create_stream ~sw ~clock () in
  (* Just verify creation works *)
  Alcotest.(check int) "state created" 30 (get_config state).frame_rate

let test_start_stop_stream () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let state = create_stream ~sw ~clock () in
  start_stream state;
  Alcotest.(check bool) "running after start" true (is_running state);
  stop_stream state;
  Alcotest.(check bool) "not running after stop" false (is_running state)

(** {1 Event Generation Tests} *)

let test_ping_event () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let state = create_stream ~sw ~clock () in
  let event = ping_event ~state in
  Alcotest.(check bool) "is ping" true (event.event_type = Ping);
  Alcotest.(check bool) "has id" true (Option.is_some event.id)

let test_error_event () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let state = create_stream ~sw ~clock () in
  let event = error_event ~state ~message:"Connection lost" in
  Alcotest.(check bool) "is error" true (event.event_type = Error);
  let open Yojson.Safe.Util in
  let msg = event.data |> member "message" |> to_string in
  Alcotest.(check string) "message" "Connection lost" msg

let test_transport_event () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let state = create_stream ~sw ~clock () in
  let event = transport_event ~state ~playing:true ~recording:false ~position:10.5 in
  Alcotest.(check bool) "is transport" true (event.event_type = Transport);
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "playing" true (event.data |> member "playing" |> to_bool);
  Alcotest.(check bool) "recording" false (event.data |> member "recording" |> to_bool)

let test_automation_event () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let state = create_stream ~sw ~clock () in
  let points = [`Assoc [("time", `Float 0.0); ("value", `Float 1.0)]] in
  let event = automation_event ~state ~track_index:0 ~param_name:"volume" ~points in
  Alcotest.(check bool) "is automation" true (event.event_type = Automation);
  let open Yojson.Safe.Util in
  Alcotest.(check string) "param_name" "volume"
    (event.data |> member "param_name" |> to_string)

let test_meter_event () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let state = create_stream ~sw ~clock () in
  let meter = Metering.{
    left = { rms_linear = 0.5; peak_linear = 0.8; rms_db = -6.0; peak_db = -2.0 };
    right = { rms_linear = 0.5; peak_linear = 0.8; rms_db = -6.0; peak_db = -2.0 };
    mono_sum = { rms_linear = 0.5; peak_linear = 0.8; rms_db = -6.0; peak_db = -2.0 };
  } in
  let frame = Metering.create_frame ~timestamp:1.0 ~track_index:0 ~output:meter () in
  let event = meter_event_of_frame ~state frame in
  Alcotest.(check bool) "is meter" true (event.event_type = Meter);
  Alcotest.(check bool) "has id" true (Option.is_some event.id)

(** {1 HTTP Headers Test} *)

let test_sse_headers () =
  Alcotest.(check bool) "has content-type" true
    (List.exists (fun (k, v) -> k = "Content-Type" && v = "text/event-stream") sse_headers);
  Alcotest.(check bool) "has cache-control" true
    (List.exists (fun (k, _) -> k = "Cache-Control") sse_headers)

(** {1 Tool Definition Test} *)

let test_meter_stream_tool () =
  let json = Yojson.Safe.from_string meter_stream_tool in
  let open Yojson.Safe.Util in
  let name = json |> member "name" |> to_string in
  Alcotest.(check string) "tool name" "daw_meter_stream" name

(** All tests *)
let () =
  Alcotest.run "SSE" [
    "event types", [
      Alcotest.test_case "to_string" `Quick test_event_type_to_string;
    ];
    "event formatting", [
      Alcotest.test_case "basic event" `Quick test_format_basic_event;
      Alcotest.test_case "with id" `Quick test_format_event_with_id;
      Alcotest.test_case "with retry" `Quick test_format_event_with_retry;
    ];
    "config", [
      Alcotest.test_case "default" `Quick test_default_config;
      Alcotest.test_case "from json" `Quick test_config_of_json;
      Alcotest.test_case "json defaults" `Quick test_config_of_json_defaults;
      Alcotest.test_case "frame interval" `Quick test_frame_interval;
    ];
    "stream state", [
      Alcotest.test_case "create" `Quick test_create_stream;
      Alcotest.test_case "start/stop" `Quick test_start_stop_stream;
    ];
    "events", [
      Alcotest.test_case "ping" `Quick test_ping_event;
      Alcotest.test_case "error" `Quick test_error_event;
      Alcotest.test_case "transport" `Quick test_transport_event;
      Alcotest.test_case "automation" `Quick test_automation_event;
      Alcotest.test_case "meter" `Quick test_meter_event;
    ];
    "http", [
      Alcotest.test_case "sse headers" `Quick test_sse_headers;
    ];
    "tool", [
      Alcotest.test_case "definition" `Quick test_meter_stream_tool;
    ];
  ]
