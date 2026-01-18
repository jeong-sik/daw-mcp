(** DAW Bridge Plugin Tests - OCaml plugin logic *)

open Daw_bridge.Bridge

(** Test plugin creation *)
let test_create () =
  let plugin = create () in
  Alcotest.(check bool) "not active" false plugin.is_active;
  Alcotest.(check bool) "not processing" false plugin.is_processing;
  Alcotest.(check (float 0.1)) "default sample rate" 44100.0 plugin.sample_rate;
  Alcotest.(check int) "default block size" 512 plugin.block_size

(** Test plugin activation *)
let test_activate () =
  let plugin = create () in
  activate plugin 48000.0 1024;
  Alcotest.(check bool) "is active" true plugin.is_active;
  Alcotest.(check (float 0.1)) "sample rate updated" 48000.0 plugin.sample_rate;
  Alcotest.(check int) "block size updated" 1024 plugin.block_size

(** Test plugin deactivation *)
let test_deactivate () =
  let plugin = create () in
  activate plugin 48000.0 1024;
  Alcotest.(check bool) "is active" true plugin.is_active;
  deactivate plugin;
  Alcotest.(check bool) "is not active" false plugin.is_active

(** Test start/stop processing *)
let test_processing () =
  let plugin = create () in
  activate plugin 44100.0 512;
  start_processing plugin;
  Alcotest.(check bool) "is processing" true plugin.is_processing;
  stop_processing plugin;
  Alcotest.(check bool) "not processing" false plugin.is_processing

(** Test linear to dB conversion *)
let test_linear_to_db () =
  (* 1.0 linear = 0 dB *)
  Alcotest.(check (float 0.01)) "unity gain" 0.0 (linear_to_db 1.0);

  (* 0.5 linear ≈ -6 dB *)
  let db_half = linear_to_db 0.5 in
  Alcotest.(check bool) "half amplitude ~-6dB" true (db_half > -6.1 && db_half < -6.0);

  (* 0.1 linear = -20 dB *)
  Alcotest.(check (float 0.01)) "0.1 amplitude" (-20.0) (linear_to_db 0.1);

  (* 0 or negative → -100 dB (floor) *)
  Alcotest.(check (float 0.01)) "zero amplitude" (-100.0) (linear_to_db 0.0);
  Alcotest.(check (float 0.01)) "negative amplitude" (-100.0) (linear_to_db (-0.5))

(** Test RMS calculation *)
let test_calculate_rms () =
  (* Empty array *)
  Alcotest.(check (float 0.001)) "empty rms" 0.0 (calculate_rms [||]);

  (* DC signal *)
  let dc = Array.make 100 0.5 in
  Alcotest.(check (float 0.001)) "dc rms" 0.5 (calculate_rms dc);

  (* Sine wave peak 1.0 → RMS ≈ 0.707 *)
  let sine = Array.init 1000 (fun i ->
    sin (2.0 *. Float.pi *. float_of_int i /. 100.0)
  ) in
  let rms = calculate_rms sine in
  Alcotest.(check bool) "sine rms ~0.707" true (rms > 0.70 && rms < 0.71)

(** Test peak calculation *)
let test_calculate_peak () =
  (* Empty array *)
  Alcotest.(check (float 0.001)) "empty peak" 0.0 (calculate_peak [||]);

  (* Constant signal *)
  let const = Array.make 100 0.3 in
  Alcotest.(check (float 0.001)) "const peak" 0.3 (calculate_peak const);

  (* Mixed positive/negative *)
  let mixed = [| 0.1; -0.5; 0.3; -0.8; 0.2 |] in
  Alcotest.(check (float 0.001)) "mixed peak" 0.8 (calculate_peak mixed);

  (* Sine wave *)
  let sine = Array.init 1000 (fun i ->
    sin (2.0 *. Float.pi *. float_of_int i /. 100.0)
  ) in
  let peak = calculate_peak sine in
  Alcotest.(check bool) "sine peak ~1.0" true (peak > 0.99 && peak <= 1.0)

(** Test meter values initialization *)
let test_meter_init () =
  let plugin = create () in
  Alcotest.(check (float 0.001)) "peak_l init" 0.0 plugin.peak_l;
  Alcotest.(check (float 0.001)) "peak_r init" 0.0 plugin.peak_r;
  Alcotest.(check (float 0.001)) "rms_l init" 0.0 plugin.rms_l;
  Alcotest.(check (float 0.001)) "rms_r init" 0.0 plugin.rms_r

(** Test parameter get/set *)
let test_params () =
  let plugin = create () in
  (* Default param value *)
  let value = get_param plugin 0 in
  Alcotest.(check (float 0.001)) "default param" 0.0 value;
  (* Set param (placeholder - just verify no crash) *)
  set_param plugin 0 0.5

(** Test process without connection (should not crash) *)
let test_process_disconnected () =
  let plugin = create () in
  activate plugin 44100.0 512;
  start_processing plugin;
  (* Process should handle disconnected state gracefully *)
  process plugin;
  Alcotest.(check bool) "still processing" true plugin.is_processing

(** Test full lifecycle *)
let test_lifecycle () =
  let plugin = init () in
  Alcotest.(check bool) "created" true (plugin.sample_rate > 0.0);

  activate plugin 96000.0 256;
  Alcotest.(check bool) "activated" true plugin.is_active;

  start_processing plugin;
  process plugin;
  process plugin;
  stop_processing plugin;

  deactivate plugin;
  Alcotest.(check bool) "deactivated" false plugin.is_active;

  destroy plugin
  (* Plugin destroyed - no more assertions *)

(** All tests *)
let () =
  Alcotest.run "DAW Bridge" [
    "creation", [
      Alcotest.test_case "create plugin" `Quick test_create;
      Alcotest.test_case "meter init" `Quick test_meter_init;
    ];
    "lifecycle", [
      Alcotest.test_case "activate" `Quick test_activate;
      Alcotest.test_case "deactivate" `Quick test_deactivate;
      Alcotest.test_case "processing" `Quick test_processing;
      Alcotest.test_case "full lifecycle" `Quick test_lifecycle;
    ];
    "dsp", [
      Alcotest.test_case "linear to dB" `Quick test_linear_to_db;
      Alcotest.test_case "calculate RMS" `Quick test_calculate_rms;
      Alcotest.test_case "calculate peak" `Quick test_calculate_peak;
    ];
    "params", [
      Alcotest.test_case "get/set params" `Quick test_params;
    ];
    "process", [
      Alcotest.test_case "process disconnected" `Quick test_process_disconnected;
    ];
  ]
