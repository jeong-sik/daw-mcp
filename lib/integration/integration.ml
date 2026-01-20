(** DAW MCP Integration Layer

    Unified initialization and connection management for all DAW drivers.
    This module ties together the driver registry, MCP server, and
    provides automatic DAW detection and reconnection.
*)

open Daw_driver.Driver

(** Connection error types *)
type connection_error = [
  | `Unknown_daw of daw_id
  | `Not_running of daw_id
  | `Connection_failed of string
  | `No_daw_found
  | `Max_attempts
  | `Still_connecting
  | `Command_failed of string
]

(** Connection state *)
type connection_state =
  | Disconnected
  | Connecting
  | Connected of (module DAW_DRIVER)
  | Failed of string

(** Integration manager state *)
type t = {
  mutable state : connection_state;
  mutable last_daw_id : daw_id option;
  mutable reconnect_attempts : int;
  max_reconnect_attempts : int;
  breaker : Mcp_resilience.circuit_breaker;
}

(** Create new integration manager *)
let create () = {
  state = Disconnected;
  last_daw_id = None;
  reconnect_attempts = 0;
  max_reconnect_attempts = 3;
  breaker = Mcp_resilience.create_circuit_breaker ~name:"daw_driver" ~failure_threshold:5 ();
}

(** Reset circuit breaker state after successful connection *)
let reset_circuit_breaker cb =
  Eio.Mutex.use_rw ~protect:true cb.Mcp_resilience.mutex (fun () ->
    cb.Mcp_resilience.state <- Mcp_resilience.Closed;
    cb.Mcp_resilience.failure_count <- 0;
    cb.Mcp_resilience.success_count <- 0;
    cb.Mcp_resilience.last_failure_time <- 0.0;
    cb.Mcp_resilience.probe_in_progress <- false
  )

(** Register all available drivers *)
let register_all_drivers () =
  (* Register each driver - they add themselves to the registry *)
  Daw_drivers.Reaper.register ();
  Daw_drivers.Ableton.register ();
  Daw_drivers.Logic.register ();
  Daw_drivers.Mainstage.register ()
  (* Future: Cubase, ProTools, FLStudio via plugin bridge *)

(** Get human-readable DAW name *)
let daw_name = function
  | Reaper -> "Reaper"
  | Ableton -> "Ableton Live"
  | LogicPro -> "Logic Pro"
  | MainStage -> "MainStage"
  | Cubase -> "Cubase"
  | ProTools -> "Pro Tools"
  | FLStudio -> "FL Studio"

(** Detect all running DAWs *)
let detect_running_daws () =
  get_all ()
  |> List.filter (fun entry -> entry.detect ())
  |> List.map (fun entry -> entry.daw_id)

(** Connect to a specific DAW *)
let connect_to_daw t ~sw ~net daw_id =
  match find_by_id daw_id with
  | None ->
    t.state <- Failed (Printf.sprintf "Unknown DAW: %s" (daw_name daw_id));
    Error (`Unknown_daw daw_id)
  | Some entry ->
    t.state <- Connecting;
    let driver = entry.create () in
    let module D = (val driver : DAW_DRIVER) in
    let result = Eio.Promise.await (D.connect ~sw ~net ()) in
    match result with
    | Ok true ->
      t.state <- Connected driver;
      t.last_daw_id <- Some daw_id;
      t.reconnect_attempts <- 0;
      reset_circuit_breaker t.breaker;
      Logs.info (fun m -> m "Connected to %s" (daw_name daw_id));
      Ok driver
    | Ok false ->
      t.state <- Failed (Printf.sprintf "%s is not running" (daw_name daw_id));
      Error (`Not_running daw_id)
    | Error exn ->
      t.state <- Failed (Printexc.to_string exn);
      Error (`Connection_failed (Printexc.to_string exn))

(** Auto-detect and connect to first available DAW *)
let auto_connect t ~sw ~net =
  let running = detect_running_daws () in
  match running with
  | [] ->
    t.state <- Failed "No DAW detected";
    Error `No_daw_found
  | daw_id :: _ ->
    connect_to_daw t ~sw ~net daw_id

(** Disconnect from current DAW *)
let disconnect t =
  match t.state with
  | Connected driver ->
    let module D = (val driver : DAW_DRIVER) in
    D.disconnect ();
    t.state <- Disconnected;
    Logs.info (fun m -> m "Disconnected from DAW")
  | _ -> ()

(** Attempt reconnection *)
let try_reconnect t ~sw ~net =
  if t.reconnect_attempts >= t.max_reconnect_attempts then begin
    t.state <- Failed "Max reconnection attempts reached";
    Error `Max_attempts
  end else begin
    t.reconnect_attempts <- t.reconnect_attempts + 1;
    Logs.info (fun m -> m "Reconnection attempt %d/%d"
      t.reconnect_attempts t.max_reconnect_attempts);
    match t.last_daw_id with
    | Some daw_id -> connect_to_daw t ~sw ~net daw_id
    | None -> auto_connect t ~sw ~net
  end

(** Get current driver (if connected) *)
let get_driver t =
  match t.state with
  | Connected driver -> Some driver
  | _ -> None

(** Check if connected *)
let is_connected t =
  match t.state with
  | Connected _ -> true
  | _ -> false

