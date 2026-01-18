(** OSC - Pure OCaml Open Sound Control implementation

    Re-exports all OSC modules for convenient access.
*)

(** OSC types: messages, bundles, arguments *)
include Osc_types

(** Re-export show function *)
let show_osc_packet = Osc_types.show_osc_packet

(** Parse OSC binary data to OCaml types *)
module Parse = Osc_parse

(** Serialize OCaml types to OSC binary data *)
module Serialize = Osc_serialize

(** UDP transport using Eio *)
module Transport = Osc_transport

(** Convenience: create and send message in one call *)
let send_message ~sw ~net ~host ~port address args =
  let t = Transport.create ~sw ~net ~host ~port in
  Transport.send_message t address args;
  Transport.close t

(** Convenience: parse string to packet *)
let parse = Parse.parse

(** Convenience: serialize packet to string *)
let serialize = Serialize.serialize
