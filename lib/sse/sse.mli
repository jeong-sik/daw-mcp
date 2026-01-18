(** SSE (Server-Sent Events) - Real-time streaming interface *)

(** {1 Event Types} *)

type event_type =
  | Meter
  | Automation
  | Transport
  | Error
  | Ping

val event_type_to_string : event_type -> string

(** {1 Events} *)

type event = {
  event_type : event_type;
  data : Yojson.Safe.t;
  id : string option;
  retry : int option;
}

val create_event :
  event_type:event_type ->
  data:Yojson.Safe.t ->
  ?id:string ->
  ?retry:int ->
  unit -> event

val format_event : event -> string
(** Format an event as SSE text (event: ... \n data: ... \n\n) *)

(** {1 Stream Configuration} *)

type stream_config = {
  frame_rate : int;
  include_input : bool;
  track_indices : int list option;
}

val default_config : stream_config
val frame_interval : stream_config -> float
val config_of_json : Yojson.Safe.t -> stream_config

(** {1 Stream State} *)

type stream_state

val create_stream :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Time.clock ->
  ?config:stream_config ->
  unit -> stream_state

val start_stream : stream_state -> unit
val stop_stream : stream_state -> unit
val is_running : stream_state -> bool
val get_config : stream_state -> stream_config
val should_emit_frame : stream_state -> bool
val sleep_until_next_frame : stream_state -> unit

(** {1 Event Generators} *)

val meter_event_of_frame :
  state:stream_state -> Metering.meter_frame -> event

val ping_event : state:stream_state -> event
val error_event : state:stream_state -> message:string -> event

val transport_event :
  state:stream_state ->
  playing:bool ->
  recording:bool ->
  position:float -> event

val automation_event :
  state:stream_state ->
  track_index:int ->
  param_name:string ->
  points:Yojson.Safe.t list -> event

(** {1 Stream Generation} *)

val generate_meter_events :
  state:stream_state ->
  get_meter_frame:(unit -> Metering.meter_frame option) ->
  unit -> string Seq.t
(** Generate meter events as SSE-formatted strings *)

(** {1 HTTP Helpers} *)

val sse_headers : (string * string) list
(** HTTP headers for SSE response *)

val meter_stream_tool : string
(** MCP tool definition JSON *)
