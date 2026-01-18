(** DAW MCP Types - DAW-agnostic type definitions *)

(** Transport state *)
type transport_state =
  | Stopped
  | Playing
  | Recording
  | Paused
[@@deriving yojson]

(** Time position in various formats *)
type time_position = {
  bars : int;
  beats : int;
  ticks : int;
  seconds : float;
}
[@@deriving yojson]

(** Track type *)
type track_type =
  | Audio
  | Midi
  | Instrument
  | Aux
  | Master
  | Bus
  | Folder
[@@deriving yojson]

(** Track info *)
type track = {
  index : int;
  name : string;
  track_type : track_type;
  muted : bool;
  soloed : bool;
  armed : bool;
  volume : float;  (** 0.0 - 1.0 normalized *)
  pan : float;     (** -1.0 (L) to 1.0 (R) *)
}
[@@deriving yojson]

(** Mixer channel *)
type mixer_channel = {
  track_index : int;
  volume_db : float;
  pan : float;
  mute : bool;
  solo : bool;
  arm : bool;
  sends : (int * float) list;  (** (send_index, level) *)
}
[@@deriving yojson]

(** Plugin parameter *)
type plugin_param = {
  plugin_index : int;
  param_index : int;
  name : string;
  value : float;  (** normalized 0.0 - 1.0 *)
  display_value : string;
}
[@@deriving yojson]

(** Marker/Region *)
type marker = {
  id : int;
  name : string;
  position : time_position;
  is_region : bool;
  end_position : time_position option;
  color : int option;  (** RGB as int *)
}
[@@deriving yojson]

(** DAW capabilities - what features each DAW supports *)
type capabilities = {
  transport : bool;
  tracks : bool;
  mixer : bool;
  plugins : bool;
  markers : bool;
  routing : bool;
  render : bool;
  metering : bool;
  automation : bool;
}
[@@deriving yojson]

(** Supported DAW identifiers - alias to Daw_driver.Driver.daw_id *)
type daw_id = Daw_driver.Driver.daw_id =
  | Reaper
  | Ableton
  | LogicPro
  | MainStage
  | Cubase
  | ProTools
  | FLStudio
[@@deriving yojson]

(** DAW connection info *)
type daw_info = {
  daw_id : daw_id;
  name : string;
  version : string option;
  capabilities : capabilities;
}
[@@deriving yojson]

(** Automation mode *)
type automation_mode =
  | Off
  | Read
  | Write
  | Touch
  | Latch
[@@deriving yojson]

(** Automation curve type *)
type curve_type =
  | Linear
  | Bezier
  | Exponential
  | Logarithmic
  | Step
[@@deriving yojson]

(** Automation point *)
type automation_point = {
  time : float;       (** in seconds *)
  value : float;      (** normalized 0.0 - 1.0 *)
  curve : curve_type;
}
[@@deriving yojson]

(** Metering data *)
type meter_data = {
  track_index : int;
  input_rms_db : float;
  input_peak_db : float;
  output_rms_db : float;
  output_peak_db : float;
  timestamp : float;
}
[@@deriving yojson]

(** MCP Tool result *)
type 'a tool_result = {
  success : bool;
  data : 'a option;
  error : string option;
}
[@@deriving yojson]

(** Default capabilities - all disabled *)
let default_capabilities = {
  transport = false;
  tracks = false;
  mixer = false;
  plugins = false;
  markers = false;
  routing = false;
  render = false;
  metering = false;
  automation = false;
}

(** Full capabilities - all enabled *)
let full_capabilities = {
  transport = true;
  tracks = true;
  mixer = true;
  plugins = true;
  markers = true;
  routing = true;
  render = true;
  metering = true;
  automation = true;
}

(** DAW id to string *)
let daw_id_to_string = function
  | Reaper -> "Reaper"
  | Ableton -> "Ableton Live"
  | LogicPro -> "Logic Pro"
  | MainStage -> "MainStage"
  | Cubase -> "Cubase"
  | ProTools -> "Pro Tools"
  | FLStudio -> "FL Studio"

(** String to DAW id *)
let daw_id_of_string = function
  | "reaper" | "Reaper" -> Some Reaper
  | "ableton" | "Ableton" | "Ableton Live" -> Some Ableton
  | "logic" | "Logic" | "Logic Pro" | "LogicPro" -> Some LogicPro
  | "mainstage" | "MainStage" -> Some MainStage
  | "cubase" | "Cubase" -> Some Cubase
  | "protools" | "ProTools" | "Pro Tools" -> Some ProTools
  | "fl" | "FL" | "FL Studio" | "FLStudio" -> Some FLStudio
  | _ -> None
