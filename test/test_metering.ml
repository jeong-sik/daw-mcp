(** Metering Engine Tests - DSP and dB conversion *)

open Metering

(** Float comparison with tolerance *)
let float_eq ?(eps = 0.001) a b = Float.abs (a -. b) < eps

(** Custom testable for floats with tolerance *)
let float_approx = Alcotest.testable
  (fun ppf f -> Format.fprintf ppf "%f" f)
  (float_eq ~eps:0.01)

(** {1 dB Conversion Tests} *)

let test_linear_to_db_unity () =
  (* 1.0 linear = 0 dB *)
  let db = linear_to_db 1.0 in
  Alcotest.(check float_approx) "unity = 0dB" 0.0 db

let test_linear_to_db_half () =
  (* 0.5 linear ≈ -6.02 dB *)
  let db = linear_to_db 0.5 in
  Alcotest.(check bool) "half ≈ -6dB" true (float_eq ~eps:0.1 db (-6.02))

let test_linear_to_db_zero () =
  (* 0 or negative linear = min_db *)
  let db_zero = linear_to_db 0.0 in
  let db_neg = linear_to_db (-0.5) in
  Alcotest.(check float_approx) "zero = min_db" min_db db_zero;
  Alcotest.(check float_approx) "negative = min_db" min_db db_neg

let test_db_to_linear_zero () =
  (* 0 dB = 1.0 linear *)
  let lin = db_to_linear 0.0 in
  Alcotest.(check float_approx) "0dB = unity" 1.0 lin

let test_db_to_linear_minus6 () =
  (* -6 dB ≈ 0.5 linear *)
  let lin = db_to_linear (-6.0) in
  Alcotest.(check bool) "-6dB ≈ 0.5" true (float_eq ~eps:0.05 lin 0.5)

let test_db_to_linear_min () =
  (* min_db or below = 0 linear *)
  let lin_min = db_to_linear min_db in
  let lin_below = db_to_linear (min_db -. 10.0) in
  Alcotest.(check float_approx) "min_db = 0" 0.0 lin_min;
  Alcotest.(check float_approx) "below min = 0" 0.0 lin_below

let test_db_roundtrip () =
  (* linear -> dB -> linear should be identity *)
  let original = 0.7 in
  let result = db_to_linear (linear_to_db original) in
  Alcotest.(check bool) "roundtrip" true (float_eq original result)

(** {1 RMS Tests} *)

let test_rms_silence () =
  let samples = Array.make 100 0.0 in
  let rms = calculate_rms samples in
  Alcotest.(check float_approx) "silence RMS = 0" 0.0 rms

let test_rms_dc () =
  (* DC signal: RMS = absolute value *)
  let samples = Array.make 100 0.5 in
  let rms = calculate_rms samples in
  Alcotest.(check float_approx) "DC RMS = value" 0.5 rms

let test_rms_sine () =
  (* Pure sine wave: RMS = amplitude / sqrt(2) ≈ 0.707 *)
  let n = 1000 in
  let samples = Array.init n (fun i ->
    Float.sin (2.0 *. Float.pi *. Float.of_int i /. Float.of_int n)
  ) in
  let rms = calculate_rms samples in
  let expected = 1.0 /. Float.sqrt 2.0 in
  Alcotest.(check bool) "sine RMS ≈ 0.707" true (float_eq ~eps:0.01 rms expected)

let test_rms_empty () =
  let samples = [||] in
  let rms = calculate_rms samples in
  Alcotest.(check float_approx) "empty RMS = 0" 0.0 rms

(** {1 Peak Tests} *)

let test_peak_silence () =
  let samples = Array.make 100 0.0 in
  let peak = calculate_peak samples in
  Alcotest.(check float_approx) "silence peak = 0" 0.0 peak

let test_peak_positive () =
  let samples = [| 0.1; 0.5; 0.3; 0.8; 0.2 |] in
  let peak = calculate_peak samples in
  Alcotest.(check float_approx) "positive peak = 0.8" 0.8 peak

let test_peak_negative () =
  (* Peak should be absolute value *)
  let samples = [| 0.1; -0.9; 0.3; 0.5 |] in
  let peak = calculate_peak samples in
  Alcotest.(check float_approx) "negative peak = 0.9" 0.9 peak

let test_peak_empty () =
  let samples = [||] in
  let peak = calculate_peak samples in
  Alcotest.(check float_approx) "empty peak = 0" 0.0 peak

(** {1 Channel Meter Tests} *)

