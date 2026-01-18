(** Reaper OSC Driver - Control Reaper via OSC protocol

    Reaper OSC Configuration:
    - Enable OSC in Preferences → Control/OSC/Web
    - Default ports: 8000 (receive), 9000 (send to Reaper)
    - Pattern config: Default or Custom

    Reference: https://www.reaper.fm/sdk/osc/osc.php
*)

open Daw_driver.Driver

(** Reaper connection state *)
type state = {
  mutable client : Osc.Transport.t option;
  mutable host : string;
  mutable port : int;
  mutable connected : bool;
  mutable transport_state : transport_state;
  mutable tempo : float;
  mutable position : float;
}

(** Global state *)
let state = {
  client = None;
  host = "127.0.0.1";
  port = 8000;  (* Default Reaper OSC port *)
  connected = false;
  transport_state = Stopped;
  tempo = 120.0;
  position = 0.0;
}

(** Check if Reaper is running (macOS) *)
let detect_reaper () =
  try
    let ic = Unix.open_process_in "pgrep -x REAPER 2>/dev/null" in
    let result = try Some (input_line ic) with End_of_file -> None in
    ignore (Unix.close_process_in ic);
    Option.is_some result
  with _ -> false

(** Reaper OSC addresses *)
module Addr = struct
  (* Transport *)
  let play = "/play"
  let stop = "/stop"
  let record = "/record"
  let pause = "/pause"
  let rewind = "/rewind"
  let forward = "/forward"
  let goto_start = "/goto"
  let time = "/time"  (* position in seconds *)

  (* Tempo *)
  let tempo = "/tempo/raw"
  let tempo_str = "/tempo/str"

  (* Track control (1-indexed) *)
  let track n = Printf.sprintf "/track/%d" n
  let track_name n = Printf.sprintf "/track/%d/name" n
  let track_volume n = Printf.sprintf "/track/%d/volume" n
  let track_pan n = Printf.sprintf "/track/%d/pan" n
  let track_mute n = Printf.sprintf "/track/%d/mute" n
  let track_solo n = Printf.sprintf "/track/%d/solo" n
  let track_recarm n = Printf.sprintf "/track/%d/recarm" n
  let track_select n = Printf.sprintf "/track/%d/select" n

  (* Master track *)
  let master_volume = "/master/volume"
  let master_pan = "/master/pan"

  (* Actions (Reaper action IDs) *)
  let action id = Printf.sprintf "/action/%d" id

  (* Common action IDs *)
  let action_play = 40044
  let action_stop = 1016
  let action_pause = 40073
  let action_record = 1013
  let action_undo = 40029
  let action_redo = 40030
end

(** Send OSC message to Reaper *)
let send_osc address args =
  match state.client with
  | Some client ->
    Osc.Transport.send_message client address args;
    Ok ()
  | None ->
    Error (Failure "Not connected to Reaper")

(** Send OSC with float arg *)
let send_float address value =
  send_osc address [Osc.Float32 value]

(** Send OSC with int arg *)
let send_int address value =
  send_osc address [Osc.Int32 (Int32.of_int value)]

(** Send OSC trigger (no args or 1.0) *)
let send_trigger address =
  send_osc address [Osc.Float32 1.0]

