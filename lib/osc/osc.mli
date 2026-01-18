(** OSC - Pure OCaml Open Sound Control implementation

    This module provides a complete OSC 1.0 implementation in pure OCaml,
    using Angstrom for parsing and Faraday for serialization.
*)

(** {1 Types} *)

(** OSC argument types *)
type osc_arg =
  | Int32 of int32
  | Float32 of float
  | String of string
  | Blob of bytes
  | Int64 of int64
  | Timetag of int64
  | Double of float
  | Char of char
  | Color of int32
  | Midi of bytes
  | True
  | False
  | Nil
  | Infinitum

(** OSC message: address pattern + arguments *)
type osc_message = {
  address : string;
  args : osc_arg list;
}

(** OSC bundle: timetag + elements *)
type osc_bundle = {
  timetag : int64;
  elements : osc_packet list;
}

(** OSC packet: message or bundle *)
and osc_packet =
  | Message of osc_message
  | Bundle of osc_bundle

(** Show function for debugging *)
val show_osc_packet : osc_packet -> string

(** {1 Constants} *)

(** Timetag for immediate execution *)
val timetag_immediately : int64

(** {1 Constructors} *)

(** Create a message packet *)
val message : string -> osc_arg list -> osc_packet

(** Create a bundle for immediate execution *)
val bundle_now : osc_packet list -> osc_packet

(** Generate type tag string from arguments *)
val make_type_tag : osc_arg list -> string

(** {1 Parsing} *)

module Parse : sig
  (** Parse OSC binary data to packet *)
  val parse : string -> (osc_packet, string) result

  (** Parse from Cstruct *)
  val parse_cstruct : Cstruct.t -> (osc_packet, string) result
end

(** {1 Serialization} *)

module Serialize : sig
  (** Serialize packet to string *)
  val serialize : osc_packet -> string

  (** Serialize to bytes *)
  val serialize_bytes : osc_packet -> bytes

  (** Serialize to Cstruct *)
  val serialize_cstruct : osc_packet -> Cstruct.t

  (** Serialize message directly *)
  val serialize_message : string -> osc_arg list -> string
end

(** {1 Transport} *)

module Transport : sig
  (** OSC UDP client *)
  type t

  (** Create client connected to remote host:port *)
  val create : sw:Eio.Switch.t -> net:_ Eio.Net.t -> host:string -> port:int -> t

  (** Send OSC packet *)
  val send : t -> osc_packet -> unit

  (** Send message *)
  val send_message : t -> string -> osc_arg list -> unit

  (** Send bundle *)
  val send_bundle : t -> osc_packet list -> unit

  (** Set receive callback *)
  val on_receive : t -> (osc_packet -> unit) -> unit

  (** Start receive loop in background fiber *)
  val start_receiving : sw:Eio.Switch.t -> t -> unit

  (** Close connection *)
  val close : t -> unit

  (** Common OSC addresses for DAWs *)
  module Addr : sig
    val reaper_play : string
    val reaper_stop : string
    val reaper_record : string
    val reaper_pause : string
    val reaper_tempo : string
    val reaper_track : int -> string
    val reaper_track_volume : int -> string
    val reaper_track_pan : int -> string
    val reaper_track_mute : int -> string
    val reaper_track_solo : int -> string
    val reaper_track_arm : int -> string
    val reaper_track_select : int -> string
  end
end

(** {1 Convenience} *)

(** Send a one-shot message *)
val send_message : sw:Eio.Switch.t -> net:_ Eio.Net.t ->
  host:string -> port:int -> string -> osc_arg list -> unit

(** Parse string to packet *)
val parse : string -> (osc_packet, string) result

(** Serialize packet to string *)
val serialize : osc_packet -> string
