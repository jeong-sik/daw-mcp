(** OSC Transport - UDP socket using Eio

    Sends and receives OSC packets over UDP using Eio direct-style I/O.
*)

open Osc_types

(** OSC client for sending messages *)
type 'a client = {
  socket : 'a Eio.Net.datagram_socket;
  remote_addr : Eio.Net.Sockaddr.datagram;
  mutable receive_handler : (osc_packet -> unit) option;
}

(** Existential wrapper for client *)
type t = Client : 'a client -> t

(** Create OSC client connected to remote host:port *)
let create ~sw ~net ~host ~port =
  let socket = Eio.Net.datagram_socket ~sw net `UdpV4 in
  (* Get address info for the host - returns first result *)
  let addrs = Eio.Net.getaddrinfo_datagram ~service:(string_of_int port) net host in
  let remote_addr = match addrs with
    | addr :: _ -> addr
    | [] -> failwith ("Could not resolve host: " ^ host)
  in
  Client { socket; remote_addr; receive_handler = None }

(** Send OSC packet *)
let send (Client t) packet =
  let data = Osc_serialize.serialize packet in
  let buf = Cstruct.of_string data in
  Eio.Net.send t.socket ~dst:t.remote_addr [buf]

(** Send OSC message (convenience) *)
let send_message t address args =
  send t (Message { address; args })

(** Send multiple messages as bundle *)
let send_bundle t packets =
  send t (Bundle { timetag = timetag_immediately; elements = packets })

(** Set receive handler *)
let on_receive (Client t) handler =
  t.receive_handler <- Some handler

(** Receive loop - call in a fiber *)
let receive_loop (Client t) =
  let buf = Cstruct.create 65536 in  (* Max UDP packet size *)
  while true do
    let addr, len = Eio.Net.recv t.socket buf in
    ignore addr;
    let data = Cstruct.sub buf 0 len |> Cstruct.to_string in
    match Osc_parse.parse data with
    | Ok packet ->
      (match t.receive_handler with
       | Some handler -> handler packet
       | None -> ())
    | Error msg ->
      Logs.warn (fun m -> m "OSC parse error: %s" msg)
  done

(** Start receiving in background fiber *)
let start_receiving ~sw t =
  Eio.Fiber.fork ~sw (fun () -> receive_loop t)

(** Close connection *)
let close (Client t) =
  Eio.Net.close t.socket

(** Common OSC addresses for DAWs *)
module Addr = struct
  (* Reaper OSC addresses *)
  let reaper_play = "/play"
  let reaper_stop = "/stop"
  let reaper_record = "/record"
  let reaper_pause = "/pause"
  let reaper_rewind = "/rewind"
  let reaper_forward = "/forward"
  let reaper_goto = "/time"
  let reaper_tempo = "/tempo/raw"
  let reaper_track n = Printf.sprintf "/track/%d" n
  let reaper_track_volume n = Printf.sprintf "/track/%d/volume" n
  let reaper_track_pan n = Printf.sprintf "/track/%d/pan" n
  let reaper_track_mute n = Printf.sprintf "/track/%d/mute" n
  let reaper_track_solo n = Printf.sprintf "/track/%d/solo" n
  let reaper_track_arm n = Printf.sprintf "/track/%d/recarm" n
  let reaper_track_select n = Printf.sprintf "/track/%d/select" n

  (* Ableton OSC addresses (via LiveOSC or similar) *)
  let ableton_play = "/live/play"
  let ableton_stop = "/live/stop"
  let ableton_tempo = "/live/tempo"
  let ableton_track_volume n = Printf.sprintf "/live/track/%d/volume" n
  let ableton_track_mute n = Printf.sprintf "/live/track/%d/mute" n
end
