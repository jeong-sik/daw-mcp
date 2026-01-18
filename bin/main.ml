(** DAW MCP - Main entry point

    Pure OCaml MCP server for controlling DAWs via AI.
    Supports stdio and HTTP transports.
*)

open Cmdliner

(** Setup logging *)
let setup_logging level =
  Fmt_tty.setup_std_outputs ();
  Logs.set_level level;
  Logs.set_reporter (Logs_fmt.reporter ())

(** Run stdio transport - reads JSON-RPC from stdin, writes to stdout *)
let run_stdio () =
  setup_logging (Some Logs.Warning);
  Logs.info (fun m -> m "DAW MCP starting (stdio mode)");

  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let stdin_flow = Eio.Stdenv.stdin env in
  let stdout_flow = Eio.Stdenv.stdout env in

  Eio.Switch.run @@ fun sw ->
  let ctx = Daw_mcp.Mcp_server.create_context ~sw ~net in
  let buf = Eio.Buf_read.of_flow ~max_size:1_000_000 stdin_flow in

  (* Simple line-by-line processing *)
  try
    while true do
      let line = Eio.Buf_read.line buf in
      if String.length line > 0 then begin
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

(** Run HTTP transport using Eio with SSE support for MCP streamable-http *)
let run_http port =
  setup_logging (Some Logs.Info);
  Logs.info (fun m -> m "DAW MCP starting (HTTP mode on port %d)" port);

  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in

  Eio.Switch.run @@ fun sw ->
  let ctx = Daw_mcp.Mcp_server.create_context ~sw ~net in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true net addr in

  Logs.info (fun m -> m "Listening on http://127.0.0.1:%d" port);
  Logs.info (fun m -> m "  GET /mcp  -> SSE stream (streamable-http)");
  Logs.info (fun m -> m "  POST /mcp -> JSON-RPC requests");

  (* Accept connections *)
  while true do
    Eio.Net.accept_fork socket ~sw ~on_error:(fun exn ->
      Logs.err (fun m -> m "Connection error: %s" (Printexc.to_string exn))
    ) (fun flow _addr ->
      let buf = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in

      (* Parse request line *)
      let first_line = Eio.Buf_read.line buf in
      let (http_method, path) = parse_request_line first_line in

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
        with _ -> Logs.info (fun m -> m "SSE client disconnected"))

      | "POST", "/mcp" | "POST", "/" ->
        (* JSON-RPC request *)
        let body =
          if !content_length > 0 then Eio.Buf_read.take !content_length buf
          else ""
        in
        let response = Daw_mcp.Mcp_server.process_json_with_context ~ctx body in
        let response_body = Yojson.Safe.to_string response in
        let headers = Printf.sprintf
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: %d\r\n\r\n"
          (String.length response_body)
        in
        Eio.Flow.copy_string headers flow;
        Eio.Flow.copy_string response_body flow

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

(** Run Unix socket transport for AU/CLAP plugin IPC *)
let run_socket socket_path =
  setup_logging (Some Logs.Info);
  Logs.info (fun m -> m "DAW MCP starting (Unix socket mode: %s)" socket_path);

  (* Remove old socket file if exists *)
  (try Unix.unlink socket_path with Unix.Unix_error _ -> ());

  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in

  Eio.Switch.run @@ fun sw ->
  let ctx = Daw_mcp.Mcp_server.create_context ~sw ~net in
  let addr = `Unix socket_path in
  let socket = Eio.Net.listen ~sw ~backlog:16 ~reuse_addr:true net addr in

  Logs.info (fun m -> m "Listening on %s" socket_path);

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
  let info = Cmd.info "daw-mcp" ~version:"0.1.0" ~doc in
  Cmd.v info Term.(const main_cmd $ port_arg $ socket_arg $ verbose_arg)

let () = exit (Cmd.eval cmd)
