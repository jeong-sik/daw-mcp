(** SSE (Server-Sent Events) - Real-time streaming for metering data

    Implements SSE protocol over HTTP for streaming audio meter data
    to clients in real-time.
*)

(** SSE event types *)
type event_type =
  | Meter
  | Automation
  | Transport
  | Error
  | Ping

let event_type_to_string = function
  | Meter -> "meter"
  | Automation -> "automation"
  | Transport -> "transport"
  | Error -> "error"
  | Ping -> "ping"

(** SSE event *)
type event = {
  event_type : event_type;
  data : Yojson.Safe.t;
  id : string option;
  retry : int option;  (** milliseconds *)
}

(** Create an SSE event *)
let create_event ~event_type ~data ?id ?retry () =
  { event_type; data; id; retry }

(** Format an event as SSE text *)
let format_event event =
  let buf = Buffer.create 256 in
  (* Event type *)
  Buffer.add_string buf (Printf.sprintf "event: %s\n" (event_type_to_string event.event_type));
  (* Optional ID *)
  (match event.id with
   | Some id -> Buffer.add_string buf (Printf.sprintf "id: %s\n" id)
   | None -> ());
  (* Optional retry *)
  (match event.retry with
   | Some ms -> Buffer.add_string buf (Printf.sprintf "retry: %d\n" ms)
   | None -> ());
  (* Data (JSON) *)
  Buffer.add_string buf (Printf.sprintf "data: %s\n\n" (Yojson.Safe.to_string event.data));
  Buffer.contents buf

(** SSE stream configuration *)
type stream_config = {
  frame_rate : int;  (** frames per second (30 or 60) *)
  include_input : bool;
  track_indices : int list option;  (** None = all tracks *)
}

let default_config = {
  frame_rate = 30;
  include_input = false;
  track_indices = None;
}

(** Frame interval in seconds *)
let frame_interval config =
  1.0 /. Float.of_int config.frame_rate

(** SSE stream state *)
type stream_state = {
  config : stream_config;
  mutable running : bool;
  mutable event_id : int;
  mutable last_frame_time : float;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Time.clock;
}

(** Create a new stream state *)
let create_stream ~sw ~clock ?(config = default_config) () = {
  config;
  running = false;
  event_id = 0;
  last_frame_time = 0.0;
  sw;
  clock;
}

(** Generate next event ID *)
let next_event_id state =
  state.event_id <- state.event_id + 1;
  string_of_int state.event_id

(** Create meter event from frame *)
let meter_event_of_frame ~state (frame : Metering.meter_frame) =
  let id = next_event_id state in
  create_event
    ~event_type:Meter
    ~data:(Metering.frame_to_json frame)
    ~id
    ()

(** Create ping event (keepalive) *)
let ping_event ~state =
  let id = next_event_id state in
  create_event
    ~event_type:Ping
    ~data:(`Assoc [("timestamp", `Float (Unix.gettimeofday ()))])
    ~id
    ()

(** Create error event *)
let error_event ~state ~message =
  let id = next_event_id state in
  create_event
    ~event_type:Error
    ~data:(`Assoc [
      ("message", `String message);
      ("timestamp", `Float (Unix.gettimeofday ()));
    ])
    ~id
    ()

(** HTTP headers for SSE response *)
let sse_headers = [
  ("Content-Type", "text/event-stream");
  ("Cache-Control", "no-cache");
  ("Connection", "keep-alive");
  ("X-Accel-Buffering", "no");  (* Disable nginx buffering *)
]

(** Start streaming (for integration with HTTP server) *)
let start_stream state =
  state.running <- true;
  state.last_frame_time <- Unix.gettimeofday ()

(** Stop streaming *)
let stop_stream state =
  state.running <- false

(** Check if stream is running *)
let is_running state = state.running

(** Get stream config *)
let get_config state = state.config

(** Check if should emit frame based on frame rate *)
let should_emit_frame state =
  let now = Unix.gettimeofday () in
  let interval = frame_interval state.config in
  if now -. state.last_frame_time >= interval then begin
    state.last_frame_time <- now;
    true
  end else
    false

(** Sleep until next frame *)
let sleep_until_next_frame state =
  let now = Unix.gettimeofday () in
  let interval = frame_interval state.config in
  let elapsed = now -. state.last_frame_time in
  let remaining = interval -. elapsed in
  if remaining > 0.0 then
    Eio.Time.sleep state.clock remaining

(** Stream meter data (generator function for use with Eio) *)
let generate_meter_events ~state ~get_meter_frame () =
  Seq.unfold (fun () ->
    if not state.running then None
    else begin
      sleep_until_next_frame state;
      if should_emit_frame state then
        match get_meter_frame () with
        | Some frame ->
          let event = meter_event_of_frame ~state frame in
          Some (format_event event, ())
        | None ->
          (* No data, send ping *)
          let event = ping_event ~state in
          Some (format_event event, ())
      else
        Some ("", ())  (* Skip frame *)
    end
  ) ()

(** Meter stream configuration from JSON *)
let config_of_json json =
  let open Yojson.Safe.Util in
  let frame_rate = json |> member "frame_rate" |> to_int_option |> Option.value ~default:30 in
  let include_input = json |> member "include_input" |> to_bool_option |> Option.value ~default:false in
  let track_indices =
    match json |> member "track_indices" with
    | `Null -> None
    | `List l -> Some (List.map to_int l)
    | _ -> None
  in
  { frame_rate; include_input; track_indices }

(** MCP tool for meter streaming *)
let meter_stream_tool = {|{
  "name": "daw_meter_stream",
  "description": "Start real-time audio meter streaming via SSE. Returns an SSE stream URL.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "frame_rate": {
        "type": "integer",
        "description": "Frames per second (30 or 60)",
        "default": 30,
        "enum": [30, 60]
      },
      "include_input": {
        "type": "boolean",
        "description": "Include input meters",
        "default": false
      },
      "track_indices": {
        "type": "array",
        "items": {"type": "integer"},
        "description": "Track indices to monitor (null for all)"
      }
    }
  }
}|}

(** Transport state change event *)
let transport_event ~state ~playing ~recording ~position =
  let id = next_event_id state in
  create_event
    ~event_type:Transport
    ~data:(`Assoc [
      ("playing", `Bool playing);
      ("recording", `Bool recording);
      ("position", `Float position);
      ("timestamp", `Float (Unix.gettimeofday ()));
    ])
    ~id
    ()

(** Automation point change event *)
let automation_event ~state ~track_index ~param_name ~points =
  let id = next_event_id state in
  create_event
    ~event_type:Automation
    ~data:(`Assoc [
      ("track_index", `Int track_index);
      ("param_name", `String param_name);
      ("points", `List points);
      ("timestamp", `Float (Unix.gettimeofday ()));
    ])
    ~id
    ()
