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

(** Run HTTP transport using Eio *)
let run_http port =
  setup_logging (Some Logs.Info);
  Logs.info (fun m -> m "DAW MCP starting (HTTP mode on port %d)" port);

  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in

  Eio.Switch.run @@ fun sw ->
  let ctx = Daw_mcp.Mcp_server.create_context ~sw ~net in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true net addr in

  Logs.info (fun m -> m "Listening on http://127.0.0.1:%d" port);

  (* Accept connections *)
  while true do
    Eio.Net.accept_fork socket ~sw ~on_error:(fun exn ->
      Logs.err (fun m -> m "Connection error: %s" (Printexc.to_string exn))
    ) (fun flow _addr ->
      (* Read HTTP request with proper Content-Length handling *)
      let buf = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in

      (* Parse headers and extract Content-Length *)
      let content_length = ref 0 in
      let rec parse_headers () =
        let line = Eio.Buf_read.line buf in
        if String.length line > 0 then begin
          (* Parse Content-Length header (case-insensitive) *)
          let lower = String.lowercase_ascii line in
          if String.length lower > 15 && String.sub lower 0 15 = "content-length:" then begin
            let value_str = String.trim (String.sub line 15 (String.length line - 15)) in
            content_length := int_of_string_opt value_str |> Option.value ~default:0
          end;
          parse_headers ()
        end
      in

      (* Read first line (method/path) *)
      let first_line = Eio.Buf_read.line buf in
      ignore first_line;  (* POST / HTTP/1.1 *)

      parse_headers ();

      (* Read exactly Content-Length bytes *)
      let body =
        if !content_length > 0 then
          Eio.Buf_read.take !content_length buf
        else
          ""
      in

      (* Process JSON-RPC with context *)
      let response = Daw_mcp.Mcp_server.process_json_with_context ~ctx body in
      let response_body = Yojson.Safe.to_string response in

      (* Send HTTP response *)
      let headers = Printf.sprintf
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n"
        (String.length response_body)
      in
      Eio.Flow.copy_string headers flow;
      Eio.Flow.copy_string response_body flow
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
  let info = Cmd.info "daw-mcp" ~version:"0.1.1" ~doc in
  Cmd.v info Term.(const main_cmd $ port_arg $ socket_arg $ verbose_arg)

let () = exit (Cmd.eval cmd)
