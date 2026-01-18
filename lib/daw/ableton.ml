(** Ableton Live OSC Driver

    Control Ableton Live via OSC using AbletonOSC or similar.
    Requires: AbletonOSC Max for Live device or LiveOSC Python script.

    OSC Address patterns (AbletonOSC):
    - /live/song/start_playing
    - /live/song/stop_playing
    - /live/song/set_tempo <bpm>
    - /live/track/<n>/set/volume <0-1>
    - /live/track/<n>/set/mute <0|1>
    - /live/clip/<track>/<clip>/fire
    - /live/scene/<n>/fire

    Default ports:
    - Send: 11000
    - Receive: 11001
*)

open Daw_driver.Driver
open Osc

(** Ableton state *)
type state = {
  mutable connected : bool;
  mutable osc_client : Osc.Transport.t option;
  mutable transport_state : transport_state;
  mutable tempo : float;
  mutable selected_track : int;
}

let state = {
  connected = false;
  osc_client = None;
  transport_state = Stopped;
  tempo = 120.0;
  selected_track = 0;
}

(** Default OSC ports *)
let default_host = "127.0.0.1"
let default_port = 11000

(** Detect Ableton Live running *)
let detect_ableton () =
  (* Check if Ableton Live process is running *)
  let cmd = "pgrep -x 'Ableton Live' || pgrep -x 'Live'" in
  let ic = Unix.open_process_in cmd in
  let result = try
    let _pid = input_line ic in
    true
  with End_of_file ->
    false
  in
  ignore (Unix.close_process_in ic);
  result

(** Send OSC message to Ableton *)
let send_osc msg =
  match state.osc_client with
  | Some client -> Osc.Transport.send client msg; true
  | None -> false

(** Ableton-specific OSC addresses *)
module Addr = struct
  let start_playing = "/live/song/start_playing"
  let stop_playing = "/live/song/stop_playing"
  let continue_playing = "/live/song/continue_playing"
  let set_tempo = "/live/song/set_tempo"
  let get_tempo = "/live/song/get_tempo"

  let track_volume n = Printf.sprintf "/live/track/%d/set/volume" n
  let track_pan n = Printf.sprintf "/live/track/%d/set/pan" n
  let track_mute n = Printf.sprintf "/live/track/%d/set/mute" n
  let track_solo n = Printf.sprintf "/live/track/%d/set/solo" n
  let track_arm n = Printf.sprintf "/live/track/%d/set/arm" n

  let clip_fire track clip = Printf.sprintf "/live/clip/%d/%d/fire" track clip
  let scene_fire n = Printf.sprintf "/live/scene/%d/fire" n

  let select_track n = Printf.sprintf "/live/track/%d/select" n
end

