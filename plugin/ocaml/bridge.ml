(** DAW Bridge - Pure OCaml Plugin Logic

    This module implements the core plugin functionality in OCaml.
    It's called from the minimal C shim via caml_callback.

    Key responsibilities:
    1. IPC with daw-mcp server (Unix socket)
    2. Parameter state management
    3. Real-time meter data collection
    4. Marker/Region management
    5. Routing configuration
    6. Render/Bounce operations
*)

(** {1 Parameter Types} *)

type param_info = {
  id : int;
  name : string;
  min_value : float;
  max_value : float;
  default_value : float;
  mutable current_value : float;
  unit : string;
  plugin_id : int;
}

(** {1 Marker Types} *)

type marker = {
  marker_id : int;
  name : string;
  position : float;
  color : int option;
}

type region = {
  region_id : int;
  name : string;
  start_pos : float;
  end_pos : float;
  color : int option;
}

(** {1 Routing Types} *)

type send = {
  send_id : int;
  dest_track : int;
  mutable level : float;
  mutable pan : float;
  mutable enabled : bool;
}

type routing = {
  track_index : int;
  input_channels : int list;
  output_channels : int list;
  mutable sends : send list;
}

(** {1 Render Types} *)

type render_format =
  | WAV
  | AIFF
  | MP3
  | FLAC
  | OGG

type render_settings = {
  format : render_format;
  sample_rate : int;
  bit_depth : int;
  start_time : float;
  end_time : float;
  normalize : bool;
  output_path : string;
}

type render_status =
  | Idle
  | Rendering of float
  | Completed of string
  | Failed of string

(** {1 Plugin State} *)

type t = {
  mutable sample_rate : float;
  mutable block_size : int;
  mutable is_active : bool;
  mutable is_processing : bool;

  (* Metering *)
  mutable peak_l : float;
  mutable peak_r : float;
  mutable rms_l : float;
  mutable rms_r : float;

  (* IPC *)
  mutable socket_fd : Unix.file_descr option;
  mutable connected : bool;

  (* Extended state *)
  mutable params : param_info list;
  mutable markers : marker list;
  mutable regions : region list;
  mutable routing : routing option;
  mutable render_status : render_status;
}

(** Default socket path for IPC *)
let socket_path = "/tmp/daw-mcp.sock"

(** ID counters *)
let next_marker_id = ref 1
let next_region_id = ref 1
let next_send_id = ref 1

(** Create new plugin instance *)
let create () = {
  sample_rate = 44100.0;
  block_size = 512;
  is_active = false;
  is_processing = false;
  peak_l = 0.0;
  peak_r = 0.0;
  rms_l = 0.0;
  rms_r = 0.0;
  socket_fd = None;
  connected = false;
  params = [];
  markers = [];
  regions = [];
  routing = None;
  render_status = Idle;
}

(** Connect to daw-mcp server via Unix socket *)
let connect_to_server t =
  try
    let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Unix.connect fd (Unix.ADDR_UNIX socket_path);
    t.socket_fd <- Some fd;
    t.connected <- true;
    true
  with Unix.Unix_error _ ->
    t.connected <- false;
    false

(** Disconnect from server *)
let disconnect_from_server t =
  match t.socket_fd with
  | Some fd ->
    Unix.close fd;
    t.socket_fd <- None;
    t.connected <- false
  | None -> ()

(** Send JSON-RPC message to server *)
let send_message t msg =
  match t.socket_fd with
  | Some fd ->
    let data = msg ^ "\n" in
    let len = String.length data in
    let written = Unix.write_substring fd data 0 len in
    written = len
  | None -> false

(** Read response from server (non-blocking) *)
let read_response t =
  match t.socket_fd with
  | Some fd ->
    let buf = Bytes.create 4096 in
    begin try
      Unix.set_nonblock fd;
      let len = Unix.read fd buf 0 4096 in
      Unix.clear_nonblock fd;
      if len > 0 then
        Some (Bytes.sub_string buf 0 len)
      else
        None
    with Unix.Unix_error (Unix.EAGAIN, _, _) | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) ->
      Unix.clear_nonblock fd;
      None
    end
  | None -> None

(** Initialize plugin (called from C shim) *)
let init () =
  let t = create () in
  ignore (connect_to_server t);
  t

(** Destroy plugin (called from C shim) *)
let destroy t =
  disconnect_from_server t

