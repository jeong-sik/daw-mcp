(** MainStage AppleScript Driver

    Control MainStage (Apple's live performance app) via AppleScript + System Events.
    MainStage has limited scripting support, similar to Logic Pro.

    Key differences from Logic Pro:
    - Live performance focused (patches, sets, concerts)
    - No traditional track/recording workflow
    - Keyboard shortcuts differ from Logic

    MainStage keyboard shortcuts (default):
    - Space: Start/Stop playback
    - P: Panic (all notes off)
    - Up/Down arrows: Navigate patches
    - Left/Right arrows: Previous/Next set
*)

open Daw_driver.Driver

(** MainStage state *)
type state = {
  mutable connected : bool;
  mutable transport_state : transport_state;
  mutable tempo : float;
  mutable current_patch : int;
  mutable current_set : int;
}

let state = {
  connected = false;
  transport_state = Stopped;
  tempo = 120.0;
  current_patch = 1;
  current_set = 1;
}

(** App name for AppleScript *)
let app_name = "MainStage"
let process_name = "MainStage"

(** Check if MainStage is running *)
let detect_mainstage () =
  Transport.Applescript.is_app_running process_name

(** Ensure MainStage is frontmost for keyboard commands *)
let ensure_frontmost () =
  let result = Transport.Applescript.activate_app app_name in
  if not result.success then
    Logs.warn (fun m -> m "Failed to activate MainStage: %s"
      (Option.value result.error ~default:"unknown error"));
  Time_compat.sleep 0.1;
  result.success

(** Send key to MainStage *)
let send_key key =
  if ensure_frontmost () then
    Transport.Applescript.send_keystroke process_name key ()
  else
    { Transport.Applescript.success = false; output = ""; error = Some "Could not activate MainStage" }

(** Send key code to MainStage *)
let send_keycode code =
  if ensure_frontmost () then
    Transport.Applescript.send_keycode process_name code ()
  else
    { Transport.Applescript.success = false; output = ""; error = Some "Could not activate MainStage" }

(** Send key with modifiers *)
let send_key_mod key modifiers =
  if ensure_frontmost () then
    Transport.Applescript.send_keystroke process_name key ~modifiers ()
  else
    { Transport.Applescript.success = false; output = ""; error = Some "Could not activate MainStage" }

module MainStage_driver : DAW_DRIVER = struct
  let name = "MainStage"

  let get_info () =
    Eio.Promise.create_resolved (Ok {
      daw_id = MainStage;
      name = "MainStage";
      version = None;
      capabilities = ();
    })

  let connect ~sw:_ ~net:_ () =
    if detect_mainstage () then begin
      state.connected <- true;
      Logs.info (fun m -> m "Connected to MainStage");
      Eio.Promise.create_resolved (Ok true)
    end else
      Eio.Promise.create_resolved (Ok false)

  let disconnect () =
    state.connected <- false;
    Logs.info (fun m -> m "Disconnected from MainStage")

  let is_connected () = state.connected

  (* Transport - using keyboard shortcuts *)
  let play () =
    let result = send_keycode Transport.Applescript.KeyCode.space in
    if result.success then begin
      state.transport_state <- Playing;
      Eio.Promise.create_resolved (Ok ())
    end else
      Eio.Promise.create_resolved (Error (Failure (Option.value result.error ~default:"Play failed")))

  let stop () =
    let result = send_keycode Transport.Applescript.KeyCode.space in
    if result.success then begin
      state.transport_state <- Stopped;
      Eio.Promise.create_resolved (Ok ())
    end else
      Eio.Promise.create_resolved (Error (Failure (Option.value result.error ~default:"Stop failed")))

  let record () =
    (* MainStage doesn't have traditional recording *)
    Eio.Promise.create_resolved (Error (Failure "MainStage does not support recording"))

  let pause () =
    stop ()

  let get_transport_state () =
    Eio.Promise.create_resolved (Ok state.transport_state)

  let set_position _seconds =
    Eio.Promise.create_resolved (Error (Failure "Position setting not applicable to MainStage"))

  let get_position () =
    Eio.Promise.create_resolved (Ok {
      bars = 1;
      beats = 1;
      ticks = 0;
      seconds = 0.0;
    })

  (* Tempo - MainStage follows concert tempo *)
  let set_tempo _bpm =
    Eio.Promise.create_resolved (Error (Failure "Tempo is set per concert in MainStage"))

  let get_tempo () =
    Eio.Promise.create_resolved (Ok state.tempo)

  (* Tracks/Patches - MainStage uses patches instead of tracks *)
  let get_tracks () =
    (* Return patches as "tracks" *)
    Eio.Promise.create_resolved (Ok [])

  let select_track index =
    (* Navigate to patch using up/down arrows *)
    let current = state.current_patch in
    let diff = index - current in
    let key = if diff > 0 then
      Transport.Applescript.KeyCode.down
    else
      Transport.Applescript.KeyCode.up
    in
    let rec send_keys n =
      if n <= 0 then true
      else
        let result = send_keycode key in
        result.success && send_keys (n - 1)
    in
    if send_keys (abs diff) then begin
      state.current_patch <- index;
      Eio.Promise.create_resolved (Ok ())
    end else
      Eio.Promise.create_resolved (Error (Failure "Patch selection failed"))

  let get_selected_track () =
    Eio.Promise.create_resolved (Ok state.current_patch)

  (* Mixer - limited in MainStage via AppleScript *)
  let set_volume ~track_index:_ _value =
    Eio.Promise.create_resolved (Error (Failure "Volume control requires AU plugin bridge"))

  let set_pan ~track_index:_ _value =
    Eio.Promise.create_resolved (Error (Failure "Pan control requires AU plugin bridge"))

  let set_mute ~track_index:_ _enabled =
    (* Cmd+M mutes the selected channel strip *)
    let result = send_key_mod "m" [`Command] in
    if result.success then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Mute toggle failed"))

  let set_solo ~track_index:_ _enabled =
    (* Cmd+S solos the selected channel strip *)
    let result = send_key_mod "s" [`Command] in
    if result.success then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Solo toggle failed"))

  let set_arm ~track_index:_ _enabled =
    Eio.Promise.create_resolved (Error (Failure "MainStage does not have arm/record enable"))

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

  (* Plugins - requires AU bridge *)
  let get_plugin_param ~track_index:_ ~plugin_index:_ ~param_index:_ =
    Eio.Promise.create_resolved (Error (Failure "Plugin params require AU bridge"))

  let set_plugin_param ~track_index:_ ~plugin_index:_ ~param_index:_ _ =
    Eio.Promise.create_resolved (Error (Failure "Plugin params require AU bridge"))

  (* Markers - MainStage doesn't use markers *)
  let get_markers () =
    Eio.Promise.create_resolved (Ok [])

  let add_marker _name =
    Eio.Promise.create_resolved (Error (Failure "MainStage does not support markers"))

  let goto_marker _id =
    Eio.Promise.create_resolved (Error (Failure "MainStage does not support markers"))

  (* Metering - requires AU bridge *)
  let get_meter ~track_index:_ =
    Eio.Promise.create_resolved (Error (Failure "Metering requires AU plugin bridge"))

  (* Automation - not applicable to MainStage live use *)
  let read_automation ~track_index:_ ~param_name:_ ~start_time:_ ~end_time:_ =
    Eio.Promise.create_resolved (Ok [])

  let write_automation ~track_index:_ ~param_name:_ _points =
    Eio.Promise.create_resolved (Error (Failure "MainStage does not support automation"))

  let set_automation_mode ~track_index:_ _mode =
    Eio.Promise.create_resolved (Error (Failure "MainStage does not support automation modes"))
end

(** MainStage-specific functions *)

(** Panic - all notes off (P key) *)
let panic () =
  send_key "p"

(** Next patch (down arrow) *)
let next_patch () =
  let result = send_keycode Transport.Applescript.KeyCode.down in
  if result.success then
    state.current_patch <- state.current_patch + 1;
  result

(** Previous patch (up arrow) *)
let prev_patch () =
  let result = send_keycode Transport.Applescript.KeyCode.up in
  if result.success then
    state.current_patch <- max 1 (state.current_patch - 1);
  result

(** Next set (right arrow) *)
let next_set () =
  let result = send_keycode Transport.Applescript.KeyCode.right in
  if result.success then
    state.current_set <- state.current_set + 1;
  result

(** Previous set (left arrow) *)
let prev_set () =
  let result = send_keycode Transport.Applescript.KeyCode.left in
  if result.success then
    state.current_set <- max 1 (state.current_set - 1);
  result

let create () : (module DAW_DRIVER) = (module MainStage_driver)

let register () =
  Daw_driver.Driver.register {
    daw_id = MainStage;
    create;
    detect = detect_mainstage;
  }
