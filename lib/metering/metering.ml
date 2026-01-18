(** Metering Engine - Pure OCaml DSP for real-time audio metering

    Provides RMS, Peak detection, and dB conversion for audio signals.
    Designed for integration with DAW plugin bridge.
*)

(** Minimum dB value (silence threshold) *)
let min_db = -96.0

(** Reference level for 0 dBFS *)
let db_reference = 1.0

(** Convert linear amplitude to decibels *)
let linear_to_db ?(reference = db_reference) amplitude =
  if amplitude <= 0.0 then min_db
  else
    let db = 20.0 *. Float.log10 (amplitude /. reference) in
    Float.max min_db db

(** Convert decibels to linear amplitude *)
let db_to_linear ?(reference = db_reference) db =
  if db <= min_db then 0.0
  else reference *. (10.0 ** (db /. 20.0))

(** Calculate RMS (Root Mean Square) of audio samples *)
let calculate_rms samples =
  let n = Array.length samples in
  if n = 0 then 0.0
  else
    let sum_squares = Array.fold_left (fun acc x -> acc +. (x *. x)) 0.0 samples in
    Float.sqrt (sum_squares /. Float.of_int n)

(** Calculate peak (maximum absolute value) of audio samples *)
let calculate_peak samples =
  Array.fold_left (fun acc x -> Float.max acc (Float.abs x)) 0.0 samples

(** Meter data for a single channel *)
type channel_meter = {
  rms_linear : float;
  peak_linear : float;
  rms_db : float;
  peak_db : float;
}

(** Calculate meter data for a channel *)
let meter_channel samples =
  let rms_linear = calculate_rms samples in
  let peak_linear = calculate_peak samples in
  {
    rms_linear;
    peak_linear;
    rms_db = linear_to_db rms_linear;
    peak_db = linear_to_db peak_linear;
  }

(** Stereo meter data *)
type stereo_meter = {
  left : channel_meter;
  right : channel_meter;
  mono_sum : channel_meter;  (** L+R summed to mono *)
}

(** Calculate stereo meter data from interleaved samples *)
let meter_stereo_interleaved samples =
  let n = Array.length samples in
  let half = n / 2 in
  let left = Array.init half (fun i -> samples.(i * 2)) in
  let right = Array.init half (fun i -> samples.(i * 2 + 1)) in
  let mono = Array.init half (fun i -> (samples.(i * 2) +. samples.(i * 2 + 1)) /. 2.0) in
  {
    left = meter_channel left;
    right = meter_channel right;
    mono_sum = meter_channel mono;
  }

(** Calculate stereo meter data from separate L/R arrays *)
let meter_stereo ~left ~right =
  let n = min (Array.length left) (Array.length right) in
  let mono = Array.init n (fun i -> (left.(i) +. right.(i)) /. 2.0) in
  {
    left = meter_channel left;
    right = meter_channel right;
    mono_sum = meter_channel mono;
  }

(** Peak hold state for smooth metering display *)
type peak_hold = {
  mutable current_peak : float;
  mutable hold_counter : int;
  hold_time : int;  (** frames to hold peak *)
  release_rate : float;  (** dB per frame to release *)
}

(** Create a new peak hold processor *)
let create_peak_hold ?(hold_time = 30) ?(release_rate = 0.5) () = {
  current_peak = min_db;
  hold_counter = 0;
  hold_time;
  release_rate;
}

(** Update peak hold with new value *)
let update_peak_hold ph new_peak_db =
  if new_peak_db > ph.current_peak then begin
    ph.current_peak <- new_peak_db;
    ph.hold_counter <- ph.hold_time
  end else if ph.hold_counter > 0 then
    ph.hold_counter <- ph.hold_counter - 1
  else
    ph.current_peak <- Float.max min_db (ph.current_peak -. ph.release_rate);
  ph.current_peak

(** Ballistics for smooth meter movement *)
type ballistics = {
  mutable current_value : float;
  attack_coeff : float;  (** 0.0-1.0, higher = faster attack *)
  release_coeff : float;  (** 0.0-1.0, higher = faster release *)
}

