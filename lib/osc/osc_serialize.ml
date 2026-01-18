(** OSC Serializer - Pure OCaml using Faraday

    Serializes OCaml types to OSC 1.0 binary format.
    All data is big-endian and aligned to 4-byte boundaries.
*)

open Faraday
open Osc_types

(** Write big-endian int32 *)
let write_be_int32 t v =
  write_uint8 t (Int32.to_int (Int32.shift_right_logical v 24) land 0xFF);
  write_uint8 t (Int32.to_int (Int32.shift_right_logical v 16) land 0xFF);
  write_uint8 t (Int32.to_int (Int32.shift_right_logical v 8) land 0xFF);
  write_uint8 t (Int32.to_int v land 0xFF)

(** Write big-endian int64 *)
let write_be_int64 t v =
  for i = 7 downto 0 do
    write_uint8 t (Int64.to_int (Int64.shift_right_logical v (i * 8)) land 0xFF)
  done

(** Write big-endian float32 *)
let write_be_float32 t v =
  write_be_int32 t (Int32.bits_of_float v)

(** Write big-endian float64 *)
let write_be_float64 t v =
  write_be_int64 t (Int64.bits_of_float v)

(** Write null-terminated string, padded to 4 bytes *)
let write_osc_string t s =
  write_string t s;
  write_uint8 t 0;  (* null terminator *)
  let total = String.length s + 1 in
  let padding = padding_for total in
  for _ = 1 to padding do
    write_uint8 t 0
  done

(** Write blob: int32 size + data + padding *)
let write_osc_blob t b =
  let len = Bytes.length b in
  write_be_int32 t (Int32.of_int len);
  write_bytes t b;
  let padding = padding_for len in
  for _ = 1 to padding do
    write_uint8 t 0
  done

(** Write single OSC argument *)
let write_arg t = function
  | Int32 v -> write_be_int32 t v
  | Float32 v -> write_be_float32 t v
  | String v -> write_osc_string t v
  | Blob v -> write_osc_blob t v
  | Int64 v -> write_be_int64 t v
  | Timetag v -> write_be_int64 t v
  | Double v -> write_be_float64 t v
  | Char c -> write_be_int32 t (Int32.of_int (Char.code c))
  | Color v -> write_be_int32 t v
  | Midi v -> write_bytes t v
  | True | False | Nil | Infinitum -> ()  (* No data for these types *)

(** Write OSC message *)
let write_message t { address; args } =
  write_osc_string t address;
  write_osc_string t (make_type_tag args);
  List.iter (write_arg t) args

(** Forward declaration for recursive serialization *)
let rec write_packet t = function
  | Message msg -> write_message t msg
  | Bundle bundle -> write_bundle t bundle

(** Write bundle element with size prefix *)
and write_bundle_element t packet =
  (* First serialize to get size *)
  let inner = create 256 in
  write_packet inner packet;
  let data = serialize_to_string inner in
  write_be_int32 t (Int32.of_int (String.length data));
  write_string t data

(** Write OSC bundle *)
and write_bundle t { timetag; elements } =
  write_string t "#bundle\x00";
  write_be_int64 t timetag;
  List.iter (write_bundle_element t) elements

(** Main entry point: serialize OSC packet to string *)
let serialize packet =
  let t = create 256 in
  write_packet t packet;
  serialize_to_string t

(** Serialize to bytes *)
let serialize_bytes packet =
  Bytes.of_string (serialize packet)

(** Serialize to Cstruct *)
let serialize_cstruct packet =
  Cstruct.of_string (serialize packet)

(** Convenience: serialize message directly *)
let serialize_message address args =
  serialize (Message { address; args })
