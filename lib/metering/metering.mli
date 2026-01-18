(** Metering Engine - Pure OCaml DSP for real-time audio metering *)

(** {1 Constants} *)

val min_db : float
(** Minimum dB value (silence threshold), typically -96.0 *)

val db_reference : float
(** Reference level for 0 dBFS *)

(** {1 dB Conversion} *)

val linear_to_db : ?reference:float -> float -> float
(** Convert linear amplitude to decibels *)

val db_to_linear : ?reference:float -> float -> float
(** Convert decibels to linear amplitude *)

(** {1 Basic Metering} *)

val calculate_rms : float array -> float
(** Calculate RMS (Root Mean Square) of audio samples *)

val calculate_peak : float array -> float
(** Calculate peak (maximum absolute value) of audio samples *)

(** {1 Meter Types} *)

type channel_meter = {
  rms_linear : float;
  peak_linear : float;
  rms_db : float;
  peak_db : float;
}
(** Meter data for a single channel *)

type stereo_meter = {
  left : channel_meter;
  right : channel_meter;
  mono_sum : channel_meter;
}
(** Stereo meter data *)

val meter_channel : float array -> channel_meter
(** Calculate meter data for a channel *)

val meter_stereo_interleaved : float array -> stereo_meter
(** Calculate stereo meter data from interleaved samples *)

val meter_stereo : left:float array -> right:float array -> stereo_meter
(** Calculate stereo meter data from separate L/R arrays *)

(** {1 Peak Hold} *)

type peak_hold
(** Peak hold state for smooth metering display *)

val create_peak_hold : ?hold_time:int -> ?release_rate:float -> unit -> peak_hold
(** Create a new peak hold processor *)

val update_peak_hold : peak_hold -> float -> float
(** Update peak hold with new value (in dB), returns current peak hold value *)

(** {1 Ballistics} *)

type ballistics
(** Ballistics for smooth meter movement *)

val create_ballistics : ?attack_ms:float -> ?release_ms:float -> sample_rate:float -> unit -> ballistics
(** Create ballistics processor *)

val update_ballistics : ballistics -> float -> float
(** Update ballistics with new value (in dB), returns smoothed value *)

(** {1 Full Meter Processor} *)

type meter_processor
(** Full meter processor with ballistics and peak hold *)

val create_processor : sample_rate:float -> meter_processor
(** Create a full meter processor *)

val process_buffer : meter_processor -> float array -> channel_meter
(** Process a buffer and update meter values *)

(** {1 Stereo Processor} *)

type stereo_processor = {
  left : meter_processor;
  right : meter_processor;
}
(** Stereo meter processor *)

val create_stereo_processor : sample_rate:float -> stereo_processor
(** Create stereo processor *)

val process_stereo_buffer : stereo_processor -> left:float array -> right:float array -> stereo_meter
(** Process stereo buffer *)

val get_peak_holds : stereo_processor -> float * float
(** Get current peak hold values (left, right) in dB *)

(** {1 Streaming} *)

type meter_frame = {
  timestamp : float;
  track_index : int;
  input : stereo_meter option;
  output : stereo_meter;
}
(** Meter frame for streaming *)

val create_frame : timestamp:float -> track_index:int -> ?input:stereo_meter -> output:stereo_meter -> unit -> meter_frame
(** Create meter frame *)

val frame_to_json : meter_frame -> Yojson.Safe.t
(** Convert meter frame to JSON *)
