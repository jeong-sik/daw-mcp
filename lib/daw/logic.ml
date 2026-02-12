(** Logic Pro AppleScript Driver

    Control Logic Pro X via AppleScript + System Events.
    Note: Logic Pro has limited scripting support, so this uses
    keyboard shortcuts and menu automation.

    Keyboard shortcuts (default Logic Pro):
    - Space: Play/Stop
    - R: Record
    - , (comma): Rewind
    - . (period): Forward
    - Enter: Go to beginning

    Note: For deep integration (plugin params, metering), use AU plugin bridge.
*)

open Daw_driver.Driver

(** Logic Pro state *)
type state = {
  mutable connected : bool;
  mutable transport_state : transport_state;
  mutable tempo : float;
  mutable position : float;
  mutable selected_track : int;
}

let state = {
  connected = false;
  transport_state = Stopped;
  tempo = 120.0;
  position = 0.0;
  selected_track = 1;
}

(** App name for AppleScript *)
let app_name = "Logic Pro"
let process_name = "Logic Pro"

(** Check if Logic Pro is running *)
let detect_logic () =
  Transport.Applescript.is_app_running process_name

(** Ensure Logic is frontmost for keyboard commands *)
let ensure_frontmost () =
  let result = Transport.Applescript.activate_app app_name in
  if not result.success then
    Logs.warn (fun m -> m "Failed to activate Logic Pro: %s"
      (Option.value result.error ~default:"unknown error"));
  (* Small delay for app to come to front *)
  Time_compat.sleep 0.1;
  result.success

(** Send key to Logic Pro *)
let send_key key =
  if ensure_frontmost () then
    Transport.Applescript.send_keystroke process_name key ()
  else
    { Transport.Applescript.success = false; output = ""; error = Some "Could not activate Logic Pro" }

(** Send key code to Logic Pro *)
let send_keycode code =
  if ensure_frontmost () then
    Transport.Applescript.send_keycode process_name code ()
  else
    { Transport.Applescript.success = false; output = ""; error = Some "Could not activate Logic Pro" }

(** Send key with modifiers *)
let send_key_mod key modifiers =
  if ensure_frontmost () then
    Transport.Applescript.send_keystroke process_name key ~modifiers ()
  else
    { Transport.Applescript.success = false; output = ""; error = Some "Could not activate Logic Pro" }

module Logic_driver : DAW_DRIVER = struct
  let name = "Logic Pro"

  let get_info () =
    Eio.Promise.create_resolved (Ok {
      daw_id = LogicPro;
      name = "Logic Pro";
      version = None;
      capabilities = ();
    })

  let connect ~sw:_ ~net:_ () =
    if detect_logic () then begin
      state.connected <- true;
      Logs.info (fun m -> m "Connected to Logic Pro");
      Eio.Promise.create_resolved (Ok true)
    end else
      Eio.Promise.create_resolved (Ok false)

  let disconnect () =
    state.connected <- false;
    Logs.info (fun m -> m "Disconnected from Logic Pro")

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
    (* Space toggles play/stop in Logic *)
    let result = send_keycode Transport.Applescript.KeyCode.space in
    if result.success then begin
      state.transport_state <- Stopped;
      Eio.Promise.create_resolved (Ok ())
    end else
      Eio.Promise.create_resolved (Error (Failure (Option.value result.error ~default:"Stop failed")))

  let record () =
    let result = send_key "r" in
    if result.success then begin
      state.transport_state <- Recording;
      Eio.Promise.create_resolved (Ok ())
    end else
      Eio.Promise.create_resolved (Error (Failure (Option.value result.error ~default:"Record failed")))

  let pause () =
    (* Logic doesn't have a dedicated pause - use play/stop toggle *)
    stop ()

  let get_transport_state () =
    (* Note: We can't reliably query Logic's state via AppleScript *)
    Eio.Promise.create_resolved (Ok state.transport_state)

  let set_position _seconds =
    (* Would need to use the Go To Position dialog (Cmd+/) *)
    Eio.Promise.create_resolved (Error (Failure "Position setting requires manual input in Logic"))

  let get_position () =
    Eio.Promise.create_resolved (Ok {
      bars = 1;
      beats = 1;
      ticks = 0;
      seconds = state.position;
    })

  (* Tempo *)
  let set_tempo _bpm =
    (* Would need to double-click tempo display or use menu *)
    Eio.Promise.create_resolved (Error (Failure "Tempo setting requires AU plugin bridge"))

  let get_tempo () =
    Eio.Promise.create_resolved (Ok state.tempo)

  (* Tracks *)
  let get_tracks () =
    (* Track list not accessible via AppleScript *)
    Eio.Promise.create_resolved (Ok [])

  let select_track index =
    (* Use up/down arrows to navigate tracks *)
    let current = state.selected_track in
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
      state.selected_track <- index;
      Eio.Promise.create_resolved (Ok ())
    end else
      Eio.Promise.create_resolved (Error (Failure "Track selection failed"))

  let get_selected_track () =
    Eio.Promise.create_resolved (Ok state.selected_track)

  (* Mixer - limited without plugin *)
  let set_volume ~track_index:_ _value =
    Eio.Promise.create_resolved (Error (Failure "Volume control requires AU plugin bridge"))

  let set_pan ~track_index:_ _value =
    Eio.Promise.create_resolved (Error (Failure "Pan control requires AU plugin bridge"))

  let set_mute ~track_index:_ _enabled =
    (* M key toggles mute on selected track *)
    let result = send_key "m" in
    if result.success then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Mute toggle failed"))

  let set_solo ~track_index:_ _enabled =
    (* S key toggles solo on selected track *)
    let result = send_key "s" in
    if result.success then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Solo toggle failed"))

  let set_arm ~track_index:_ _enabled =
    (* R key with Shift toggles record enable *)
    let result = send_key_mod "r" [`Shift] in
    if result.success then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Arm toggle failed"))

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

  (* Markers *)
  let get_markers () =
    Eio.Promise.create_resolved (Ok [])

  let add_marker name =
    (* Option+' creates marker at playhead *)
    let result = send_key_mod "'" [`Option] in
    if result.success then
      Eio.Promise.create_resolved (Ok {
        id = 0;
        name;
        position = { bars = 1; beats = 1; ticks = 0; seconds = 0.0 };
        is_region = false;
        end_position = None;
        color = None;
      })
    else
      Eio.Promise.create_resolved (Error (Failure "Marker creation failed"))

  let goto_marker _id =
    Eio.Promise.create_resolved (Error (Failure "Marker navigation requires marker number"))

  (* Metering - requires AU bridge *)
  let get_meter ~track_index:_ =
    Eio.Promise.create_resolved (Error (Failure "Metering requires AU plugin bridge"))

  (* Automation *)
  let read_automation ~track_index:_ ~param_name:_ ~start_time:_ ~end_time:_ =
    Eio.Promise.create_resolved (Ok [])

  let write_automation ~track_index:_ ~param_name:_ _points =
    Eio.Promise.create_resolved (Error (Failure "Automation requires AU plugin bridge"))

  let set_automation_mode ~track_index:_ _mode =
    (* A key cycles through automation modes *)
    let result = send_key "a" in
    if result.success then
      Eio.Promise.create_resolved (Ok ())
    else
      Eio.Promise.create_resolved (Error (Failure "Automation mode change failed"))
end

let create () : (module DAW_DRIVER) = (module Logic_driver)

let register () =
  Daw_driver.Driver.register {
    daw_id = LogicPro;
    create;
    detect = detect_logic;
  }