(** Get connection status as JSON-friendly record *)
let get_status t =
  let state_str = match t.state with
    | Disconnected -> "disconnected"
    | Connecting -> "connecting"
    | Connected _ -> "connected"
    | Failed _ -> "error"
  in
  let error_msg = match t.state with
    | Failed msg -> Some msg
    | _ -> None
  in
  let daw_name = match t.state with
    | Connected driver ->
      let module D = (val driver : DAW_DRIVER) in
      Some D.name
    | _ -> None
  in
  (state_str, daw_name, error_msg)

(** Execute command with auto-reconnect and resilience *)
let with_driver t ~sw ~net ~clock ~op_name f =
  let op () =
    let res = 
      match t.state with
      | Connected driver -> f driver
      | Disconnected | Failed _ ->
          (* Try to reconnect *)
          begin match try_reconnect t ~sw ~net with
          | Ok driver -> f driver
          | Error err -> Error err
          end
      | Connecting ->
          Error `Still_connecting
    in
    match res with
    | Ok r -> Mcp_resilience.Ok r
    | Error err -> Mcp_resilience.Error (match err with
        | `Unknown_daw _ -> "Unknown DAW"
        | `Not_running _ -> "DAW is not running"
        | `Connection_failed msg -> "Connection failed: " ^ msg
        | `No_daw_found -> "No DAW found"
        | `Max_attempts -> "Max reconnection attempts reached"
        | `Still_connecting -> "Still connecting..."
        | `Command_failed msg -> "Command failed: " ^ msg)
  in
  let result = Mcp_resilience.with_retry_eio ~clock ~circuit_breaker:(Some t.breaker) ~op_name ~classify:(fun e -> Fail e) op in
  match result with
  | Ok r -> Ok r
  | Error err -> Error (`Connection_failed err)
  | CircuitOpen -> Error (`Connection_failed "Circuit breaker open")
  | TimedOut -> Error (`Connection_failed "Operation timed out")

(** Transport commands with error handling *)
module Transport = struct
  let play t ~sw ~net ~clock =
    with_driver t ~sw ~net ~clock ~op_name:"transport_play" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.play ()) with
      | Ok () -> Ok `Playing
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )

  let stop t ~sw ~net ~clock =
    with_driver t ~sw ~net ~clock ~op_name:"transport_stop" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.stop ()) with
      | Ok () -> Ok `Stopped
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )

  let record t ~sw ~net ~clock =
    with_driver t ~sw ~net ~clock ~op_name:"transport_record" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.record ()) with
      | Ok () -> Ok `Recording
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )

  let get_state t ~sw ~net ~clock =
    with_driver t ~sw ~net ~clock ~op_name:"transport_get_state" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.get_transport_state ()) with
      | Ok state -> Ok state
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )
end

(** Tempo commands *)
module Tempo = struct
  let get t ~sw ~net ~clock =
    with_driver t ~sw ~net ~clock ~op_name:"tempo_get" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.get_tempo ()) with
      | Ok bpm -> Ok bpm
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )

  let set t ~sw ~net ~clock bpm =
    with_driver t ~sw ~net ~clock ~op_name:"tempo_set" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.set_tempo bpm) with
      | Ok () -> Ok bpm
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )
end

(** Track commands *)
module Tracks = struct
  let get_all t ~sw ~net ~clock =
    with_driver t ~sw ~net ~clock ~op_name:"tracks_get_all" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.get_tracks ()) with
      | Ok tracks -> Ok tracks
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )

  let select t ~sw ~net ~clock index =
    with_driver t ~sw ~net ~clock ~op_name:"tracks_select" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.select_track index) with
      | Ok () -> Ok index
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )

  let get_selected t ~sw ~net ~clock =
    with_driver t ~sw ~net ~clock ~op_name:"tracks_get_selected" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.get_selected_track ()) with
      | Ok index -> Ok index
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )
end

(** Mixer commands *)
module Mixer = struct
  let set_volume t ~sw ~net ~clock ~track_index value =
    with_driver t ~sw ~net ~clock ~op_name:"mixer_set_volume" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.set_volume ~track_index value) with
      | Ok () -> Ok ()
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )

  let set_pan t ~sw ~net ~clock ~track_index value =
    with_driver t ~sw ~net ~clock ~op_name:"mixer_set_pan" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.set_pan ~track_index value) with
      | Ok () -> Ok ()
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )

  let set_mute t ~sw ~net ~clock ~track_index enabled =
    with_driver t ~sw ~net ~clock ~op_name:"mixer_set_mute" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.set_mute ~track_index enabled) with
      | Ok () -> Ok ()
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )

  let set_solo t ~sw ~net ~clock ~track_index enabled =
    with_driver t ~sw ~net ~clock ~op_name:"mixer_set_solo" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.set_solo ~track_index enabled) with
      | Ok () -> Ok ()
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )

  let get_channel t ~sw ~net ~clock ~track_index =
    with_driver t ~sw ~net ~clock ~op_name:"mixer_get_channel" (fun driver ->
      let module D = (val driver : DAW_DRIVER) in
      match Eio.Promise.await (D.get_mixer_channel ~track_index) with
      | Ok channel -> Ok channel
      | Error exn -> Error (`Command_failed (Printexc.to_string exn))
    )
end
