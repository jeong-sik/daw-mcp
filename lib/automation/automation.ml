(** Automation API - Read/Write automation data for DAW tracks

    Provides types and functions for:
    - Reading existing automation data
    - Writing automation points with various curve types
    - Setting automation modes (Read, Write, Touch, Latch)
*)

(** Automation modes supported by DAWs *)
type mode =
  | Off        (** No automation *)
  | Read       (** Play back automation, no recording *)
  | Write      (** Overwrite automation continuously *)
  | Touch      (** Record only while parameter is touched *)
  | Latch      (** Like Touch but maintains last value after release *)

let mode_to_string = function
  | Off -> "off"
  | Read -> "read"
  | Write -> "write"
  | Touch -> "touch"
  | Latch -> "latch"

let mode_of_string = function
  | "off" -> Some Off
  | "read" -> Some Read
  | "write" -> Some Write
  | "touch" -> Some Touch
  | "latch" -> Some Latch
  | _ -> None

(** Curve interpolation types *)
type curve_type =
  | Linear        (** Straight line between points *)
  | Bezier        (** Smooth bezier curve *)
  | Exponential   (** Exponential curve (fast start, slow end) *)
  | Logarithmic   (** Logarithmic curve (slow start, fast end) *)
  | Step          (** No interpolation, instant jump *)

let curve_type_to_string = function
  | Linear -> "linear"
  | Bezier -> "bezier"
  | Exponential -> "exponential"
  | Logarithmic -> "logarithmic"
  | Step -> "step"

let curve_type_of_string = function
  | "linear" -> Some Linear
  | "bezier" -> Some Bezier
  | "exponential" -> Some Exponential
  | "logarithmic" -> Some Logarithmic
  | "step" -> Some Step
  | _ -> None

(** Automation point with time and value *)
type point = {
  time : float;     (** Time in seconds from project start *)
  value : float;    (** Normalized value 0.0-1.0 *)
  curve : curve_type;  (** Curve to next point *)
}

let create_point ?(curve = Linear) ~time ~value () =
  { time; value; curve }

let point_to_json p =
  `Assoc [
    ("time", `Float p.time);
    ("value", `Float p.value);
    ("curve", `String (curve_type_to_string p.curve));
  ]

let point_of_json json =
  let open Yojson.Safe.Util in
  let time = json |> member "time" |> to_float in
  let value = json |> member "value" |> to_float in
  let curve_str = json |> member "curve" |> to_string_option |> Option.value ~default:"linear" in
  let curve = curve_type_of_string curve_str |> Option.value ~default:Linear in
  { time; value; curve }

(** Automation lane for a single parameter *)
type lane = {
  track_index : int;
  param_name : string;
  points : point list;
  mode : mode;
}

let create_lane ~track_index ~param_name ?(mode = Read) ?(points = []) () =
  { track_index; param_name; points; mode }

