(** OSC Parser - Pure OCaml using Angstrom

    Parses OSC 1.0 binary format to OCaml types.
    All data is big-endian and aligned to 4-byte boundaries.
*)

open Angstrom
open Osc_types

(** Parse 4 bytes as big-endian int32 *)
let be_int32 =
  take 4 >>| fun s ->
  let b0 = Char.code s.[0] in
  let b1 = Char.code s.[1] in
  let b2 = Char.code s.[2] in
  let b3 = Char.code s.[3] in
  Int32.(add (shift_left (of_int b0) 24)
    (add (shift_left (of_int b1) 16)
      (add (shift_left (of_int b2) 8)
        (of_int b3))))

(** Parse 8 bytes as big-endian int64 *)
let be_int64 =
  take 8 >>| fun s ->
  let result = ref 0L in
  for i = 0 to 7 do
    result := Int64.(add (shift_left !result 8) (of_int (Char.code s.[i])))
  done;
  !result

(** Parse 4 bytes as big-endian float32 *)
let be_float32 =
  be_int32 >>| Int32.float_of_bits

(** Parse 8 bytes as big-endian float64 *)
let be_float64 =
  be_int64 >>| Int64.float_of_bits

(** Parse null-terminated string, padded to 4 bytes *)
let osc_string =
  take_while (fun c -> c <> '\x00') >>= fun s ->
  let total_len = String.length s + 1 in  (* +1 for null terminator *)
  let padding = padding_for total_len in
  take (1 + padding) >>| fun _ -> s  (* consume null + padding *)

(** Parse blob: int32 size + data + padding *)
let osc_blob =
  be_int32 >>= fun size ->
  let size = Int32.to_int size in
  take size >>= fun data ->
  let padding = padding_for size in
  take padding >>| fun _ -> Bytes.of_string data

(** Parse single OSC argument by type tag *)
let parse_arg = function
  | 'i' -> be_int32 >>| fun v -> Int32 v
  | 'f' -> be_float32 >>| fun v -> Float32 v
  | 's' -> osc_string >>| fun v -> String v
  | 'b' -> osc_blob >>| fun v -> Blob v
  | 'h' -> be_int64 >>| fun v -> Int64 v
  | 't' -> be_int64 >>| fun v -> Timetag v
  | 'd' -> be_float64 >>| fun v -> Double v
  | 'c' -> be_int32 >>| fun v -> Char (Char.chr (Int32.to_int v land 0xFF))
  | 'r' -> be_int32 >>| fun v -> Color v
  | 'm' -> take 4 >>| fun v -> Midi (Bytes.of_string v)
  | 'T' -> return True
  | 'F' -> return False
  | 'N' -> return Nil
  | 'I' -> return Infinitum
  | c -> fail (Printf.sprintf "Unknown OSC type tag: %c" c)

(** Parse arguments according to type tag string (without leading ',') *)
let parse_args type_tags =
  let tags = String.to_seq type_tags |> List.of_seq in
  let rec go acc = function
    | [] -> return (List.rev acc)
    | tag :: rest ->
      parse_arg tag >>= fun arg ->
      go (arg :: acc) rest
  in
  go [] tags

(** Parse OSC message *)
let osc_message_parser =
  osc_string >>= fun address ->
  osc_string >>= fun type_tag ->
  (* Type tag starts with ',' *)
  let tags = if String.length type_tag > 0 && type_tag.[0] = ','
             then String.sub type_tag 1 (String.length type_tag - 1)
             else type_tag in
  parse_args tags >>| fun args ->
  { address; args }

(** Bundle header: "#bundle\x00" *)
let bundle_header = string "#bundle\x00"

(** Forward declaration for recursive parsing *)
let osc_packet_parser : osc_packet Angstrom.t ref = ref (return (Message { address = ""; args = [] }))

(** Parse bundle element (size + content) *)
let bundle_element =
  be_int32 >>= fun size ->
  take (Int32.to_int size) >>= fun content ->
  match parse_string ~consume:All !osc_packet_parser content with
  | Ok packet -> return packet
  | Error msg -> fail msg

(** Parse OSC bundle *)
let osc_bundle_parser =
  bundle_header *>
  be_int64 >>= fun timetag ->
  many bundle_element >>| fun elements ->
  { timetag; elements }

(** Parse OSC packet (message or bundle) *)
let parse_packet =
  peek_char >>= function
  | Some '#' -> osc_bundle_parser >>| fun b -> Bundle b
  | Some '/' -> osc_message_parser >>| fun m -> Message m
  | Some c -> fail (Printf.sprintf "Invalid OSC packet start: %c" c)
  | None -> fail "Empty OSC packet"

(* Initialize forward reference *)
let () = osc_packet_parser := parse_packet

(** Main entry point: parse bytes to OSC packet *)
let parse data =
  parse_string ~consume:All parse_packet data

(** Parse from Cstruct *)
let parse_cstruct cs =
  parse (Cstruct.to_string cs)