(** Activate plugin with audio settings (called from C shim) *)
let activate t sample_rate block_size =
  t.sample_rate <- sample_rate;
  t.block_size <- block_size;
  t.is_active <- true;
  if not t.connected then
    ignore (connect_to_server t)

(** Deactivate plugin (called from C shim) *)
let deactivate t =
  t.is_active <- false

(** Start processing (called from C shim) *)
let start_processing t =
  t.is_processing <- true

(** Stop processing (called from C shim) *)
let stop_processing t =
  t.is_processing <- false

(** Calculate RMS value from samples *)
let calculate_rms samples =
  let n = Array.length samples in
  if n = 0 then 0.0
  else begin
    let sum_sq = Array.fold_left (fun acc s -> acc +. (s *. s)) 0.0 samples in
    sqrt (sum_sq /. float_of_int n)
  end

(** Calculate peak value from samples *)
let calculate_peak samples =
  Array.fold_left (fun acc s -> max acc (abs_float s)) 0.0 samples

(** Convert linear amplitude to dB *)
let linear_to_db value =
  if value <= 0.0 then -100.0
  else 20.0 *. log10 value

(** Process audio block (called from C shim) *)
let process t =
  if not t.is_processing then ()
  else begin
    if t.connected then begin
      let msg = Printf.sprintf
        {|{"jsonrpc":"2.0","method":"meter_update","params":{"peak_l":%.2f,"peak_r":%.2f,"rms_l":%.2f,"rms_r":%.2f}}|}
        (linear_to_db t.peak_l)
        (linear_to_db t.peak_r)
        (linear_to_db t.rms_l)
        (linear_to_db t.rms_r)
      in
      ignore (send_message t msg)
    end
  end

(** {1 Parameter Management} *)

let get_param t param_id =
  match List.find_opt (fun p -> p.id = param_id) t.params with
  | Some p -> p.current_value
  | None -> 0.0

let set_param t param_id value =
  match List.find_opt (fun p -> p.id = param_id) t.params with
  | Some p ->
    let clamped = max p.min_value (min p.max_value value) in
    p.current_value <- clamped;
    (* Notify server of parameter change *)
    if t.connected then begin
      let msg = Printf.sprintf
        {|{"jsonrpc":"2.0","method":"param_changed","params":{"id":%d,"value":%.4f}}|}
        param_id clamped
      in
      ignore (send_message t msg)
    end
  | None -> ()

let get_param_info t param_id =
  List.find_opt (fun p -> p.id = param_id) t.params

let list_params t plugin_id =
  List.filter (fun p -> p.plugin_id = plugin_id) t.params

let register_param t param =
  (* Remove existing param with same ID, then add new one *)
  t.params <- param :: List.filter (fun p -> p.id <> param.id) t.params

(** {1 Marker Management} *)

let get_markers t = t.markers

let add_marker t ~name ~position ?color () =
  let marker_id = !next_marker_id in
  incr next_marker_id;
  let m = { marker_id; name; position; color } in
  t.markers <- m :: t.markers;
  m

let remove_marker t marker_id =
  let len_before = List.length t.markers in
  t.markers <- List.filter (fun m -> m.marker_id <> marker_id) t.markers;
  List.length t.markers < len_before

let get_regions t = t.regions

let add_region t ~name ~start_pos ~end_pos ?color () =
  let region_id = !next_region_id in
  incr next_region_id;
  let r = { region_id; name; start_pos; end_pos; color } in
  t.regions <- r :: t.regions;
  r

let remove_region t region_id =
  let len_before = List.length t.regions in
  t.regions <- List.filter (fun r -> r.region_id <> region_id) t.regions;
  List.length t.regions < len_before

(** {1 Routing} *)

let get_routing t track_index =
  match t.routing with
  | Some r when r.track_index = track_index -> Some r
  | _ -> None

let add_send t ~track_index ~dest_track ~level =
  let send_id = !next_send_id in
  incr next_send_id;
  let s = { send_id; dest_track; level; pan = 0.0; enabled = true } in
  (match t.routing with
   | Some r when r.track_index = track_index ->
     r.sends <- s :: r.sends
   | _ ->
     t.routing <- Some {
       track_index;
       input_channels = [1; 2];
       output_channels = [1; 2];
       sends = [s];
     });
  s

let remove_send t ~track_index ~send_id =
  match t.routing with
  | Some r when r.track_index = track_index ->
    let len_before = List.length r.sends in
    r.sends <- List.filter (fun s -> s.send_id <> send_id) r.sends;
    List.length r.sends < len_before
  | _ -> false

