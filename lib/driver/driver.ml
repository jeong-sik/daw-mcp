(** DAW Driver Registry Implementation *)

(* Forward reference to types - will be replaced when modules are linked *)
type daw_id = Reaper | Ableton | LogicPro | MainStage | Cubase | ProTools | FLStudio
type transport_state = Stopped | Playing | Recording | Paused
type time_position = { bars: int; beats: int; ticks: int; seconds: float }
type track_type = Audio | Midi | Instrument | Aux | Master | Bus | Folder
type track = {
  index: int; name: string; track_type: track_type; muted: bool;
  soloed: bool; armed: bool; volume: float; pan: float;
}
type mixer_channel = {
  track_index: int; volume_db: float; pan: float; mute: bool;
  solo: bool; arm: bool; sends: (int * float) list;
}
type plugin_param = {
  plugin_index: int; param_index: int; name: string;
  value: float; display_value: string;
}
type marker = {
  id: int; name: string; position: time_position; is_region: bool;
  end_position: time_position option; color: int option;
}
type daw_info = {
  daw_id: daw_id; name: string; version: string option;
  capabilities: unit;  (* simplified *)
}
type meter_data = {
  track_index: int; input_rms_db: float; input_peak_db: float;
  output_rms_db: float; output_peak_db: float; timestamp: float;
}
type automation_mode = Off | Read | Write | Touch | Latch
type automation_point = { time: float; value: float; curve: unit }

module type DAW_DRIVER = sig
  val name : string
  val get_info : unit -> daw_info Eio.Promise.or_exn
  val connect : sw:Eio.Switch.t -> net:_ Eio.Net.t -> unit -> bool Eio.Promise.or_exn
  val disconnect : unit -> unit
  val is_connected : unit -> bool
  val play : unit -> unit Eio.Promise.or_exn
  val stop : unit -> unit Eio.Promise.or_exn
  val record : unit -> unit Eio.Promise.or_exn
  val pause : unit -> unit Eio.Promise.or_exn
  val get_transport_state : unit -> transport_state Eio.Promise.or_exn
  val set_position : float -> unit Eio.Promise.or_exn
  val get_position : unit -> time_position Eio.Promise.or_exn
  val set_tempo : float -> unit Eio.Promise.or_exn
  val get_tempo : unit -> float Eio.Promise.or_exn
  val get_tracks : unit -> track list Eio.Promise.or_exn
  val select_track : int -> unit Eio.Promise.or_exn
  val get_selected_track : unit -> int Eio.Promise.or_exn
  val set_volume : track_index:int -> float -> unit Eio.Promise.or_exn
  val set_pan : track_index:int -> float -> unit Eio.Promise.or_exn
  val set_mute : track_index:int -> bool -> unit Eio.Promise.or_exn
  val set_solo : track_index:int -> bool -> unit Eio.Promise.or_exn
  val set_arm : track_index:int -> bool -> unit Eio.Promise.or_exn
  val get_mixer_channel : track_index:int -> mixer_channel Eio.Promise.or_exn
  val get_plugin_param : track_index:int -> plugin_index:int -> param_index:int ->
    plugin_param Eio.Promise.or_exn
  val set_plugin_param : track_index:int -> plugin_index:int -> param_index:int ->
    float -> unit Eio.Promise.or_exn
  val get_markers : unit -> marker list Eio.Promise.or_exn
  val add_marker : string -> marker Eio.Promise.or_exn
  val goto_marker : int -> unit Eio.Promise.or_exn
  val get_meter : track_index:int -> meter_data Eio.Promise.or_exn
  val read_automation : track_index:int -> param_name:string ->
    start_time:float -> end_time:float -> automation_point list Eio.Promise.or_exn
  val write_automation : track_index:int -> param_name:string ->
    automation_point list -> unit Eio.Promise.or_exn
  val set_automation_mode : track_index:int -> automation_mode -> unit Eio.Promise.or_exn
end

type driver_entry = {
  daw_id : daw_id;
  create : unit -> (module DAW_DRIVER);
  detect : unit -> bool;
}

(* Driver registry *)
let registry : driver_entry list ref = ref []

let register entry =
  registry := entry :: !registry

let get_all () = !registry

let find_by_id daw_id =
  List.find_opt (fun e -> e.daw_id = daw_id) !registry

let auto_detect () =
  match List.find_opt (fun e -> e.detect ()) !registry with
  | Some entry -> Some (entry.create ())
  | None -> None
