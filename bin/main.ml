(** DAW MCP - Main entry point

    Pure OCaml MCP server for controlling DAWs via AI.
    Supports stdio and HTTP transports.
*)

open Cmdliner

let version =
  match Build_info.V1.version () with
  | None -> "dev"
  | Some v -> Build_info.V1.Version.to_string v

(** Setup logging *)
let setup_logging level =
  Fmt_tty.setup_std_outputs ();
  Logs.set_level level;
  Logs.set_reporter (Logs_fmt.reporter ())

type jsonrpc_kind =
  [ `Request | `Notification | `Response | `Unknown ]

let classify_jsonrpc_message (body : string) : jsonrpc_kind =
  match Yojson.Safe.from_string body with
  | exception _ -> `Unknown
  | `Assoc fields ->
      let has_method = List.mem_assoc "method" fields in
      let id = List.assoc_opt "id" fields in
      let has_result = List.mem_assoc "result" fields in
      let has_error = List.mem_assoc "error" fields in
      (match has_method, id with
       | true, None
       | true, Some `Null -> `Notification
       | true, Some _ -> `Request
       | false, Some _ when has_result || has_error -> `Response
       | _ -> `Unknown)
  | _ -> `Unknown

(** Run stdio transport - reads JSON-RPC from stdin, writes to stdout *)
let run_stdio () =
  setup_logging (Some Logs.Warning);
  Logs.info (fun m -> m "DAW MCP starting (stdio mode)");

  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let stdin_flow = Eio.Stdenv.stdin env in
  let stdout_flow = Eio.Stdenv.stdout env in

  Eio.Switch.run @@ fun sw ->
  let ctx = Daw_mcp.Mcp_server.create_context ~sw ~net ~clock in
  let buf = Eio.Buf_read.of_flow ~max_size:1_000_000 stdin_flow in

  (* Simple line-by-line processing *)
  try
    while true do
      let line = Eio.Buf_read.line buf in
      if String.length line > 0 then begin
        match classify_jsonrpc_message line with
        | `Notification ->
            ignore (Daw_mcp.Mcp_server.process_line_with_context ~ctx line)
        | `Response ->
            (* Response: ignore for server-only stdio usage *)
            ()
        | `Request | `Unknown ->
            let response = Daw_mcp.Mcp_server.process_line_with_context ~ctx line in
            Eio.Flow.copy_string (response ^ "\n") stdout_flow
      end
    done
  with
  | End_of_file -> Logs.info (fun m -> m "DAW MCP shutting down")
  | Eio.Buf_read.Buffer_limit_exceeded -> Logs.err (fun m -> m "Input too large")

(** Parse HTTP request line into (method, path) *)
let parse_request_line line =
  match String.split_on_char ' ' line with
  | method_ :: path :: _ -> (method_, path)
  | _ -> ("GET", "/")

(** Send SSE event *)
let send_sse_event flow ~event ~data =
  let msg = Printf.sprintf "event: %s\ndata: %s\n\n" event data in
  Eio.Flow.copy_string msg flow

(** SSE client registry for shutdown notification *)
type sse_client = {
  flow: Eio.Flow.sink_ty Eio.Resource.t;
  mutable connected: bool;
}
let sse_clients : (int, sse_client) Hashtbl.t = Hashtbl.create 16
let sse_client_counter = ref 0

let register_sse_client flow =
  incr sse_client_counter;
  let id = !sse_client_counter in
  let client = { flow; connected = true } in
  Hashtbl.add sse_clients id client;
  id

let unregister_sse_client id =
  (match Hashtbl.find_opt sse_clients id with
   | Some c -> c.connected <- false
   | None -> ());
  Hashtbl.remove sse_clients id

let broadcast_sse_shutdown reason =
  let data = Printf.sprintf
    {|{"jsonrpc":"2.0","method":"notifications/shutdown","params":{"reason":"%s","message":"Server is shutting down, please reconnect"}}|}
    reason
  in
  let msg = Printf.sprintf "event: notification\ndata: %s\n\n" data in
  Hashtbl.iter (fun _ client ->
    if client.connected then
      try Eio.Flow.copy_string msg client.flow with _ -> ()
  ) sse_clients

(** Graceful shutdown exception *)
exception Shutdown

(** Run HTTP transport using Eio with SSE support for MCP streamable-http *)
let run_http port =
  setup_logging (Some Logs.Info);
  Logs.info (fun m -> m "DAW MCP starting (HTTP mode on port %d)" port);

  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in

  (* Graceful shutdown setup *)
  let switch_ref = ref None in
  let shutdown_initiated = ref false in
  let initiate_shutdown signal_name =
    if not !shutdown_initiated then begin
      shutdown_initiated := true;
      Logs.info (fun m -> m "DAW MCP: Received %s, shutting down gracefully..." signal_name);

      (* Broadcast shutdown notification to all SSE clients *)
      broadcast_sse_shutdown signal_name;
      Logs.info (fun m -> m "DAW MCP: Sent shutdown notification to %d SSE clients" (Hashtbl.length sse_clients));

      (* Give clients 500ms to receive the notification *)
      Unix.sleepf 0.5;

      match !switch_ref with
      | Some sw -> Eio.Switch.fail sw Shutdown
      | None -> ()
    end
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGTERM"));
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGINT"));

  (try
  Eio.Switch.run @@ fun sw ->
  switch_ref := Some sw;
  let ctx = Daw_mcp.Mcp_server.create_context ~sw ~net ~clock in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true net addr in

  Logs.info (fun m -> m "Listening on http://127.0.0.1:%d" port);
  Logs.info (fun m -> m "  GET /mcp  -> SSE stream (streamable-http)");
  Logs.info (fun m -> m "  POST /mcp -> JSON-RPC requests");
  Logs.info (fun m -> m "  Graceful shutdown: SIGTERM/SIGINT supported");

  (* Accept connections *)
  while true do
    Eio.Net.accept_fork socket ~sw ~on_error:(fun exn ->
      Logs.err (fun m -> m "Connection error: %s" (Printexc.to_string exn))
    ) (fun flow _addr ->
      let buf = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in

      (* Parse request line *)
      let first_line = Eio.Buf_read.line buf in
      let (http_method, path) = parse_request_line first_line in
      Logs.info (fun m -> m "Request: %s %s" http_method path);

      (* Parse headers and extract Content-Length *)
      let content_length = ref 0 in
      let rec parse_headers () =
        let line = Eio.Buf_read.line buf in
        if String.length line > 0 then begin
          let lower = String.lowercase_ascii line in
          if String.length lower > 15 && String.sub lower 0 15 = "content-length:" then begin
            let value_str = String.trim (String.sub line 15 (String.length line - 15)) in
            content_length := int_of_string_opt value_str |> Option.value ~default:0
          end;
          parse_headers ()
        end
      in
      parse_headers ();

      match http_method, path with
      | "GET", "/mcp" ->
        (* SSE stream for MCP streamable-http *)
        Logs.info (fun m -> m "SSE client connected");

        (* Register client for shutdown broadcast *)
        let client_id = register_sse_client (flow :> Eio.Flow.sink_ty Eio.Resource.t) in

        let headers = String.concat "\r\n" [
          "HTTP/1.1 200 OK";
          "Content-Type: text/event-stream";
          "Cache-Control: no-cache";
          "Connection: keep-alive";
          "Access-Control-Allow-Origin: *";
          "\r\n"
        ] in
        Eio.Flow.copy_string headers flow;

        (* Send initial endpoint event (MCP protocol) *)
        send_sse_event flow ~event:"endpoint" ~data:"/mcp";

        (* Keep connection alive with periodic pings *)
        (try
          while true do
            Eio.Time.sleep clock 15.0;
            send_sse_event flow ~event:"ping" ~data:(string_of_float (Unix.gettimeofday ()))
          done
        with _ ->
          unregister_sse_client client_id;
          Logs.info (fun m -> m "SSE client disconnected"))

      | "GET", "/health" ->
        let body = "OK" in
        let headers = Printf.sprintf
          "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: %d\r\n\r\n"
          (String.length body)
        in
        Eio.Flow.copy_string headers flow;
        Eio.Flow.copy_string body flow

      | "POST", "/mcp" | "POST", "/" ->
        (* JSON-RPC request *)
        let body =
          if !content_length > 0 then Eio.Buf_read.take !content_length buf
          else ""
        in
        (match classify_jsonrpc_message body with
         | `Notification ->
             ignore (Daw_mcp.Mcp_server.process_json_with_context ~ctx body);
             let headers = String.concat "\r\n" [
               "HTTP/1.1 202 Accepted";
               "Access-Control-Allow-Origin: *";
               "Content-Length: 0";
               "\r\n"
             ] in
             Eio.Flow.copy_string headers flow
         | `Response ->
             let headers = String.concat "\r\n" [
               "HTTP/1.1 202 Accepted";
               "Access-Control-Allow-Origin: *";
               "Content-Length: 0";
               "\r\n"
             ] in
             Eio.Flow.copy_string headers flow
         | `Request | `Unknown ->
             let response = Daw_mcp.Mcp_server.process_json_with_context ~ctx body in
             let response_body = Yojson.Safe.to_string response in
             let headers = Printf.sprintf
               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: %d\r\n\r\n"
               (String.length response_body)
             in
             Eio.Flow.copy_string headers flow;
             Eio.Flow.copy_string response_body flow)

      | "OPTIONS", _ ->
        (* CORS preflight *)
        let headers = String.concat "\r\n" [
          "HTTP/1.1 204 No Content";
          "Access-Control-Allow-Origin: *";
          "Access-Control-Allow-Methods: GET, POST, OPTIONS";
          "Access-Control-Allow-Headers: Content-Type";
          "\r\n"
        ] in
        Eio.Flow.copy_string headers flow

      | _ ->
        (* 404 *)
        let body = "Not Found" in
        let headers = Printf.sprintf
          "HTTP/1.1 404 Not Found\r\nContent-Length: %d\r\n\r\n" (String.length body)
        in
        Eio.Flow.copy_string headers flow;
        Eio.Flow.copy_string body flow
    )
  done
  with
  | Shutdown ->
      Logs.info (fun m -> m "DAW MCP: Shutdown complete.")
  | Eio.Cancel.Cancelled _ ->
      Logs.info (fun m -> m "DAW MCP: Shutdown complete."))

(** Run Unix socket transport for AU/CLAP plugin IPC *)
let run_socket socket_path =
  setup_logging (Some Logs.Info);
  Logs.info (fun m -> m "DAW MCP starting (Unix socket mode: %s)" socket_path);

  (* Remove old socket file if exists *)
  (try Unix.unlink socket_path with Unix.Unix_error _ -> ());

  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in

  (* Graceful shutdown setup *)
  let switch_ref = ref None in
  let shutdown_initiated = ref false in
  let initiate_shutdown signal_name =
    if not !shutdown_initiated then begin
      shutdown_initiated := true;
      Logs.info (fun m -> m "DAW MCP: Received %s, shutting down gracefully..." signal_name);
      match !switch_ref with
      | Some sw -> Eio.Switch.fail sw Shutdown
      | None -> ()
    end
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGTERM"));
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> initiate_shutdown "SIGINT"));

  (try
  Eio.Switch.run @@ fun sw ->
  switch_ref := Some sw;
  let ctx = Daw_mcp.Mcp_server.create_context ~sw ~net ~clock in
  let addr = `Unix socket_path in
  let socket = Eio.Net.listen ~sw ~backlog:16 ~reuse_addr:true net addr in

  Logs.info (fun m -> m "Listening on %s" socket_path);
  Logs.info (fun m -> m "  Graceful shutdown: SIGTERM/SIGINT supported");

  (* Accept connections *)
  while true do
    Eio.Net.accept_fork socket ~sw ~on_error:(fun exn ->
      Logs.err (fun m -> m "Connection error: %s" (Printexc.to_string exn))
    ) (fun flow _addr ->
      Logs.info (fun m -> m "Plugin connected");
      let buf = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in

      (* Line-by-line JSON-RPC processing *)
      try
        while true do
          let line = Eio.Buf_read.line buf in
          if String.length line > 0 then begin
            let response = Daw_mcp.Mcp_server.process_line_with_context ~ctx line in
            Eio.Flow.copy_string (response ^ "\n") flow
          end
        done
      with
      | End_of_file -> Logs.info (fun m -> m "Plugin disconnected")
      | exn -> Logs.err (fun m -> m "Error: %s" (Printexc.to_string exn))
    )
  done
  with
  | Shutdown ->
      Logs.info (fun m -> m "DAW MCP: Shutdown complete.")
  | Eio.Cancel.Cancelled _ ->
      Logs.info (fun m -> m "DAW MCP: Shutdown complete."))

(** Command-line interface *)
let port_arg =
  let doc = "HTTP port to listen on" in
  Arg.(value & opt (some int) None & info ["p"; "port"] ~docv:"PORT" ~doc)

let socket_arg =
  let doc = "Unix socket path for plugin IPC (e.g., /tmp/daw-bridge.sock)" in
  Arg.(value & opt (some string) None & info ["s"; "socket"] ~docv:"PATH" ~doc)

let verbose_arg =
  let doc = "Enable verbose logging" in
  Arg.(value & flag & info ["v"; "verbose"] ~doc)

let main_cmd port socket verbose =
  if verbose then setup_logging (Some Logs.Debug);
  match socket, port with
  | Some s, _ -> run_socket s
  | None, Some p -> run_http p
  | None, None -> run_stdio ()

let cmd =
  let doc = "DAW MCP Server - Control DAWs via AI" in
  let info = Cmd.info "daw-mcp" ~version ~doc in
  Cmd.v info Term.(const main_cmd $ port_arg $ socket_arg $ verbose_arg)

let () = exit (Cmd.eval cmd)
