(** DAW MCP Integration Layer

    Unified initialization and connection management for all DAW drivers.
    This module ties together the driver registry, MCP server, and
    provides automatic DAW detection and reconnection.
*)

(** Connection error types *)
type connection_error = [
  | `Unknown_daw of Daw_driver.Driver.daw_id
  | `Not_running of Daw_driver.Driver.daw_id
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
  | Connected of (module Daw_driver.Driver.DAW_DRIVER)
  | Failed of string

(** Integration manager state *)
type t

(** Create new integration manager *)
val create : unit -> t

(** Register all available drivers *)
val register_all_drivers : unit -> unit

(** Get human-readable DAW name *)
val daw_name : Daw_driver.Driver.daw_id -> string

(** Detect all running DAWs *)
val detect_running_daws : unit -> Daw_driver.Driver.daw_id list

(** Connect to a specific DAW *)
val connect_to_daw : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t -> Daw_driver.Driver.daw_id ->
  ((module Daw_driver.Driver.DAW_DRIVER), connection_error) result

(** Auto-detect and connect to first available DAW *)
val auto_connect : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
  ((module Daw_driver.Driver.DAW_DRIVER), connection_error) result

(** Disconnect from current DAW *)
val disconnect : t -> unit

(** Attempt reconnection *)
val try_reconnect : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
  ((module Daw_driver.Driver.DAW_DRIVER), connection_error) result

(** Get current driver (if connected) *)
val get_driver : t -> (module Daw_driver.Driver.DAW_DRIVER) option

(** Check if connected *)
val is_connected : t -> bool

(** Get connection status as JSON-friendly record *)
val get_status : t -> string * string option * string option

(** Execute command with auto-reconnect *)
val with_driver : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
  ((module Daw_driver.Driver.DAW_DRIVER) -> ('a, connection_error) result) ->
  ('a, connection_error) result

(** Transport commands with error handling *)
module Transport : sig
  val play : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    ([ `Playing ], connection_error) result
  val stop : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    ([ `Stopped ], connection_error) result
  val record : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    ([ `Recording ], connection_error) result
  val get_state : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    (Daw_driver.Driver.transport_state, connection_error) result
end

(** Tempo commands *)
module Tempo : sig
  val get : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    (float, connection_error) result
  val set : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t -> float ->
    (float, connection_error) result
end

(** Track commands *)
module Tracks : sig
  val get_all : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    (Daw_driver.Driver.track list, connection_error) result
  val select : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t -> int ->
    (int, connection_error) result
  val get_selected : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    (int, connection_error) result
end

(** Mixer commands *)
module Mixer : sig
  val set_volume : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    track_index:int -> float -> (unit, connection_error) result
  val set_pan : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    track_index:int -> float -> (unit, connection_error) result
  val set_mute : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    track_index:int -> bool -> (unit, connection_error) result
  val set_solo : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    track_index:int -> bool -> (unit, connection_error) result
  val get_channel : t -> sw:Eio.Switch.t -> net:_ Eio.Net.t ->
    track_index:int -> (Daw_driver.Driver.mixer_channel, connection_error) result
end