let test_meter_channel () =
  let samples = Array.init 100 (fun i ->
    0.5 *. Float.sin (2.0 *. Float.pi *. Float.of_int i /. 100.0)
  ) in
  let meter = meter_channel samples in
  Alcotest.(check bool) "rms_linear > 0" true (meter.rms_linear > 0.0);
  Alcotest.(check bool) "peak_linear > 0" true (meter.peak_linear > 0.0);
  Alcotest.(check bool) "rms_db < 0" true (meter.rms_db < 0.0);
  Alcotest.(check bool) "peak_db < 0" true (meter.peak_db < 0.0);
  Alcotest.(check bool) "peak >= rms" true (meter.peak_linear >= meter.rms_linear)

(** {1 Stereo Meter Tests} *)

let test_meter_stereo_interleaved () =
  (* L R L R L R ... interleaved *)
  let n = 200 in  (* 100 samples per channel *)
  let samples = Array.init n (fun i ->
    if i mod 2 = 0 then 0.5  (* Left = 0.5 DC *)
    else 0.25  (* Right = 0.25 DC *)
  ) in
  let meter = meter_stereo_interleaved samples in
  Alcotest.(check bool) "left RMS ≈ 0.5" true (float_eq ~eps:0.01 meter.left.rms_linear 0.5);
  Alcotest.(check bool) "right RMS ≈ 0.25" true (float_eq ~eps:0.01 meter.right.rms_linear 0.25);
  Alcotest.(check bool) "mono ≈ 0.375" true (float_eq ~eps:0.01 meter.mono_sum.rms_linear 0.375)

let test_meter_stereo_separate () =
  let left = Array.make 100 0.8 in
  let right = Array.make 100 0.4 in
  let meter = meter_stereo ~left ~right in
  Alcotest.(check float_approx) "left RMS = 0.8" 0.8 meter.left.rms_linear;
  Alcotest.(check float_approx) "right RMS = 0.4" 0.4 meter.right.rms_linear;
  Alcotest.(check float_approx) "mono = 0.6" 0.6 meter.mono_sum.rms_linear

(** {1 Peak Hold Tests} *)

let test_peak_hold_attack () =
  let ph = create_peak_hold ~hold_time:10 ~release_rate:1.0 () in
  let v1 = update_peak_hold ph (-20.0) in
  let v2 = update_peak_hold ph (-10.0) in  (* New peak, higher *)
  Alcotest.(check float_approx) "first value" (-20.0) v1;
  Alcotest.(check float_approx) "new peak captured" (-10.0) v2

let test_peak_hold_hold () =
  let ph = create_peak_hold ~hold_time:5 ~release_rate:1.0 () in
  let _ = update_peak_hold ph (-10.0) in
  (* Should hold for 5 frames *)
  let v2 = update_peak_hold ph (-20.0) in
  let v3 = update_peak_hold ph (-20.0) in
  Alcotest.(check float_approx) "hold 1" (-10.0) v2;
  Alcotest.(check float_approx) "hold 2" (-10.0) v3

let test_peak_hold_release () =
  let ph = create_peak_hold ~hold_time:1 ~release_rate:2.0 () in
  let _ = update_peak_hold ph (-10.0) in
  let _ = update_peak_hold ph (-30.0) in  (* Start hold *)
  let v3 = update_peak_hold ph (-30.0) in  (* Hold expired, release *)
  Alcotest.(check float_approx) "released" (-12.0) v3  (* -10 - 2 = -12 *)

(** {1 Ballistics Tests} *)

let test_ballistics_attack () =
  (* Use slower attack to see gradual approach *)
  let b = create_ballistics ~attack_ms:100.0 ~release_ms:1000.0 ~sample_rate:44100.0 () in
  (* First update from min_db toward 0 dB *)
  let v1 = update_ballistics b 0.0 in
  let v2 = update_ballistics b 0.0 in
  (* Value should increase (attack toward 0 dB) *)
  Alcotest.(check bool) "v1 > min_db" true (v1 > min_db);
  Alcotest.(check bool) "v2 > v1 (attacking)" true (v2 > v1);
  (* But not yet at target *)
  Alcotest.(check bool) "v2 < 0" true (v2 < 0.0)

let test_ballistics_smooth () =
  (* Use fast attack for quick convergence test *)
  let b = create_ballistics ~attack_ms:1.0 ~release_ms:100.0 ~sample_rate:44100.0 () in
  (* Run many iterations to approach target *)
  for _ = 1 to 1000 do
    ignore (update_ballistics b (-20.0))
  done;
  let final = update_ballistics b (-20.0) in
  (* After 1000 iterations with fast attack, should be very close to -20 *)
  Alcotest.(check bool) "close to target" true (Float.abs (final -. (-20.0)) < 1.0)

(** {1 Processor Tests} *)

