(** OSC Types - Open Sound Control message types (Pure OCaml)

    OSC 1.0 Spec: http://opensoundcontrol.org/spec-1_0

    OSC messages consist of:
    - Address pattern (string starting with '/')
    - Type tag string (starting with ',')
    - Arguments (aligned to 4-byte boundaries)
*)

(** OSC argument types *)
type osc_arg =
  | Int32 of int32           (** 'i' - 32-bit big-endian two's complement int *)
  | Float32 of float         (** 'f' - 32-bit big-endian IEEE 754 float *)
  | String of string         (** 's' - null-terminated, padded to 4 bytes *)
  | Blob of bytes            (** 'b' - int32 size + data, padded to 4 bytes *)
  | Int64 of int64           (** 'h' - 64-bit big-endian int *)
  | Timetag of int64         (** 't' - NTP timestamp (64-bit) *)
  | Double of float          (** 'd' - 64-bit big-endian float *)
  | Char of char             (** 'c' - ASCII character in 32-bit int *)
  | Color of int32           (** 'r' - RGBA color *)
  | Midi of bytes            (** 'm' - 4 bytes MIDI message *)
  | True                     (** 'T' - no data *)
  | False                    (** 'F' - no data *)
  | Nil                      (** 'N' - no data *)
  | Infinitum                (** 'I' - no data *)
[@@deriving show { with_path = false }]

(** OSC message: address pattern + arguments *)
type osc_message = {
  address : string;
  args : osc_arg list;
}
[@@deriving show { with_path = false }]

(** OSC timetag constants *)
let timetag_immediately = 1L  (* NTP: Jan 1, 1900 + 1 second *)

(** OSC bundle: timetag + elements (messages or nested bundles) *)
type osc_bundle = {
  timetag : int64;
  elements : osc_packet list;
}
[@@deriving show { with_path = false }]

(** An OSC packet is either a message or a bundle *)
and osc_packet =
  | Message of osc_message
  | Bundle of osc_bundle
[@@deriving show { with_path = false }]

(** Type tag character for each argument type *)
let type_tag_of_arg = function
  | Int32 _ -> 'i'
  | Float32 _ -> 'f'
  | String _ -> 's'
  | Blob _ -> 'b'
  | Int64 _ -> 'h'
  | Timetag _ -> 't'
  | Double _ -> 'd'
  | Char _ -> 'c'
  | Color _ -> 'r'
  | Midi _ -> 'm'
  | True -> 'T'
  | False -> 'F'
  | Nil -> 'N'
  | Infinitum -> 'I'

(** Generate type tag string from arguments *)
let make_type_tag args =
  let tags = List.map type_tag_of_arg args in
  String.init (List.length tags + 1) (function
    | 0 -> ','
    | n -> List.nth tags (n - 1))

(** Helper: pad size to 4-byte boundary *)
let pad4 n =
  let rem = n mod 4 in
  if rem = 0 then n else n + (4 - rem)

(** Helper: padding bytes needed *)
let padding_for n =
  let rem = n mod 4 in
  if rem = 0 then 0 else 4 - rem

(** Create a simple message with string/float/int args *)
let message address args = Message { address; args }

(** Create a bundle with immediate execution *)
let bundle_now elements = Bundle { timetag = timetag_immediately; elements }
