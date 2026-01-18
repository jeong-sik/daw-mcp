(** DAW Bridge - Pure OCaml Plugin Logic *)

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
  position : float;  (** Position in seconds *)
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
  | Rendering of float  (** Progress 0.0-1.0 *)
  | Completed of string (** Output file path *)
  | Failed of string    (** Error message *)

(** {1 Plugin State} *)

type t = {
  mutable sample_rate : float;
  mutable block_size : int;
  mutable is_active : bool;
  mutable is_processing : bool;
  mutable peak_l : float;
  mutable peak_r : float;
  mutable rms_l : float;
  mutable rms_r : float;
  mutable socket_fd : Unix.file_descr option;
  mutable connected : bool;
  mutable params : param_info list;
  mutable markers : marker list;
  mutable regions : region list;
  mutable routing : routing option;
  mutable render_status : render_status;
}

(** {1 Core Functions} *)

val create : unit -> t
val init : unit -> t
val destroy : t -> unit
val activate : t -> float -> int -> unit
val deactivate : t -> unit
val start_processing : t -> unit
val stop_processing : t -> unit
val process : t -> unit

(** {1 DSP Utilities} *)

val calculate_rms : float array -> float
val calculate_peak : float array -> float
val linear_to_db : float -> float

(** {1 Parameter Management} *)

val get_param : t -> int -> float
val set_param : t -> int -> float -> unit
val get_param_info : t -> int -> param_info option
val list_params : t -> int -> param_info list
val register_param : t -> param_info -> unit

(** {1 Marker Management} *)

val get_markers : t -> marker list
val add_marker : t -> name:string -> position:float -> ?color:int -> unit -> marker
val remove_marker : t -> int -> bool
val get_regions : t -> region list
val add_region : t -> name:string -> start_pos:float -> end_pos:float -> ?color:int -> unit -> region
val remove_region : t -> int -> bool

(** {1 Routing} *)

val get_routing : t -> int -> routing option
val add_send : t -> track_index:int -> dest_track:int -> level:float -> send
val remove_send : t -> track_index:int -> send_id:int -> bool
val set_send_level : t -> track_index:int -> send_id:int -> float -> bool

(** {1 Render/Bounce} *)

val start_render : t -> render_settings -> bool
val get_render_status : t -> render_status
val cancel_render : t -> unit
val format_to_string : render_format -> string
val format_of_string : string -> render_format option

(** {1 IPC} *)

val connect_to_server : t -> bool
val disconnect_from_server : t -> unit
val read_response : t -> string option

(** {1 Transport} *)

val play : t -> unit
val stop : t -> unit
val record : t -> unit

(** {1 JSON Serialization} *)

val param_to_json : param_info -> Yojson.Safe.t
val marker_to_json : marker -> Yojson.Safe.t
val region_to_json : region -> Yojson.Safe.t
val send_to_json : send -> Yojson.Safe.t
val routing_to_json : routing -> Yojson.Safe.t
val render_status_to_json : render_status -> Yojson.Safe.t