module Ableton_driver : DAW_DRIVER = struct
  let name = "Ableton Live"

  let get_info () =
    Eio.Promise.create_resolved (Ok {
      daw_id = Ableton;
      name = "Ableton Live";
      version = None;
      capabilities = ();
    })

  let connect ~sw ~net () =
    if detect_ableton () then begin
      let client = Osc.Transport.create ~sw ~net ~host:default_host ~port:default_port in
      state.osc_client <- Some client;
      state.connected <- true;
      Logs.info (fun m -> m "Connected to Ableton Live via OSC on port %d" default_port);
      Eio.Promise.create_resolved (Ok true)
    end else
      Eio.Promise.create_resolved (Ok false)

  let disconnect () =
    state.osc_client <- None;
    state.connected <- false;
    Logs.info (fun m -> m "Disconnected from Ableton Live")

  let is_connected () = state.connected

  (* Transport *)
  let play () =
    let msg = message Addr.start_playing [] in
    if send_osc msg then begin
      state.transport_state <- Playing;
      Eio.Promise.create_resolved (Ok ())
    end else
      Eio.Promise.create_resolved (Error (Failure "Failed to send play command"))

  let stop () =
    let msg = message Addr.stop_playing [] in
    if send_osc msg then begin
      state.transport_state <- Stopped;
      Eio.Promise.create_resolved (Ok ())
    end else
      Eio.Promise.create_resolved (Error (Failure "Failed to send stop command"))

  let record () =
    (* Ableton uses session view - fire clip to record *)
    Eio.Promise.create_resolved (Error (Failure "Use clip recording in Ableton"))

  let pause () =
    stop ()

  let get_transport_state () =
    Eio.Promise.create_resolved (Ok state.transport_state)

  let set_position _seconds =
    Eio.Promise.create_resolved (Error (Failure "Position setting not yet implemented"))

  let get_position () =
    Eio.Promise.create_resolved (Ok {
      bars = 1;
      beats = 1;
      ticks = 0;
      seconds = 0.0;
    })

  (* Tempo *)
  let set_tempo bpm =
    let msg = message Addr.set_tempo [Float32 bpm] in
    if send_osc msg then begin
      state.tempo <- bpm;
      Eio.Promise.create_resolved (Ok ())
    end else
      Eio.Promise.create_resolved (Error (Failure "Failed to set tempo"))

  let get_tempo () =
    Eio.Promise.create_resolved (Ok state.tempo)

  (* Tracks *)
  let get_tracks () =
    Eio.Promise.create_resolved (Ok [])

  let select_track index =
    let msg = message (Addr.select_track index) [] in
    if send_osc msg then begin
      state.selected_track <- index;
      Eio.Promise.create_resolved (Ok ())
    end else
      Eio.Promise.create_resolved (Error (Failure "Failed to select track"))

  let get_selected_track () =
    Eio.Promise.create_resolved (Ok state.selected_track)

  (* Mixer *)
  let set_volume ~track_index value =
    let msg = message (Addr.track_volume track_index) [Float32 value] in
    if send_osc msg then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Failed to set volume"))

  let set_pan ~track_index value =
    let msg = message (Addr.track_pan track_index) [Float32 value] in
    if send_osc msg then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Failed to set pan"))

  let set_mute ~track_index enabled =
    let value = if enabled then 1.0 else 0.0 in
    let msg = message (Addr.track_mute track_index) [Float32 value] in
    if send_osc msg then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Failed to set mute"))

  let set_solo ~track_index enabled =
    let value = if enabled then 1.0 else 0.0 in
    let msg = message (Addr.track_solo track_index) [Float32 value] in
    if send_osc msg then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Failed to set solo"))

  let set_arm ~track_index enabled =
    let value = if enabled then 1.0 else 0.0 in
    let msg = message (Addr.track_arm track_index) [Float32 value] in
    if send_osc msg then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Failed to set arm"))

  let get_mixer_channel ~track_index =
    Eio.Promise.create_resolved (Ok {
      track_index;
      volume_db = 0.0;
      pan = 0.0;
      mute = false;
      solo = false;
      arm = false;
      sends = [];
    })

  (* Plugins *)
  let get_plugin_param ~track_index:_ ~plugin_index:_ ~param_index:_ =
    Eio.Promise.create_resolved (Error (Failure "Plugin params not yet implemented"))

  let set_plugin_param ~track_index:_ ~plugin_index:_ ~param_index:_ _ =
    Eio.Promise.create_resolved (Error (Failure "Plugin params not yet implemented"))

  (* Markers *)
  let get_markers () =
    Eio.Promise.create_resolved (Ok [])

  let add_marker _name =
    Eio.Promise.create_resolved (Error (Failure "Markers not yet implemented"))

  let goto_marker _id =
    Eio.Promise.create_resolved (Error (Failure "Markers not yet implemented"))

  (* Metering *)
  let get_meter ~track_index:_ =
    Eio.Promise.create_resolved (Error (Failure "Metering not yet implemented"))

  (* Automation *)
  let read_automation ~track_index:_ ~param_name:_ ~start_time:_ ~end_time:_ =
    Eio.Promise.create_resolved (Ok [])

  let write_automation ~track_index:_ ~param_name:_ _points =
    Eio.Promise.create_resolved (Error (Failure "Automation not yet implemented"))

  let set_automation_mode ~track_index:_ _mode =
    Eio.Promise.create_resolved (Error (Failure "Automation modes not yet implemented"))
end

(** Ableton-specific functions *)

(** Fire a clip at track/clip position *)
let fire_clip ~track ~clip =
  let msg = message (Addr.clip_fire track clip) [] in
  send_osc msg

(** Fire a scene by index *)
let fire_scene scene =
  let msg = message (Addr.scene_fire scene) [] in
  send_osc msg

(** Continue playing from current position *)
let continue_playing () =
  let msg = message Addr.continue_playing [] in
  send_osc msg

let create () : (module DAW_DRIVER) = (module Ableton_driver)

let register () =
  Daw_driver.Driver.register {
    daw_id = Ableton;
    create;
    detect = detect_ableton;
  }