let lane_to_json lane =
  `Assoc [
    ("track_index", `Int lane.track_index);
    ("param_name", `String lane.param_name);
    ("points", `List (List.map point_to_json lane.points));
    ("mode", `String (mode_to_string lane.mode));
  ]

let lane_of_json json =
  let open Yojson.Safe.Util in
  let track_index = json |> member "track_index" |> to_int in
  let param_name = json |> member "param_name" |> to_string in
  let mode_str = json |> member "mode" |> to_string_option |> Option.value ~default:"read" in
  let mode = mode_of_string mode_str |> Option.value ~default:Read in
  let points = json |> member "points" |> to_list |> List.map point_of_json in
  { track_index; param_name; points; mode }

(** Interpolate value at a given time *)
let interpolate_at ~(points : point list) ~time =
  match points with
  | [] -> None
  | [p] -> Some p.value
  | _ ->
    (* Find surrounding points *)
    let sorted = List.sort (fun a b -> Float.compare a.time b.time) points in
    let rec find_segment = function
      | [] -> None
      | [last] -> Some last.value  (* After last point *)
      | p1 :: p2 :: rest ->
        if time < p1.time then Some p1.value  (* Before first point *)
        else if time >= p1.time && time <= p2.time then
          (* Interpolate between p1 and p2 *)
          let t = (time -. p1.time) /. (p2.time -. p1.time) in
          let interpolated = match p1.curve with
            | Linear -> p1.value +. t *. (p2.value -. p1.value)
            | Step -> p1.value
            | Exponential ->
              let t' = t *. t in  (* Quadratic ease-in *)
              p1.value +. t' *. (p2.value -. p1.value)
            | Logarithmic ->
              let t' = Float.sqrt t in  (* Sqrt ease-out *)
              p1.value +. t' *. (p2.value -. p1.value)
            | Bezier ->
              (* Simplified cubic bezier *)
              let t' = t *. t *. (3.0 -. 2.0 *. t) in
              p1.value +. t' *. (p2.value -. p1.value)
          in
          Some interpolated
        else find_segment (p2 :: rest)
    in
    find_segment sorted

(** Add or update a point in a lane *)
let add_point lane point =
  (* Remove any existing point at the same time *)
  let filtered = List.filter (fun p -> Float.abs (p.time -. point.time) > 0.001) lane.points in
  let new_points = List.sort (fun a b -> Float.compare a.time b.time) (point :: filtered) in
  { lane with points = new_points }

(** Remove points in a time range *)
let remove_points_in_range lane ~start_time ~end_time =
  let filtered = List.filter (fun p ->
    p.time < start_time || p.time > end_time
  ) lane.points in
  { lane with points = filtered }

(** Get points in a time range *)
let get_points_in_range lane ~start_time ~end_time =
  List.filter (fun p ->
    p.time >= start_time && p.time <= end_time
  ) lane.points

(** Write operation for batch point insertion *)
type write_operation = {
  lane : lane;
  new_points : point list;
  replace_range : (float * float) option;  (** Optional: replace points in this range *)
}

let apply_write_operation op =
  let lane = match op.replace_range with
    | Some (start_time, end_time) ->
      remove_points_in_range op.lane ~start_time ~end_time
    | None -> op.lane
  in
  List.fold_left add_point lane op.new_points

(** MCP tool definitions *)
let automation_read_tool = {|{
  "name": "daw_automation_read",
  "description": "Read automation data for a track parameter",
  "inputSchema": {
    "type": "object",
    "properties": {
      "track_index": {
        "type": "integer",
        "description": "Track index (0-based)"
      },
      "param_name": {
        "type": "string",
        "description": "Parameter name (e.g., 'volume', 'pan', 'mute')"
      },
      "start_time": {
        "type": "number",
        "description": "Start time in seconds (optional)"
      },
      "end_time": {
        "type": "number",
        "description": "End time in seconds (optional)"
      }
    },
    "required": ["track_index", "param_name"]
  }
}|}

let automation_write_tool = {|{
  "name": "daw_automation_write",
  "description": "Write automation points for a track parameter",
  "inputSchema": {
    "type": "object",
    "properties": {
      "track_index": {
        "type": "integer",
        "description": "Track index (0-based)"
      },
      "param_name": {
        "type": "string",
        "description": "Parameter name (e.g., 'volume', 'pan')"
      },
      "points": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "time": {"type": "number"},
            "value": {"type": "number"},
            "curve": {
              "type": "string",
              "enum": ["linear", "bezier", "exponential", "logarithmic", "step"]
            }
          },
          "required": ["time", "value"]
        },
        "description": "Automation points to write"
      },
      "replace_start": {
        "type": "number",
        "description": "If set with replace_end, delete existing points in range first"
      },
      "replace_end": {
        "type": "number",
        "description": "If set with replace_start, delete existing points in range first"
      }
    },
    "required": ["track_index", "param_name", "points"]
  }
}|}

let automation_mode_tool = {|{
  "name": "daw_automation_mode",
  "description": "Set automation mode for a track",
  "inputSchema": {
    "type": "object",
    "properties": {
      "track_index": {
        "type": "integer",
        "description": "Track index (0-based)"
      },
      "mode": {
        "type": "string",
        "enum": ["off", "read", "write", "touch", "latch"],
        "description": "Automation mode to set"
      }
    },
    "required": ["track_index", "mode"]
  }
}|}

(** Parse automation write request from JSON *)
let parse_write_request json =
  let open Yojson.Safe.Util in
  let track_index = json |> member "track_index" |> to_int in
  let param_name = json |> member "param_name" |> to_string in
  let points = json |> member "points" |> to_list |> List.map point_of_json in
  let replace_range =
    match (json |> member "replace_start", json |> member "replace_end") with
    | (`Float s, `Float e) -> Some (s, e)
    | _ -> None
  in
  let lane = create_lane ~track_index ~param_name () in
  { lane; new_points = points; replace_range }

(** Common parameter names with normalized value ranges *)
type param_info = {
  name : string;
  display_name : string;
  min_value : float;
  max_value : float;
  default_value : float;
  unit : string;
}

let volume_param = {
  name = "volume";
  display_name = "Volume";
  min_value = 0.0;
  max_value = 1.0;
  default_value = 0.75;  (* -6 dB *)
  unit = "dB";
}

let pan_param = {
  name = "pan";
  display_name = "Pan";
  min_value = 0.0;
  max_value = 1.0;
  default_value = 0.5;  (* Center *)
  unit = "";
}

let mute_param = {
  name = "mute";
  display_name = "Mute";
  min_value = 0.0;
  max_value = 1.0;
  default_value = 0.0;  (* Unmuted *)
  unit = "";
}

(** Convert normalized value to display value *)
let normalized_to_display ~param value =
  param.min_value +. value *. (param.max_value -. param.min_value)

(** Convert display value to normalized value *)
let display_to_normalized ~param value =
  (value -. param.min_value) /. (param.max_value -. param.min_value)
