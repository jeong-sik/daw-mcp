(** Automation API Tests *)

open Automation

(** Float comparison with tolerance *)
let float_eq ?(eps = 0.001) a b = Float.abs (a -. b) < eps

let float_approx = Alcotest.testable
  (fun ppf f -> Format.fprintf ppf "%f" f)
  (float_eq ~eps:0.01)

(** {1 Mode Tests} *)

let test_mode_to_string () =
  Alcotest.(check string) "off" "off" (mode_to_string Off);
  Alcotest.(check string) "read" "read" (mode_to_string Read);
  Alcotest.(check string) "write" "write" (mode_to_string Write);
  Alcotest.(check string) "touch" "touch" (mode_to_string Touch);
  Alcotest.(check string) "latch" "latch" (mode_to_string Latch)

let test_mode_of_string () =
  Alcotest.(check bool) "off" true (mode_of_string "off" = Some Off);
  Alcotest.(check bool) "read" true (mode_of_string "read" = Some Read);
  Alcotest.(check bool) "write" true (mode_of_string "write" = Some Write);
  Alcotest.(check bool) "touch" true (mode_of_string "touch" = Some Touch);
  Alcotest.(check bool) "latch" true (mode_of_string "latch" = Some Latch);
  Alcotest.(check bool) "unknown" true (mode_of_string "unknown" = None)

(** {1 Curve Type Tests} *)

