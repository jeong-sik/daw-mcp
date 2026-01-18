(** Automation API - Read/Write automation data for DAW tracks *)

(** {1 Automation Mode} *)

type mode =
  | Off
  | Read
  | Write
  | Touch
  | Latch

val mode_to_string : mode -> string
val mode_of_string : string -> mode option

(** {1 Curve Types} *)

type curve_type =
  | Linear
  | Bezier
  | Exponential
  | Logarithmic
  | Step

val curve_type_to_string : curve_type -> string
val curve_type_of_string : string -> curve_type option

(** {1 Automation Points} *)

type point = {
  time : float;
  value : float;
  curve : curve_type;
}

val create_point : ?curve:curve_type -> time:float -> value:float -> unit -> point
val point_to_json : point -> Yojson.Safe.t
val point_of_json : Yojson.Safe.t -> point

(** {1 Automation Lane} *)

type lane = {
  track_index : int;
  param_name : string;
  points : point list;
  mode : mode;
}

val create_lane :
  track_index:int ->
  param_name:string ->
  ?mode:mode ->
  ?points:point list ->
  unit -> lane

val lane_to_json : lane -> Yojson.Safe.t
val lane_of_json : Yojson.Safe.t -> lane

(** {1 Interpolation} *)

val interpolate_at : points:point list -> time:float -> float option
(** Get interpolated value at a specific time *)

(** {1 Lane Operations} *)

val add_point : lane -> point -> lane
(** Add or update a point in a lane *)

val remove_points_in_range : lane -> start_time:float -> end_time:float -> lane
(** Remove all points in the given time range *)

val get_points_in_range : lane -> start_time:float -> end_time:float -> point list
(** Get points within a time range *)

(** {1 Write Operations} *)

type write_operation = {
  lane : lane;
  new_points : point list;
  replace_range : (float * float) option;
}

val apply_write_operation : write_operation -> lane
val parse_write_request : Yojson.Safe.t -> write_operation

(** {1 MCP Tool Definitions} *)

val automation_read_tool : string
val automation_write_tool : string
val automation_mode_tool : string

(** {1 Parameter Info} *)

type param_info = {
  name : string;
  display_name : string;
  min_value : float;
  max_value : float;
  default_value : float;
  unit : string;
}

val volume_param : param_info
val pan_param : param_info
val mute_param : param_info

val normalized_to_display : param:param_info -> float -> float
val display_to_normalized : param:param_info -> float -> float