let test_processor_create () =
  let mp = create_processor ~sample_rate:44100.0 in
  (* Just verify it doesn't crash *)
  let samples = Array.make 512 0.0 in
  let meter = process_buffer mp samples in
  Alcotest.(check float_approx) "silence RMS" min_db meter.rms_db

let test_stereo_processor () =
  let sp = create_stereo_processor ~sample_rate:44100.0 in
  let left = Array.init 512 (fun i -> 0.5 *. Float.sin (Float.of_int i *. 0.1)) in
  let right = Array.init 512 (fun i -> 0.3 *. Float.sin (Float.of_int i *. 0.1)) in
  let meter = process_stereo_buffer sp ~left ~right in
  Alcotest.(check bool) "left > right" true (meter.left.rms_linear > meter.right.rms_linear);
  let (lph, rph) = get_peak_holds sp in
  Alcotest.(check bool) "left peak hold exists" true (lph > min_db);
  Alcotest.(check bool) "right peak hold exists" true (rph > min_db)

(** {1 Frame Tests} *)

let test_frame_to_json () =
  let output = {
    left = { rms_linear = 0.5; peak_linear = 0.8; rms_db = -6.0; peak_db = -2.0 };
    right = { rms_linear = 0.4; peak_linear = 0.7; rms_db = -8.0; peak_db = -3.0 };
    mono_sum = { rms_linear = 0.45; peak_linear = 0.75; rms_db = -7.0; peak_db = -2.5 };
  } in
  let frame = create_frame ~timestamp:1.0 ~track_index:0 ~output () in
  let json = frame_to_json frame in
  let open Yojson.Safe.Util in
  let ts = json |> member "timestamp" |> to_float in
  let idx = json |> member "track_index" |> to_int in
  Alcotest.(check float_approx) "timestamp" 1.0 ts;
  Alcotest.(check int) "track_index" 0 idx;
  let left_rms = json |> member "output" |> member "left" |> member "rms_db" |> to_float in
  Alcotest.(check float_approx) "left rms_db" (-6.0) left_rms

let test_frame_with_input () =
  let input = {
    left = { rms_linear = 0.3; peak_linear = 0.5; rms_db = -10.0; peak_db = -6.0 };
    right = { rms_linear = 0.3; peak_linear = 0.5; rms_db = -10.0; peak_db = -6.0 };
    mono_sum = { rms_linear = 0.3; peak_linear = 0.5; rms_db = -10.0; peak_db = -6.0 };
  } in
  let output = input in
  let frame = create_frame ~timestamp:2.0 ~track_index:1 ~input ~output () in
  let json = frame_to_json frame in
  let open Yojson.Safe.Util in
  let input_json = json |> member "input" in
  Alcotest.(check bool) "has input" true (input_json <> `Null)

(** All tests *)
let () =
  Alcotest.run "Metering" [
    "dB conversion", [
      Alcotest.test_case "linear_to_db unity" `Quick test_linear_to_db_unity;
      Alcotest.test_case "linear_to_db half" `Quick test_linear_to_db_half;
      Alcotest.test_case "linear_to_db zero" `Quick test_linear_to_db_zero;
      Alcotest.test_case "db_to_linear zero" `Quick test_db_to_linear_zero;
      Alcotest.test_case "db_to_linear -6" `Quick test_db_to_linear_minus6;
      Alcotest.test_case "db_to_linear min" `Quick test_db_to_linear_min;
      Alcotest.test_case "roundtrip" `Quick test_db_roundtrip;
    ];
    "RMS", [
      Alcotest.test_case "silence" `Quick test_rms_silence;
      Alcotest.test_case "DC" `Quick test_rms_dc;
      Alcotest.test_case "sine" `Quick test_rms_sine;
      Alcotest.test_case "empty" `Quick test_rms_empty;
    ];
    "Peak", [
      Alcotest.test_case "silence" `Quick test_peak_silence;
      Alcotest.test_case "positive" `Quick test_peak_positive;
      Alcotest.test_case "negative" `Quick test_peak_negative;
      Alcotest.test_case "empty" `Quick test_peak_empty;
    ];
    "channel meter", [
      Alcotest.test_case "meter_channel" `Quick test_meter_channel;
    ];
    "stereo meter", [
      Alcotest.test_case "interleaved" `Quick test_meter_stereo_interleaved;
      Alcotest.test_case "separate" `Quick test_meter_stereo_separate;
    ];
    "peak hold", [
      Alcotest.test_case "attack" `Quick test_peak_hold_attack;
      Alcotest.test_case "hold" `Quick test_peak_hold_hold;
      Alcotest.test_case "release" `Quick test_peak_hold_release;
    ];
    "ballistics", [
      Alcotest.test_case "attack" `Quick test_ballistics_attack;
      Alcotest.test_case "smooth" `Quick test_ballistics_smooth;
    ];
    "processor", [
      Alcotest.test_case "create" `Quick test_processor_create;
      Alcotest.test_case "stereo" `Quick test_stereo_processor;
    ];
    "frame", [
      Alcotest.test_case "to_json" `Quick test_frame_to_json;
      Alcotest.test_case "with_input" `Quick test_frame_with_input;
    ];
  ]