let test_curve_type_roundtrip () =
  let curves = [Linear; Bezier; Exponential; Logarithmic; Step] in
  List.iter (fun c ->
    let s = curve_type_to_string c in
    let c' = curve_type_of_string s in
    Alcotest.(check bool) (Printf.sprintf "roundtrip %s" s) true (c' = Some c)
  ) curves

(** {1 Point Tests} *)

let test_create_point () =
  let p = create_point ~time:1.5 ~value:0.7 () in
  Alcotest.(check float_approx) "time" 1.5 p.time;
  Alcotest.(check float_approx) "value" 0.7 p.value;
  Alcotest.(check bool) "default curve" true (p.curve = Linear)

let test_create_point_with_curve () =
  let p = create_point ~time:2.0 ~value:0.5 ~curve:Bezier () in
  Alcotest.(check bool) "bezier curve" true (p.curve = Bezier)

let test_point_json_roundtrip () =
  let p = create_point ~time:3.0 ~value:0.8 ~curve:Exponential () in
  let json = point_to_json p in
  let p' = point_of_json json in
  Alcotest.(check float_approx) "time" p.time p'.time;
  Alcotest.(check float_approx) "value" p.value p'.value;
  Alcotest.(check bool) "curve" true (p.curve = p'.curve)

(** {1 Lane Tests} *)

let test_create_lane () =
  let lane = create_lane ~track_index:0 ~param_name:"volume" () in
  Alcotest.(check int) "track_index" 0 lane.track_index;
  Alcotest.(check string) "param_name" "volume" lane.param_name;
  Alcotest.(check bool) "default mode" true (lane.mode = Read);
  Alcotest.(check int) "no points" 0 (List.length lane.points)

let test_lane_json_roundtrip () =
  let points = [
    create_point ~time:0.0 ~value:0.5 ();
    create_point ~time:1.0 ~value:1.0 ~curve:Bezier ();
  ] in
  let lane = create_lane ~track_index:1 ~param_name:"pan" ~mode:Touch ~points () in
  let json = lane_to_json lane in
  let lane' = lane_of_json json in
  Alcotest.(check int) "track_index" lane.track_index lane'.track_index;
  Alcotest.(check string) "param_name" lane.param_name lane'.param_name;
  Alcotest.(check bool) "mode" true (lane.mode = lane'.mode);
  Alcotest.(check int) "points count" (List.length lane.points) (List.length lane'.points)

(** {1 Interpolation Tests} *)

let test_interpolate_empty () =
  let result = interpolate_at ~points:[] ~time:1.0 in
  Alcotest.(check bool) "empty is none" true (Option.is_none result)

let test_interpolate_single_point () =
  let points = [create_point ~time:5.0 ~value:0.7 ()] in
  let result = interpolate_at ~points ~time:1.0 in
  Alcotest.(check bool) "has value" true (Option.is_some result);
  Alcotest.(check float_approx) "value" 0.7 (Option.get result)

let test_interpolate_linear () =
  let points = [
    create_point ~time:0.0 ~value:0.0 ~curve:Linear ();
    create_point ~time:10.0 ~value:1.0 ();
  ] in
  (* At t=5, should be 0.5 *)
  let result = interpolate_at ~points ~time:5.0 in
  Alcotest.(check float_approx) "midpoint" 0.5 (Option.get result);
  (* At t=2.5, should be 0.25 *)
  let result2 = interpolate_at ~points ~time:2.5 in
  Alcotest.(check float_approx) "quarter" 0.25 (Option.get result2)

let test_interpolate_step () =
  let points = [
    create_point ~time:0.0 ~value:0.0 ~curve:Step ();
    create_point ~time:10.0 ~value:1.0 ();
  ] in
  (* Step should not interpolate *)
  let result = interpolate_at ~points ~time:5.0 in
  Alcotest.(check float_approx) "step holds" 0.0 (Option.get result)

let test_interpolate_before_first () =
  let points = [
    create_point ~time:5.0 ~value:0.5 ();
    create_point ~time:10.0 ~value:1.0 ();
  ] in
  let result = interpolate_at ~points ~time:2.0 in
  Alcotest.(check float_approx) "before first" 0.5 (Option.get result)

let test_interpolate_after_last () =
  let points = [
    create_point ~time:0.0 ~value:0.0 ();
    create_point ~time:5.0 ~value:0.5 ();
  ] in
  let result = interpolate_at ~points ~time:10.0 in
  Alcotest.(check float_approx) "after last" 0.5 (Option.get result)

(** {1 Lane Operation Tests} *)

let test_add_point () =
  let lane = create_lane ~track_index:0 ~param_name:"volume" () in
  let p1 = create_point ~time:1.0 ~value:0.5 () in
  let lane' = add_point lane p1 in
  Alcotest.(check int) "has 1 point" 1 (List.length lane'.points)

let test_add_point_replaces () =
  let p1 = create_point ~time:1.0 ~value:0.5 () in
  let lane = create_lane ~track_index:0 ~param_name:"volume" ~points:[p1] () in
  let p2 = create_point ~time:1.0 ~value:0.8 () in
  let lane' = add_point lane p2 in
  Alcotest.(check int) "still 1 point" 1 (List.length lane'.points);
  Alcotest.(check float_approx) "updated value" 0.8 (List.hd lane'.points).value

let test_remove_points_in_range () =
  let points = [
    create_point ~time:0.0 ~value:0.0 ();
    create_point ~time:5.0 ~value:0.5 ();
    create_point ~time:10.0 ~value:1.0 ();
  ] in
  let lane = create_lane ~track_index:0 ~param_name:"volume" ~points () in
  let lane' = remove_points_in_range lane ~start_time:3.0 ~end_time:7.0 in
  Alcotest.(check int) "removed 1" 2 (List.length lane'.points)

let test_get_points_in_range () =
  let points = [
    create_point ~time:0.0 ~value:0.0 ();
    create_point ~time:5.0 ~value:0.5 ();
    create_point ~time:10.0 ~value:1.0 ();
  ] in
  let lane = create_lane ~track_index:0 ~param_name:"volume" ~points () in
  let in_range = get_points_in_range lane ~start_time:3.0 ~end_time:7.0 in
  Alcotest.(check int) "1 in range" 1 (List.length in_range)

(** {1 Write Operation Tests} *)

let test_apply_write_operation () =
  let lane = create_lane ~track_index:0 ~param_name:"volume" () in
  let new_points = [
    create_point ~time:0.0 ~value:0.5 ();
    create_point ~time:2.0 ~value:0.8 ();
  ] in
  let op = { lane; new_points; replace_range = None } in
  let lane' = apply_write_operation op in
  Alcotest.(check int) "2 points" 2 (List.length lane'.points)

let test_apply_write_with_replace () =
  let existing = [
    create_point ~time:0.0 ~value:0.0 ();
    create_point ~time:5.0 ~value:0.5 ();
    create_point ~time:10.0 ~value:1.0 ();
  ] in
  let lane = create_lane ~track_index:0 ~param_name:"volume" ~points:existing () in
  let new_points = [
    create_point ~time:4.0 ~value:0.4 ();
    create_point ~time:6.0 ~value:0.6 ();
  ] in
  let op = { lane; new_points; replace_range = Some (3.0, 7.0) } in
  let lane' = apply_write_operation op in
  (* Original had 3, removed 1 in range, added 2 = 4 *)
  Alcotest.(check int) "4 points" 4 (List.length lane'.points)

let test_parse_write_request () =
  let json = Yojson.Safe.from_string {|{
    "track_index": 0,
    "param_name": "volume",
    "points": [
      {"time": 0.0, "value": 0.5},
      {"time": 2.0, "value": 1.0, "curve": "bezier"}
    ]
  }|} in
  let op = parse_write_request json in
  Alcotest.(check int) "track_index" 0 op.lane.track_index;
  Alcotest.(check string) "param_name" "volume" op.lane.param_name;
  Alcotest.(check int) "2 new points" 2 (List.length op.new_points);
  Alcotest.(check bool) "no replace range" true (Option.is_none op.replace_range)

(** {1 Tool Definition Tests} *)

let test_tool_definitions () =
  let read_json = Yojson.Safe.from_string automation_read_tool in
  let write_json = Yojson.Safe.from_string automation_write_tool in
  let mode_json = Yojson.Safe.from_string automation_mode_tool in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "read tool name" "daw_automation_read"
    (read_json |> member "name" |> to_string);
  Alcotest.(check string) "write tool name" "daw_automation_write"
    (write_json |> member "name" |> to_string);
  Alcotest.(check string) "mode tool name" "daw_automation_mode"
    (mode_json |> member "name" |> to_string)

(** {1 Param Info Tests} *)

let test_volume_param () =
  Alcotest.(check string) "name" "volume" volume_param.name;
  Alcotest.(check float_approx) "min" 0.0 volume_param.min_value;
  Alcotest.(check float_approx) "max" 1.0 volume_param.max_value

let test_normalized_to_display () =
  let param = { volume_param with min_value = -60.0; max_value = 6.0 } in
  let display = normalized_to_display ~param 0.5 in
  Alcotest.(check float_approx) "midpoint" (-27.0) display

let test_display_to_normalized () =
  let param = { volume_param with min_value = -60.0; max_value = 6.0 } in
  let norm = display_to_normalized ~param (-27.0) in
  Alcotest.(check float_approx) "midpoint" 0.5 norm

(** All tests *)
let () =
  Alcotest.run "Automation" [
    "mode", [
      Alcotest.test_case "to_string" `Quick test_mode_to_string;
      Alcotest.test_case "of_string" `Quick test_mode_of_string;
    ];
    "curve type", [
      Alcotest.test_case "roundtrip" `Quick test_curve_type_roundtrip;
    ];
    "point", [
      Alcotest.test_case "create" `Quick test_create_point;
      Alcotest.test_case "with curve" `Quick test_create_point_with_curve;
      Alcotest.test_case "json roundtrip" `Quick test_point_json_roundtrip;
    ];
    "lane", [
      Alcotest.test_case "create" `Quick test_create_lane;
      Alcotest.test_case "json roundtrip" `Quick test_lane_json_roundtrip;
    ];
    "interpolation", [
      Alcotest.test_case "empty" `Quick test_interpolate_empty;
      Alcotest.test_case "single point" `Quick test_interpolate_single_point;
      Alcotest.test_case "linear" `Quick test_interpolate_linear;
      Alcotest.test_case "step" `Quick test_interpolate_step;
      Alcotest.test_case "before first" `Quick test_interpolate_before_first;
      Alcotest.test_case "after last" `Quick test_interpolate_after_last;
    ];
    "lane operations", [
      Alcotest.test_case "add point" `Quick test_add_point;
      Alcotest.test_case "add replaces" `Quick test_add_point_replaces;
      Alcotest.test_case "remove in range" `Quick test_remove_points_in_range;
      Alcotest.test_case "get in range" `Quick test_get_points_in_range;
    ];
    "write operation", [
      Alcotest.test_case "apply" `Quick test_apply_write_operation;
      Alcotest.test_case "with replace" `Quick test_apply_write_with_replace;
      Alcotest.test_case "parse request" `Quick test_parse_write_request;
    ];
    "tools", [
      Alcotest.test_case "definitions" `Quick test_tool_definitions;
    ];
    "param info", [
      Alcotest.test_case "volume param" `Quick test_volume_param;
      Alcotest.test_case "normalized to display" `Quick test_normalized_to_display;
      Alcotest.test_case "display to normalized" `Quick test_display_to_normalized;
    ];
  ]