let set_send_level t ~track_index ~send_id level =
  match t.routing with
  | Some r when r.track_index = track_index ->
    (match List.find_opt (fun s -> s.send_id = send_id) r.sends with
     | Some s -> s.level <- level; true
     | None -> false)
  | _ -> false

(** {1 Render/Bounce} *)

let format_to_string = function
  | WAV -> "wav"
  | AIFF -> "aiff"
  | MP3 -> "mp3"
  | FLAC -> "flac"
  | OGG -> "ogg"

let format_of_string = function
  | "wav" -> Some WAV
  | "aiff" -> Some AIFF
  | "mp3" -> Some MP3
  | "flac" -> Some FLAC
  | "ogg" -> Some OGG
  | _ -> None

let start_render t settings =
  match t.render_status with
  | Rendering _ -> false  (* Already rendering *)
  | _ ->
    t.render_status <- Rendering 0.0;
    (* In real implementation, this would start actual render process *)
    if t.connected then begin
      let msg = Printf.sprintf
        {|{"jsonrpc":"2.0","method":"render_start","params":{"format":"%s","sample_rate":%d,"bit_depth":%d,"start":%.2f,"end":%.2f,"normalize":%b,"output":"%s"}}|}
        (format_to_string settings.format)
        settings.sample_rate
        settings.bit_depth
        settings.start_time
        settings.end_time
        settings.normalize
        settings.output_path
      in
      ignore (send_message t msg)
    end;
    true

let get_render_status t = t.render_status

let cancel_render t =
  match t.render_status with
  | Rendering _ ->
    t.render_status <- Failed "Cancelled by user";
    if t.connected then
      ignore (send_message t {|{"jsonrpc":"2.0","method":"render_cancel"}|})
  | _ -> ()

(** {1 Transport Commands} *)

let send_transport_command t cmd =
  if t.connected then begin
    let msg = Printf.sprintf
      {|{"jsonrpc":"2.0","method":"transport","params":{"command":"%s"}}|}
      cmd
    in
    ignore (send_message t msg)
  end

let play t = send_transport_command t "play"
let stop t = send_transport_command t "stop"
let record t = send_transport_command t "record"

(** {1 JSON Serialization} *)

let param_to_json p =
  `Assoc [
    ("id", `Int p.id);
    ("name", `String p.name);
    ("min_value", `Float p.min_value);
    ("max_value", `Float p.max_value);
    ("default_value", `Float p.default_value);
    ("current_value", `Float p.current_value);
    ("unit", `String p.unit);
    ("plugin_id", `Int p.plugin_id);
  ]

let marker_to_json m =
  `Assoc ([
    ("marker_id", `Int m.marker_id);
    ("name", `String m.name);
    ("position", `Float m.position);
  ] @ match m.color with
    | Some c -> [("color", `Int c)]
    | None -> [])

let region_to_json r =
  `Assoc ([
    ("region_id", `Int r.region_id);
    ("name", `String r.name);
    ("start_pos", `Float r.start_pos);
    ("end_pos", `Float r.end_pos);
  ] @ match r.color with
    | Some c -> [("color", `Int c)]
    | None -> [])

let send_to_json s =
  `Assoc [
    ("send_id", `Int s.send_id);
    ("dest_track", `Int s.dest_track);
    ("level", `Float s.level);
    ("pan", `Float s.pan);
    ("enabled", `Bool s.enabled);
  ]

let routing_to_json r =
  `Assoc [
    ("track_index", `Int r.track_index);
    ("input_channels", `List (List.map (fun i -> `Int i) r.input_channels));
    ("output_channels", `List (List.map (fun i -> `Int i) r.output_channels));
    ("sends", `List (List.map send_to_json r.sends));
  ]

let render_status_to_json = function
  | Idle -> `Assoc [("status", `String "idle")]
  | Rendering progress -> `Assoc [("status", `String "rendering"); ("progress", `Float progress)]
  | Completed path -> `Assoc [("status", `String "completed"); ("output_path", `String path)]
  | Failed msg -> `Assoc [("status", `String "failed"); ("error", `String msg)]

(** Register callbacks for C shim *)
let () =
  Callback.register "daw_bridge_init" init;
  Callback.register "daw_bridge_destroy" destroy;
  Callback.register "daw_bridge_activate" activate;
  Callback.register "daw_bridge_deactivate" deactivate;
  Callback.register "daw_bridge_process" process