module Reaper_driver : DAW_DRIVER = struct
  let name = "Reaper"

  let get_info () =
    Eio.Promise.create_resolved (Ok {
      daw_id = Reaper;
      name = "Reaper";
      version = None;  (* TODO: query via OSC *)
      capabilities = ();
    })

  let connect ~sw ~net () =
    let client = Osc.Transport.create ~sw ~net ~host:state.host ~port:state.port in
    state.client <- Some client;
    state.connected <- true;
    Logs.info (fun m -> m "Connected to Reaper at %s:%d" state.host state.port);
    Eio.Promise.create_resolved (Ok true)

  let disconnect () =
    (match state.client with
     | Some client -> Osc.Transport.close client
     | None -> ());
    state.client <- None;
    state.connected <- false;
    Logs.info (fun m -> m "Disconnected from Reaper")

  let is_connected () = state.connected

  (* Transport controls *)
  let play () =
    match send_trigger Addr.play with
    | Ok () ->
      state.transport_state <- Playing;
      Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let stop () =
    match send_trigger Addr.stop with
    | Ok () ->
      state.transport_state <- Stopped;
      Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let record () =
    match send_trigger Addr.record with
    | Ok () ->
      state.transport_state <- Recording;
      Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let pause () =
    match send_trigger Addr.pause with
    | Ok () ->
      state.transport_state <- Paused;
      Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let get_transport_state () =
    Eio.Promise.create_resolved (Ok state.transport_state)

  let set_position seconds =
    match send_float Addr.time seconds with
    | Ok () ->
      state.position <- seconds;
      Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let get_position () =
    (* Convert seconds to bars/beats/ticks (approximate, assumes 4/4 at current tempo) *)
    let seconds = state.position in
    let beats_per_second = state.tempo /. 60.0 in
    let total_beats = seconds *. beats_per_second in
    let bars = int_of_float (total_beats /. 4.0) + 1 in
    let beats = (int_of_float total_beats mod 4) + 1 in
    let ticks = int_of_float ((total_beats -. floor total_beats) *. 960.0) in
    Eio.Promise.create_resolved (Ok {
      bars;
      beats;
      ticks;
      seconds;
    })

  (* Tempo *)
  let set_tempo bpm =
    match send_float Addr.tempo bpm with
    | Ok () ->
      state.tempo <- bpm;
      Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let get_tempo () =
    Eio.Promise.create_resolved (Ok state.tempo)

  (* Tracks - stubs for now *)
  let get_tracks () =
    Eio.Promise.create_resolved (Error (Failure "Track query not implemented"))

  let select_track index =
    match send_trigger (Addr.track_select index) with
    | Ok () -> Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let get_selected_track () =
    Eio.Promise.create_resolved (Error (Failure "Track selection state not available"))

  (* Mixer *)
  let set_volume ~track_index value =
    match send_float (Addr.track_volume track_index) value with
    | Ok () -> Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let set_pan ~track_index value =
    (* Reaper pan: 0.0 = left, 0.5 = center, 1.0 = right *)
    let reaper_pan = (value +. 1.0) /. 2.0 in
    match send_float (Addr.track_pan track_index) reaper_pan with
    | Ok () -> Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let set_mute ~track_index enabled =
    let value = if enabled then 1.0 else 0.0 in
    match send_float (Addr.track_mute track_index) value with
    | Ok () -> Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let set_solo ~track_index enabled =
    let value = if enabled then 1.0 else 0.0 in
    match send_float (Addr.track_solo track_index) value with
    | Ok () -> Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let set_arm ~track_index enabled =
    let value = if enabled then 1.0 else 0.0 in
    match send_float (Addr.track_recarm track_index) value with
    | Ok () -> Eio.Promise.create_resolved (Ok ())
    | Error e -> Eio.Promise.create_resolved (Error e)

  let get_mixer_channel ~track_index =
    let _ = track_index in
    (* TODO: implement proper state tracking via OSC feedback *)
    Eio.Promise.create_resolved (Error (Failure "Mixer channel state not available"))

  (* Plugins - stubs *)
  let get_plugin_param ~track_index:_ ~plugin_index:_ ~param_index:_ =
    Eio.Promise.create_resolved (Error (Failure "Plugin params not yet implemented"))

  let set_plugin_param ~track_index:_ ~plugin_index:_ ~param_index:_ _ =
    Eio.Promise.create_resolved (Error (Failure "Plugin params not yet implemented"))

  (* Markers - stubs *)
  let get_markers () =
    Eio.Promise.create_resolved (Ok [])

  let add_marker _name =
    Eio.Promise.create_resolved (Error (Failure "Markers not yet implemented"))

  let goto_marker _id =
    Eio.Promise.create_resolved (Error (Failure "Markers not yet implemented"))

  (* Metering - requires plugin bridge *)
  let get_meter ~track_index:_ =
    Eio.Promise.create_resolved (Error (Failure "Metering requires plugin bridge"))

  (* Automation - stubs *)
  let read_automation ~track_index:_ ~param_name:_ ~start_time:_ ~end_time:_ =
    Eio.Promise.create_resolved (Ok [])

  let write_automation ~track_index:_ ~param_name:_ _points =
    Eio.Promise.create_resolved (Error (Failure "Automation not yet implemented"))

  let set_automation_mode ~track_index:_ _mode =
    Eio.Promise.create_resolved (Error (Failure "Automation not yet implemented"))
end

(** Create Reaper driver *)
let create () : (module DAW_DRIVER) = (module Reaper_driver)

(** Register driver *)
let register () =
  Daw_driver.Driver.register {
    daw_id = Reaper;
    create;
    detect = detect_reaper;
  }

(** Configure connection parameters *)
let configure ~host ~port =
  state.host <- host;
  state.port <- port
