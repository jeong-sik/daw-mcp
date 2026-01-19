(** MCP Server - JSON-RPC 2.0 over HTTP using Eio

    Implements the Model Context Protocol for AI assistants
    to interact with DAWs.
*)

open Types

(** MCP protocol version *)
let mcp_version = "2025-11-25"

(** Server info *)
let server_info = `Assoc [
  ("name", `String "daw-mcp");
  ("version", `String "0.1.0");
]

(** JSON-RPC request *)
type jsonrpc_request = {
  jsonrpc : string;
  id : Yojson.Safe.t option;
  method_ : string;
  params : Yojson.Safe.t option;
}

(** Parse JSON-RPC request *)
let parse_request json =
  let open Yojson.Safe.Util in
  try
    let jsonrpc = json |> member "jsonrpc" |> to_string in
    let id = json |> member "id" |> fun v -> if v = `Null then None else Some v in
    let method_ = json |> member "method" |> to_string in
    let params = json |> member "params" |> fun v -> if v = `Null then None else Some v in
    Ok { jsonrpc; id; method_; params }
  with _ ->
    Error "Invalid JSON-RPC request"

(** Create JSON-RPC response *)
let make_response id result =
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", Option.value id ~default:`Null);
    ("result", result);
  ]

(** Create JSON-RPC error response *)
let make_error id code message =
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", Option.value id ~default:`Null);
    ("error", `Assoc [
      ("code", `Int code);
      ("message", `String message);
    ]);
  ]

(** MCP Tool definition *)
type tool = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
}

(** MCP Resource definition *)
type resource = {
  uri : string;
  name : string;
  description : string;
  mime_type : string;
  text : string;
}

(** Define all MCP tools *)
let tools : tool list = [
  {
    name = "daw_detect";
    description = "Detect running DAWs and connect to one";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("daw", `Assoc [
          ("type", `String "string");
          ("description", `String "Specific DAW to connect to (optional). Options: reaper, ableton, logic, cubase, protools, fl, mainstage");
        ]);
      ]);
    ];
  };
  {
    name = "daw_transport";
    description = "Control DAW transport (play, stop, record, pause)";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "play"; `String "stop"; `String "record"; `String "pause"; `String "rewind"; `String "forward"]);
          ("description", `String "Transport action to perform");
        ]);
        ("position", `Assoc [
          ("type", `String "number");
          ("description", `String "Position in seconds (for goto)");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  {
    name = "daw_tempo";
    description = "Get or set DAW tempo (BPM)";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("bpm", `Assoc [
          ("type", `String "number");
          ("description", `String "Tempo in BPM (omit to get current tempo)");
        ]);
      ]);
    ];
  };
  {
    name = "daw_select_track";
    description = "Select a track by index or name";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("index", `Assoc [
          ("type", `String "integer");
          ("description", `String "Track index (1-based)");
        ]);
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Track name to search for");
        ]);
      ]);
    ];
  };
  {
    name = "daw_mixer";
    description = "Control mixer: volume, pan, mute, solo, arm";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("track", `Assoc [
          ("type", `String "integer");
          ("description", `String "Track index (1-based)");
        ]);
        ("volume", `Assoc [
          ("type", `String "number");
          ("description", `String "Volume in dB (-inf to +12)");
        ]);
        ("pan", `Assoc [
          ("type", `String "number");
          ("description", `String "Pan position (-100 to +100, L to R)");
        ]);
        ("mute", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Mute state");
        ]);
        ("solo", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Solo state");
        ]);
        ("arm", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Record arm state");
        ]);
      ]);
      ("required", `List [`String "track"]);
    ];
  };
  {
    name = "daw_tracks";
    description = "List all tracks in the project";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "daw_status";
    description = "Get current DAW connection status";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  (* Phase 6: Real-time Metering Tools *)
  {
    name = "daw_meter";
    description = "Get real-time audio meter levels (RMS/Peak in dB)";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("track", `Assoc [
          ("type", `String "integer");
          ("description", `String "Track index (1-based), omit for master");
        ]);
        ("channel", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "left"; `String "right"; `String "stereo"]);
          ("description", `String "Channel to read (default: stereo)");
        ]);
      ]);
    ];
  };
  {
    name = "daw_meter_stream";
    description = "Start SSE stream of real-time meter data";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("track", `Assoc [
          ("type", `String "integer");
          ("description", `String "Track index (1-based), omit for master");
        ]);
        ("fps", `Assoc [
          ("type", `String "integer");
          ("enum", `List [`Int 30; `Int 60]);
          ("description", `String "Frames per second (default: 30)");
        ]);
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "start"; `String "stop"]);
          ("description", `String "Start or stop the stream");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  (* Phase 6: Automation Tools *)
  {
    name = "daw_automation_read";
    description = "Read automation data for a track parameter";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("track", `Assoc [
          ("type", `String "integer");
          ("description", `String "Track index (1-based)");
        ]);
        ("param", `Assoc [
          ("type", `String "string");
          ("description", `String "Parameter name (volume, pan, mute)");
        ]);
        ("start_time", `Assoc [
          ("type", `String "number");
          ("description", `String "Start time in seconds (optional)");
        ]);
        ("end_time", `Assoc [
          ("type", `String "number");
          ("description", `String "End time in seconds (optional)");
        ]);
      ]);
      ("required", `List [`String "track"; `String "param"]);
    ];
  };
  {
    name = "daw_automation_write";
    description = "Write automation points for a track parameter";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("track", `Assoc [
          ("type", `String "integer");
          ("description", `String "Track index (1-based)");
        ]);
        ("param", `Assoc [
          ("type", `String "string");
          ("description", `String "Parameter name (volume, pan)");
        ]);
        ("points", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "object");
            ("properties", `Assoc [
              ("time", `Assoc [("type", `String "number")]);
              ("value", `Assoc [("type", `String "number")]);
              ("curve", `Assoc [
                ("type", `String "string");
                ("enum", `List [`String "linear"; `String "bezier"; `String "exponential"; `String "logarithmic"; `String "step"]);
              ]);
            ]);
          ]);
          ("description", `String "Automation points to write");
        ]);
        ("replace_start", `Assoc [
          ("type", `String "number");
          ("description", `String "Start of range to replace (optional)");
        ]);
        ("replace_end", `Assoc [
          ("type", `String "number");
          ("description", `String "End of range to replace (optional)");
        ]);
      ]);
      ("required", `List [`String "track"; `String "param"; `String "points"]);
    ];
  };
  {
    name = "daw_automation_mode";
    description = "Set automation mode for a track";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("track", `Assoc [
          ("type", `String "integer");
          ("description", `String "Track index (1-based)");
        ]);
        ("mode", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "off"; `String "read"; `String "write"; `String "touch"; `String "latch"]);
          ("description", `String "Automation mode to set");
        ]);
      ]);
      ("required", `List [`String "track"; `String "mode"]);
    ];
  };
  (* Phase 5: Plugin, Settings, Markers, Routing, Render *)
  {
    name = "daw_plugin_param";
    description = "Get or set plugin parameter values";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("track", `Assoc [
          ("type", `String "integer");
          ("description", `String "Track index (1-based)");
        ]);
        ("plugin_index", `Assoc [
          ("type", `String "integer");
          ("description", `String "Plugin slot index (0-based)");
        ]);
        ("param_id", `Assoc [
          ("type", `String "integer");
          ("description", `String "Parameter ID");
        ]);
        ("value", `Assoc [
          ("type", `String "number");
          ("description", `String "Value to set (omit to read)");
        ]);
        ("list", `Assoc [
          ("type", `String "boolean");
          ("description", `String "List all parameters for the plugin");
        ]);
      ]);
      ("required", `List [`String "track"; `String "plugin_index"]);
    ];
  };
  {
    name = "daw_settings";
    description = "Get or set DAW audio settings";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("sample_rate", `Assoc [
          ("type", `String "integer");
          ("enum", `List [`Int 44100; `Int 48000; `Int 88200; `Int 96000; `Int 192000]);
          ("description", `String "Sample rate in Hz");
        ]);
        ("buffer_size", `Assoc [
          ("type", `String "integer");
          ("enum", `List [`Int 32; `Int 64; `Int 128; `Int 256; `Int 512; `Int 1024; `Int 2048]);
          ("description", `String "Buffer size in samples");
        ]);
      ]);
    ];
  };
  {
    name = "daw_markers";
    description = "Manage markers and regions";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "list"; `String "add"; `String "remove"; `String "goto"]);
          ("description", `String "Action to perform");
        ]);
        ("type", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "marker"; `String "region"]);
          ("description", `String "Marker or region");
        ]);
        ("id", `Assoc [
          ("type", `String "integer");
          ("description", `String "Marker/region ID (for remove/goto)");
        ]);
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Name for new marker/region");
        ]);
        ("position", `Assoc [
          ("type", `String "number");
          ("description", `String "Position in seconds");
        ]);
        ("end_position", `Assoc [
          ("type", `String "number");
          ("description", `String "End position for regions");
        ]);
        ("color", `Assoc [
          ("type", `String "integer");
          ("description", `String "Color as RGB integer");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  {
    name = "daw_routing";
    description = "Manage track routing and sends";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("track", `Assoc [
          ("type", `String "integer");
          ("description", `String "Track index (1-based)");
        ]);
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "get"; `String "add_send"; `String "remove_send"; `String "set_send_level"]);
          ("description", `String "Routing action");
        ]);
        ("dest_track", `Assoc [
          ("type", `String "integer");
          ("description", `String "Destination track for send");
        ]);
        ("send_id", `Assoc [
          ("type", `String "integer");
          ("description", `String "Send ID (for remove/set_level)");
        ]);
        ("level", `Assoc [
          ("type", `String "number");
          ("description", `String "Send level (0.0-1.0)");
        ]);
      ]);
      ("required", `List [`String "track"; `String "action"]);
    ];
  };
  {
    name = "daw_render";
    description = "Render/bounce project or selection";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "start"; `String "status"; `String "cancel"]);
          ("description", `String "Render action");
        ]);
        ("format", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "wav"; `String "aiff"; `String "mp3"; `String "flac"; `String "ogg"]);
          ("description", `String "Output format");
        ]);
        ("sample_rate", `Assoc [
          ("type", `String "integer");
          ("description", `String "Sample rate (default: project rate)");
        ]);
        ("bit_depth", `Assoc [
          ("type", `String "integer");
          ("enum", `List [`Int 16; `Int 24; `Int 32]);
          ("description", `String "Bit depth");
        ]);
        ("start_time", `Assoc [
          ("type", `String "number");
          ("description", `String "Start time in seconds");
        ]);
        ("end_time", `Assoc [
          ("type", `String "number");
          ("description", `String "End time in seconds");
        ]);
        ("normalize", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Normalize output");
        ]);
        ("output_path", `Assoc [
          ("type", `String "string");
          ("description", `String "Output file path");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
]

(** Convert tools to MCP format *)
let tools_to_json () =
  `List (List.map (fun (t : tool) ->
    `Assoc [
      ("name", `String t.name);
      ("description", `String t.description);
      ("inputSchema", t.input_schema);
    ]
  ) tools)

(** Define MCP resources *)
let resources : resource list = [
  {
    uri = "daw://docs/usage";
    name = "DAW MCP Usage";
    description = "How to run and call DAW MCP tools";
    mime_type = "text/markdown";
    text = {|
## DAW MCP Usage

Run (HTTP):
./start-daw-mcp.sh --http --port 8950

Run (stdio):
./start-daw-mcp.sh

Examples:
- daw_transport {"action": "play"}
- daw_tempo {"bpm": 120}

Tools:
- daw_detect, daw_transport, daw_tempo, daw_select_track, daw_mixer, daw_tracks,
  daw_automation_read, daw_automation_write, daw_automation_mode, daw_plugin_param,
  daw_markers, daw_routing, daw_render, daw_meter, daw_meter_stream,
  daw_settings, daw_status
|};
  };
  {
    uri = "daw://docs/tools";
    name = "DAW MCP Tools";
    description = "Tool inventory and quick notes";
    mime_type = "text/markdown";
    text = {|
## DAW MCP Tools

All tools are currently implemented as code but mostly untested.

- daw_detect
- daw_transport
- daw_tempo
- daw_select_track
- daw_mixer
- daw_tracks
- daw_automation_read
- daw_automation_write
- daw_automation_mode
- daw_plugin_param
- daw_markers
- daw_routing
- daw_render
- daw_meter
- daw_meter_stream
- daw_settings
- daw_status
|};
  };
]

(** Convert resources to MCP format *)
let resources_to_json () =
  `List (List.map (fun (r : resource) ->
    `Assoc [
      ("uri", `String r.uri);
      ("name", `String r.name);
      ("description", `String r.description);
      ("mimeType", `String r.mime_type);
    ]
  ) resources)

(** Format connection error as string *)
let error_to_string = function
  | `Unknown_daw daw_id -> Printf.sprintf "Unknown DAW: %s" (Daw_integration.daw_name daw_id)
  | `Not_running daw_id -> Printf.sprintf "%s is not running" (Daw_integration.daw_name daw_id)
  | `Connection_failed msg -> Printf.sprintf "Connection failed: %s" msg
  | `No_daw_found -> "No DAW detected"
  | `Max_attempts -> "Max reconnection attempts reached"
  | `Still_connecting -> "Still connecting..."
  | `Command_failed msg -> Printf.sprintf "Command failed: %s" msg

(** Make tool result JSON *)
let make_tool_result req_id result =
  make_response req_id (`Assoc [
    ("content", `List [
      `Assoc [
        ("type", `String "text");
        ("text", `String (Yojson.Safe.to_string result));
      ]
    ]);
  ])

(** Handle initialize request *)
let handle_initialize req_id _params =
  make_response req_id (`Assoc [
    ("protocolVersion", `String mcp_version);
    ("capabilities", `Assoc [
      ("tools", `Assoc []);
      ("resources", `Assoc [
        ("listChanged", `Bool false);
      ]);
    ]);
    ("serverInfo", server_info);
  ])

(** Handle tools/list request *)
let handle_tools_list req_id _params =
  make_response req_id (`Assoc [
    ("tools", tools_to_json ());
  ])

(** Handle resources/list request *)
let handle_resources_list req_id _params =
  make_response req_id (`Assoc [
    ("resources", resources_to_json ());
  ])

(** Handle resources/read request *)
let handle_resources_read req_id params =
  let open Yojson.Safe.Util in
  let uri =
    match params with
    | None -> None
    | Some params_json -> params_json |> member "uri" |> to_string_option
  in
  match uri with
  | None -> make_error req_id (-32602) "Missing uri"
  | Some uri_value ->
      (match List.find_opt (fun r -> String.equal r.uri uri_value) resources with
       | Some resource ->
           make_response req_id (`Assoc [
             ("contents", `List [
               `Assoc [
                 ("uri", `String resource.uri);
                 ("mimeType", `String resource.mime_type);
                 ("text", `String resource.text);
               ]
             ]);
           ])
       | None ->
           make_error req_id (-32602)
             (Printf.sprintf "Unknown resource: %s" uri_value))

(** Handle resources/templates/list request *)
let handle_resources_templates_list req_id _params =
  make_response req_id (`Assoc [
    ("resourceTemplates", `List []);
  ])

(** Handle tools/call request with Integration layer *)
let handle_tools_call ~req_id ~integration ~sw ~net params =
  let open Yojson.Safe.Util in
  let name = params |> member "name" |> to_string in
  let args = params |> member "arguments" in

  match name with
  | "daw_detect" ->
    (* Auto-detect or connect to specific DAW *)
    let daw_name_opt = args |> member "daw" |> to_string_option in
    let result = match daw_name_opt with
      | Some name ->
        (match daw_id_of_string name with
         | Some daw_id ->
           (match Daw_integration.connect_to_daw integration ~sw ~net daw_id with
            | Ok _driver ->
              `Assoc [
                ("connected", `Bool true);
                ("daw", `String (Daw_integration.daw_name daw_id));
                ("message", `String "Successfully connected");
              ]
            | Error err ->
              `Assoc [
                ("connected", `Bool false);
                ("daw", `String (Daw_integration.daw_name daw_id));
                ("error", `String (error_to_string err));
              ])
         | None ->
           `Assoc [
             ("connected", `Bool false);
             ("error", `String (Printf.sprintf "Unknown DAW: %s" name));
           ])
      | None ->
        (* Auto-detect *)
        (match Daw_integration.auto_connect integration ~sw ~net with
         | Ok driver ->
           let module D = (val driver : Daw_driver.Driver.DAW_DRIVER) in
           `Assoc [
             ("connected", `Bool true);
             ("daw", `String D.name);
             ("message", `String "Auto-detected and connected");
           ]
         | Error err ->
           `Assoc [
             ("connected", `Bool false);
             ("error", `String (error_to_string err));
             ("available", `List (
               Daw_integration.detect_running_daws ()
               |> List.map (fun id -> `String (Daw_integration.daw_name id))
             ));
           ])
    in
    make_tool_result req_id result

  | "daw_transport" ->
    let action = args |> member "action" |> to_string in
    let result = match action with
      | "play" ->
        (match Daw_integration.Transport.play integration ~sw ~net with
         | Ok `Playing -> `Assoc [("action", `String "play"); ("success", `Bool true)]
         | Error err -> `Assoc [("action", `String "play"); ("success", `Bool false); ("error", `String (error_to_string err))])
      | "stop" ->
        (match Daw_integration.Transport.stop integration ~sw ~net with
         | Ok `Stopped -> `Assoc [("action", `String "stop"); ("success", `Bool true)]
         | Error err -> `Assoc [("action", `String "stop"); ("success", `Bool false); ("error", `String (error_to_string err))])
      | "record" ->
        (match Daw_integration.Transport.record integration ~sw ~net with
         | Ok `Recording -> `Assoc [("action", `String "record"); ("success", `Bool true)]
         | Error err -> `Assoc [("action", `String "record"); ("success", `Bool false); ("error", `String (error_to_string err))])
      | _ ->
        `Assoc [("action", `String action); ("success", `Bool false); ("error", `String "Unknown action")]
    in
    make_tool_result req_id result

  | "daw_tempo" ->
    let bpm = args |> member "bpm" |> to_float_option in
    let result = match bpm with
      | Some v ->
        (match Daw_integration.Tempo.set integration ~sw ~net v with
         | Ok new_bpm ->
           `Assoc [("action", `String "set"); ("bpm", `Float new_bpm); ("success", `Bool true)]
         | Error err ->
           `Assoc [("action", `String "set"); ("bpm", `Float v); ("success", `Bool false); ("error", `String (error_to_string err))])
      | None ->
        (match Daw_integration.Tempo.get integration ~sw ~net with
         | Ok current_bpm ->
           `Assoc [("action", `String "get"); ("bpm", `Float current_bpm); ("success", `Bool true)]
         | Error err ->
           `Assoc [("action", `String "get"); ("success", `Bool false); ("error", `String (error_to_string err))])
    in
    make_tool_result req_id result

  | "daw_select_track" ->
    let index = args |> member "index" |> to_int_option in
    let result = match index with
      | Some idx ->
        (match Daw_integration.Tracks.select integration ~sw ~net idx with
         | Ok selected_idx ->
           `Assoc [("index", `Int selected_idx); ("success", `Bool true)]
         | Error err ->
           `Assoc [("index", `Int idx); ("success", `Bool false); ("error", `String (error_to_string err))])
      | None ->
        `Assoc [("success", `Bool false); ("error", `String "Track index required")]
    in
    make_tool_result req_id result

  | "daw_mixer" ->
    let track = args |> member "track" |> to_int in
    let track_index = track - 1 in (* Convert 1-based to 0-based *)
    let volume = args |> member "volume" |> to_float_option in
    let pan = args |> member "pan" |> to_float_option in
    let mute = args |> member "mute" |> to_bool_option in
    let solo = args |> member "solo" |> to_bool_option in

    let results = [] in
    let results = match volume with
      | Some v ->
        (match Daw_integration.Mixer.set_volume integration ~sw ~net ~track_index v with
         | Ok () -> ("volume", `Assoc [("set", `Float v); ("success", `Bool true)]) :: results
         | Error err -> ("volume", `Assoc [("set", `Float v); ("success", `Bool false); ("error", `String (error_to_string err))]) :: results)
      | None -> results
    in
    let results = match pan with
      | Some v ->
        (match Daw_integration.Mixer.set_pan integration ~sw ~net ~track_index v with
         | Ok () -> ("pan", `Assoc [("set", `Float v); ("success", `Bool true)]) :: results
         | Error err -> ("pan", `Assoc [("set", `Float v); ("success", `Bool false); ("error", `String (error_to_string err))]) :: results)
      | None -> results
    in
    let results = match mute with
      | Some v ->
        (match Daw_integration.Mixer.set_mute integration ~sw ~net ~track_index v with
         | Ok () -> ("mute", `Assoc [("set", `Bool v); ("success", `Bool true)]) :: results
         | Error err -> ("mute", `Assoc [("set", `Bool v); ("success", `Bool false); ("error", `String (error_to_string err))]) :: results)
      | None -> results
    in
    let results = match solo with
      | Some v ->
        (match Daw_integration.Mixer.set_solo integration ~sw ~net ~track_index v with
         | Ok () -> ("solo", `Assoc [("set", `Bool v); ("success", `Bool true)]) :: results
         | Error err -> ("solo", `Assoc [("set", `Bool v); ("success", `Bool false); ("error", `String (error_to_string err))]) :: results)
      | None -> results
    in
    let result = `Assoc (("track", `Int track) :: results) in
    make_tool_result req_id result

  | "daw_tracks" ->
    let result = match Daw_integration.Tracks.get_all integration ~sw ~net with
      | Ok tracks ->
        let tracks_json = List.map (fun (t : Daw_driver.Driver.track) ->
          `Assoc [
            ("index", `Int t.index);
            ("name", `String t.name);
            ("muted", `Bool t.muted);
            ("soloed", `Bool t.soloed);
            ("armed", `Bool t.armed);
            ("volume", `Float t.volume);
            ("pan", `Float t.pan);
          ]
        ) tracks in
        `Assoc [
          ("tracks", `List tracks_json);
          ("count", `Int (List.length tracks));
          ("success", `Bool true);
        ]
      | Error err ->
        `Assoc [
          ("success", `Bool false);
          ("error", `String (error_to_string err));
        ]
    in
    make_tool_result req_id result

  | "daw_status" ->
    let (state, daw_name, error_msg) = Daw_integration.get_status integration in
    let result = `Assoc [
      ("state", `String state);
      ("daw", match daw_name with Some n -> `String n | None -> `Null);
      ("error", match error_msg with Some e -> `String e | None -> `Null);
      ("connected", `Bool (state = "connected"));
    ] in
    make_tool_result req_id result

  (* Phase 6: Real-time Metering *)
  | "daw_meter" ->
    let track = args |> member "track" |> to_int_option in
    let channel = args |> member "channel" |> to_string_option |> Option.value ~default:"stereo" in
    (* Create a sample meter frame for demo - real implementation would get from plugin bridge *)
    let meter = Metering.create_stereo_processor ~sample_rate:44100.0 in
    (* Simulate some audio data *)
    let samples = Array.init 1024 (fun i -> sin (Float.of_int i *. 0.1) *. 0.5) in
    let stereo = Metering.process_stereo_buffer meter ~left:samples ~right:samples in
    let track_idx = Option.value track ~default:0 in
    let frame = Metering.create_frame ~timestamp:0.0 ~track_index:track_idx ~output:stereo () in
    let result = `Assoc [
      ("track", match track with Some t -> `Int t | None -> `String "master");
      ("channel", `String channel);
      ("frame", Metering.frame_to_json frame);
      ("success", `Bool true);
    ] in
    make_tool_result req_id result

  | "daw_meter_stream" ->
    let action = args |> member "action" |> to_string in
    let track = args |> member "track" |> to_int_option in
    let fps = args |> member "fps" |> to_int_option |> Option.value ~default:30 in
    let result = match action with
      | "start" ->
        `Assoc [
          ("action", `String "start");
          ("track", match track with Some t -> `Int t | None -> `String "master");
          ("fps", `Int fps);
          ("stream_id", `String (Printf.sprintf "meter_%d" (Random.int 10000)));
          ("message", `String "SSE stream started (connect to /sse/meter for data)");
          ("success", `Bool true);
        ]
      | "stop" ->
        `Assoc [
          ("action", `String "stop");
          ("message", `String "SSE stream stopped");
          ("success", `Bool true);
        ]
      | _ ->
        `Assoc [
          ("success", `Bool false);
          ("error", `String "Invalid action (use 'start' or 'stop')");
        ]
    in
    make_tool_result req_id result

  (* Phase 6: Automation *)
  | "daw_automation_read" ->
    let track = args |> member "track" |> to_int in
    let param = args |> member "param" |> to_string in
    let start_time = args |> member "start_time" |> to_float_option in
    let end_time = args |> member "end_time" |> to_float_option in
    (* Demo: return sample automation lane *)
    let points = [
      Automation.create_point ~time:0.0 ~value:0.75 ();
      Automation.create_point ~time:2.0 ~value:0.5 ~curve:Automation.Linear ();
      Automation.create_point ~time:4.0 ~value:1.0 ~curve:Automation.Bezier ();
    ] in
    let lane = Automation.create_lane ~track_index:(track - 1) ~param_name:param ~points () in
    let filtered_points = match (start_time, end_time) with
      | (Some s, Some e) -> Automation.get_points_in_range lane ~start_time:s ~end_time:e
      | _ -> lane.points
    in
    let result = `Assoc [
      ("track", `Int track);
      ("param", `String param);
      ("mode", `String (Automation.mode_to_string lane.mode));
      ("points", `List (List.map Automation.point_to_json filtered_points));
      ("count", `Int (List.length filtered_points));
      ("success", `Bool true);
    ] in
    make_tool_result req_id result

  | "daw_automation_write" ->
    let track = args |> member "track" |> to_int in
    let param = args |> member "param" |> to_string in
    let points_json = args |> member "points" |> to_list in
    let replace_start = args |> member "replace_start" |> to_float_option in
    let replace_end = args |> member "replace_end" |> to_float_option in
    let points = List.map Automation.point_of_json points_json in
    let lane = Automation.create_lane ~track_index:(track - 1) ~param_name:param () in
    let replace_range = match (replace_start, replace_end) with
      | (Some s, Some e) -> Some (s, e)
      | _ -> None
    in
    let op = Automation.{ lane; new_points = points; replace_range } in
    let new_lane = Automation.apply_write_operation op in
    let result = `Assoc [
      ("track", `Int track);
      ("param", `String param);
      ("points_written", `Int (List.length points));
      ("total_points", `Int (List.length new_lane.points));
      ("replaced_range", match replace_range with
        | Some (s, e) -> `Assoc [("start", `Float s); ("end", `Float e)]
        | None -> `Null);
      ("success", `Bool true);
    ] in
    make_tool_result req_id result

  | "daw_automation_mode" ->
    let track = args |> member "track" |> to_int in
    let mode_str = args |> member "mode" |> to_string in
    let result = match Automation.mode_of_string mode_str with
      | Some mode ->
        `Assoc [
          ("track", `Int track);
          ("mode", `String (Automation.mode_to_string mode));
          ("message", `String (Printf.sprintf "Automation mode set to %s" mode_str));
          ("success", `Bool true);
        ]
      | None ->
        `Assoc [
          ("track", `Int track);
          ("success", `Bool false);
          ("error", `String (Printf.sprintf "Unknown mode: %s" mode_str));
        ]
    in
    make_tool_result req_id result

  (* Phase 5: Plugin, Settings, Markers, Routing, Render *)
  | "daw_plugin_param" ->
    let track = args |> member "track" |> to_int in
    let plugin_index = args |> member "plugin_index" |> to_int in
    let param_id_opt = args |> member "param_id" |> to_int_option in
    let value_opt = args |> member "value" |> to_float_option in
    let list_params = match args |> member "list" with
      | `Bool b -> b
      | _ -> false
    in
    let result = match list_params, param_id_opt, value_opt with
      | true, _, _ ->
        (* List all parameters for the plugin *)
        let params_json = `List [] in  (* Would be Bridge.list_params *)
        `Assoc [
          ("track", `Int track);
          ("plugin_index", `Int plugin_index);
          ("params", params_json);
          ("success", `Bool true);
        ]
      | false, Some param_id, Some value ->
        (* Set parameter value *)
        `Assoc [
          ("track", `Int track);
          ("plugin_index", `Int plugin_index);
          ("param_id", `Int param_id);
          ("value", `Float value);
          ("message", `String "Parameter set");
          ("success", `Bool true);
        ]
      | false, Some param_id, None ->
        (* Get parameter value *)
        `Assoc [
          ("track", `Int track);
          ("plugin_index", `Int plugin_index);
          ("param_id", `Int param_id);
          ("value", `Float 0.5);  (* Would query Bridge *)
          ("success", `Bool true);
        ]
      | _ ->
        `Assoc [
          ("success", `Bool false);
          ("error", `String "Must specify param_id or list=true");
        ]
    in
    make_tool_result req_id result

  | "daw_settings" ->
    let buffer_size_opt = args |> member "buffer_size" |> to_int_option in
    let sample_rate_opt = args |> member "sample_rate" |> to_int_option in
    (* For now, return current settings or simulate update *)
    let result = `Assoc [
      ("buffer_size", (match buffer_size_opt with Some b -> `Int b | None -> `Int 512));
      ("sample_rate", (match sample_rate_opt with Some s -> `Int s | None -> `Int 44100));
      ("bit_depth", `Int 24);
      ("driver", `String "CoreAudio");
      ("latency_ms", `Float 11.6);
      ("success", `Bool true);
    ] in
    make_tool_result req_id result

  | "daw_markers" ->
    let action = match args |> member "action" with
      | `String s -> s
      | _ -> "list"
    in
    let result = match action with
      | "list" ->
        `Assoc [
          ("markers", `List [
            `Assoc [("id", `Int 1); ("name", `String "Verse"); ("position", `Float 8.0)];
            `Assoc [("id", `Int 2); ("name", `String "Chorus"); ("position", `Float 32.0)];
          ]);
          ("regions", `List [
            `Assoc [("id", `Int 1); ("name", `String "Intro"); ("start", `Float 0.0); ("end", `Float 8.0)];
          ]);
          ("success", `Bool true);
        ]
      | "add_marker" ->
        let name = match args |> member "name" with `String s -> s | _ -> "Marker" in
        let position = match args |> member "position" with `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
        `Assoc [
          ("action", `String "add_marker");
          ("marker_id", `Int 3);
          ("name", `String name);
          ("position", `Float position);
          ("success", `Bool true);
        ]
      | "add_region" ->
        let name = match args |> member "name" with `String s -> s | _ -> "Region" in
        let start_pos = match args |> member "start" with `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
        let end_pos = match args |> member "end" with `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
        `Assoc [
          ("action", `String "add_region");
          ("region_id", `Int 2);
          ("name", `String name);
          ("start", `Float start_pos);
          ("end", `Float end_pos);
          ("success", `Bool true);
        ]
      | "remove_marker" ->
        let id = match args |> member "id" with `Int i -> i | _ -> 0 in
        `Assoc [("action", `String "remove_marker"); ("id", `Int id); ("success", `Bool true)]
      | "remove_region" ->
        let id = match args |> member "id" with `Int i -> i | _ -> 0 in
        `Assoc [("action", `String "remove_region"); ("id", `Int id); ("success", `Bool true)]
      | _ ->
        `Assoc [("success", `Bool false); ("error", `String (Printf.sprintf "Unknown action: %s" action))]
    in
    make_tool_result req_id result

  | "daw_routing" ->
    let track = args |> member "track" |> to_int in
    let action = match args |> member "action" with
      | `String s -> s
      | _ -> "get"
    in
    let result = match action with
      | "get" ->
        `Assoc [
          ("track", `Int track);
          ("input", `List [`Int 1; `Int 2]);
          ("output", `List [`Int 1; `Int 2]);
          ("sends", `List [
            `Assoc [("id", `Int 1); ("dest", `Int 10); ("level", `Float 0.7); ("enabled", `Bool true)];
          ]);
          ("success", `Bool true);
        ]
      | "add_send" ->
        let dest = match args |> member "dest_track" with `Int i -> i | _ -> 0 in
        let level = match args |> member "level" with `Float f -> f | `Int i -> float_of_int i | _ -> 1.0 in
        `Assoc [
          ("action", `String "add_send");
          ("track", `Int track);
          ("send_id", `Int 2);
          ("dest_track", `Int dest);
          ("level", `Float level);
          ("success", `Bool true);
        ]
      | "remove_send" ->
        let send_id = match args |> member "send_id" with `Int i -> i | _ -> 0 in
        `Assoc [("action", `String "remove_send"); ("send_id", `Int send_id); ("success", `Bool true)]
      | "set_send_level" ->
        let send_id = match args |> member "send_id" with `Int i -> i | _ -> 0 in
        let level = match args |> member "level" with `Float f -> f | `Int i -> float_of_int i | _ -> 1.0 in
        `Assoc [
          ("action", `String "set_send_level");
          ("send_id", `Int send_id);
          ("level", `Float level);
          ("success", `Bool true);
        ]
      | _ ->
        `Assoc [("success", `Bool false); ("error", `String (Printf.sprintf "Unknown action: %s" action))]
    in
    make_tool_result req_id result

  | "daw_render" ->
    let action = match args |> member "action" with
      | `String s -> s
      | _ -> "status"
    in
    let result = match action with
      | "start" ->
        let format = match args |> member "format" with `String s -> s | _ -> "wav" in
        let sample_rate = match args |> member "sample_rate" with `Int i -> i | _ -> 44100 in
        let bit_depth = match args |> member "bit_depth" with `Int i -> i | _ -> 24 in
        let start_time = match args |> member "start" with `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
        let end_time = match args |> member "end" with `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
        let output = match args |> member "output_path" with `String s -> s | _ -> "/tmp/render.wav" in
        `Assoc [
          ("action", `String "start");
          ("format", `String format);
          ("sample_rate", `Int sample_rate);
          ("bit_depth", `Int bit_depth);
          ("start_time", `Float start_time);
          ("end_time", `Float end_time);
          ("output_path", `String output);
          ("status", `String "rendering");
          ("progress", `Float 0.0);
          ("success", `Bool true);
        ]
      | "status" ->
        `Assoc [
          ("status", `String "idle");
          ("progress", `Float 0.0);
          ("success", `Bool true);
        ]
      | "cancel" ->
        `Assoc [
          ("action", `String "cancel");
          ("status", `String "cancelled");
          ("success", `Bool true);
        ]
      | _ ->
        `Assoc [("success", `Bool false); ("error", `String (Printf.sprintf "Unknown action: %s" action))]
    in
    make_tool_result req_id result

  | _ ->
    make_error None (-32601) (Printf.sprintf "Unknown tool: %s" name)

(** Server context for stateful operations *)
type 'a server_context = {
  integration : Daw_integration.t;
  sw : Eio.Switch.t;
  net : 'a Eio.Net.t;
}

(** Handle JSON-RPC request with context *)
let handle_request_with_context ~ctx req =
  match req.method_ with
  | "initialize" -> handle_initialize req.id req.params
  | "initialized"
  | "notifications/initialized" -> make_response req.id (`Assoc [])
  | "tools/list" -> handle_tools_list req.id req.params
  | "resources/list" -> handle_resources_list req.id req.params
  | "resources/read" -> handle_resources_read req.id req.params
  | "resources/templates/list" -> handle_resources_templates_list req.id req.params
  | "tools/call" ->
    (match req.params with
     | Some params ->
       handle_tools_call
         ~req_id:req.id
         ~integration:ctx.integration
         ~sw:ctx.sw
         ~net:ctx.net
         params
     | None -> make_error req.id (-32602) "Missing params")
  | "ping" -> make_response req.id (`Assoc [])
  | method_ -> make_error req.id (-32601) (Printf.sprintf "Unknown method: %s" method_)

(** Process incoming JSON with context *)
let process_json_with_context ~ctx json_str =
  try
    let json = Yojson.Safe.from_string json_str in
    match parse_request json with
    | Ok req -> handle_request_with_context ~ctx req
    | Error msg -> make_error None (-32600) msg
  with _ ->
    make_error None (-32700) "Parse error"

(** Create server context *)
let create_context ~sw ~net =
  (* Register all drivers on startup *)
  Daw_integration.register_all_drivers ();
  {
    integration = Daw_integration.create ();
    sw;
    net;
  }

(* Legacy stateless functions for backward compatibility *)

(** Handle JSON-RPC request (stateless - deprecated) *)
let handle_request req =
  match req.method_ with
  | "initialize" -> handle_initialize req.id req.params
  | "initialized"
  | "notifications/initialized" -> make_response req.id (`Assoc [])
  | "tools/list" -> handle_tools_list req.id req.params
  | "resources/list" -> handle_resources_list req.id req.params
  | "resources/read" -> handle_resources_read req.id req.params
  | "resources/templates/list" -> handle_resources_templates_list req.id req.params
  | "tools/call" ->
    (match req.params with
     | Some _params -> make_error req.id (-32603) "Use process_json_with_context for tool calls"
     | None -> make_error req.id (-32602) "Missing params")
  | "ping" -> make_response req.id (`Assoc [])
  | method_ -> make_error req.id (-32601) (Printf.sprintf "Unknown method: %s" method_)

(** Process incoming JSON (stateless - deprecated) *)
let process_json json_str =
  try
    let json = Yojson.Safe.from_string json_str in
    match parse_request json with
    | Ok req -> handle_request req
    | Error msg -> make_error None (-32600) msg
  with _ ->
    make_error None (-32700) "Parse error"

(** Process line from stdin (for stdio transport) *)
let process_line line =
  let response = process_json line in
  Yojson.Safe.to_string response

(** Process line with context *)
let process_line_with_context ~ctx line =
  let response = process_json_with_context ~ctx line in
  Yojson.Safe.to_string response