(** Create ballistics processor *)
let create_ballistics ?(attack_ms = 10.0) ?(release_ms = 300.0) ~sample_rate () =
  let attack_coeff = 1.0 -. Float.exp (-2.2 /. (attack_ms *. sample_rate /. 1000.0)) in
  let release_coeff = 1.0 -. Float.exp (-2.2 /. (release_ms *. sample_rate /. 1000.0)) in
  {
    current_value = min_db;
    attack_coeff;
    release_coeff;
  }

(** Update ballistics with new value *)
let update_ballistics b new_value_db =
  let coeff = if new_value_db > b.current_value then b.attack_coeff else b.release_coeff in
  b.current_value <- b.current_value +. coeff *. (new_value_db -. b.current_value);
  b.current_value

(** Full meter processor with ballistics and peak hold *)
type meter_processor = {
  rms_ballistics : ballistics;
  peak_ballistics : ballistics;
  peak_hold : peak_hold;
  mutable last_rms_db : float;
  mutable last_peak_db : float;
  mutable last_peak_hold_db : float;
}

(** Create a full meter processor *)
let create_processor ~sample_rate =
  {
    rms_ballistics = create_ballistics ~attack_ms:10.0 ~release_ms:300.0 ~sample_rate ();
    peak_ballistics = create_ballistics ~attack_ms:0.1 ~release_ms:500.0 ~sample_rate ();
    peak_hold = create_peak_hold ~hold_time:60 ~release_rate:0.3 ();
    last_rms_db = min_db;
    last_peak_db = min_db;
    last_peak_hold_db = min_db;
  }

(** Process a buffer and update meter values *)
let process_buffer mp samples =
  let meter = meter_channel samples in
  mp.last_rms_db <- update_ballistics mp.rms_ballistics meter.rms_db;
  mp.last_peak_db <- update_ballistics mp.peak_ballistics meter.peak_db;
  mp.last_peak_hold_db <- update_peak_hold mp.peak_hold meter.peak_db;
  {
    rms_linear = db_to_linear mp.last_rms_db;
    peak_linear = db_to_linear mp.last_peak_db;
    rms_db = mp.last_rms_db;
    peak_db = mp.last_peak_db;
  }

(** Stereo meter processor *)
type stereo_processor = {
  left : meter_processor;
  right : meter_processor;
}

(** Create stereo processor *)
let create_stereo_processor ~sample_rate = {
  left = create_processor ~sample_rate;
  right = create_processor ~sample_rate;
}

(** Process stereo buffer *)
let process_stereo_buffer sp ~left ~right =
  let left_meter = process_buffer sp.left left in
  let right_meter = process_buffer sp.right right in
  let mono = Array.init (min (Array.length left) (Array.length right))
    (fun i -> (left.(i) +. right.(i)) /. 2.0) in
  {
    left = left_meter;
    right = right_meter;
    mono_sum = meter_channel mono;
  }

(** Get current peak hold values *)
let get_peak_holds sp =
  (sp.left.last_peak_hold_db, sp.right.last_peak_hold_db)

(** Meter frame for streaming *)
type meter_frame = {
  timestamp : float;
  track_index : int;
  input : stereo_meter option;
  output : stereo_meter;
}

(** Create meter frame *)
let create_frame ~timestamp ~track_index ?input ~output () = {
  timestamp;
  track_index;
  input;
  output;
}

(** Convert meter frame to JSON *)
let frame_to_json frame =
  let channel_to_json (ch : channel_meter) =
    `Assoc [
      ("rms_db", `Float ch.rms_db);
      ("peak_db", `Float ch.peak_db);
    ]
  in
  let stereo_to_json (s : stereo_meter) =
    `Assoc [
      ("left", channel_to_json s.left);
      ("right", channel_to_json s.right);
    ]
  in
  `Assoc [
    ("timestamp", `Float frame.timestamp);
    ("track_index", `Int frame.track_index);
    ("input", match frame.input with Some i -> stereo_to_json i | None -> `Null);
    ("output", stereo_to_json frame.output);
  ]
