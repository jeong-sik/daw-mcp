(** OSC Protocol Tests - Pure OCaml OSC implementation *)

open Osc

(** Test helpers *)
let osc_packet = Alcotest.testable
  (fun fmt p -> Format.pp_print_string fmt (Osc.show_osc_packet p))
  (=)

(** Test OSC string padding *)
let test_string_padding () =
  (* OSC strings are null-terminated and padded to 4-byte boundary *)
  (* "/abc" = 4 chars + 1 null = 5, padded to 8 *)
  (* "," type tag = 1 + 1 null = 2, padded to 4 *)
  (* Total: 8 + 4 = 12 bytes *)
  let msg = message "/abc" [] in
  let data = Serialize.serialize msg in
  Alcotest.(check int) "4-char address" 12 (String.length data);

  (* "/ab" = 3 chars + 1 null = 4, no padding needed *)
  (* "," type tag = 1 + 1 null = 2, padded to 4 *)
  (* Total: 4 + 4 = 8 bytes *)
  let msg2 = message "/ab" [] in
  let data2 = Serialize.serialize msg2 in
  Alcotest.(check int) "3-char address" 8 (String.length data2)

(** Test OSC type tags *)
let test_type_tags () =
  let tag = make_type_tag [Int32 0l; Float32 0.0; String "x"] in
  Alcotest.(check string) "type tag string" ",ifs" tag;

  let tag_empty = make_type_tag [] in
  Alcotest.(check string) "empty type tag" "," tag_empty;

  let tag_bool = make_type_tag [True; False; Nil] in
  Alcotest.(check string) "bool/nil tags" ",TFN" tag_bool

(** Test roundtrip: serialize then parse *)
let test_roundtrip_simple () =
  let original = Message {
    address = "/test/path";
    args = [Int32 42l; Float32 3.14; String "hello"];
  } in
  let data = Serialize.serialize original in
  let parsed = Parse.parse data in
  match parsed with
  | Ok (Message { address; args }) ->
    Alcotest.(check string) "address" "/test/path" address;
    (match args with
     | [Int32 i; Float32 f; String s] ->
       Alcotest.(check int32) "int arg" 42l i;
       Alcotest.(check (float 0.01)) "float arg" 3.14 f;
       Alcotest.(check string) "string arg" "hello" s
     | _ -> Alcotest.fail "wrong args")
  | _ -> Alcotest.fail "parse failed"

(** Test roundtrip with various types *)
let test_roundtrip_types () =
  let original = Message {
    address = "/types";
    args = [
      Int32 (-123l);
      Float32 (-2.5);
      String "";  (* empty string *)
      String "longer string with spaces";
      True;
      False;
      Nil;
    ];
  } in
  let data = Serialize.serialize original in
  let parsed = Parse.parse data in
  Alcotest.(check (result osc_packet string)) "roundtrip types"
    (Ok original) parsed

(** Test Int32 encoding *)
let test_int32_encoding () =
  let msg = Message { address = "/i"; args = [Int32 0x12345678l] } in
  let data = Serialize.serialize msg in
  (* Check big-endian encoding: 0x12 0x34 0x56 0x78 *)
  let arg_start = 8 in  (* after address and type tag *)
  Alcotest.(check int) "int32 byte 0" 0x12 (Char.code data.[arg_start]);
  Alcotest.(check int) "int32 byte 1" 0x34 (Char.code data.[arg_start + 1]);
  Alcotest.(check int) "int32 byte 2" 0x56 (Char.code data.[arg_start + 2]);
  Alcotest.(check int) "int32 byte 3" 0x78 (Char.code data.[arg_start + 3])

(** Test Float32 encoding *)
let test_float32_encoding () =
  let msg = Message { address = "/f"; args = [Float32 1.0] } in
  let data = Serialize.serialize msg in
  let parsed = Parse.parse data in
  match parsed with
  | Ok (Message { args = [Float32 v]; _ }) ->
    Alcotest.(check (float 0.0001)) "float32 value" 1.0 v
  | _ ->
    Alcotest.fail "failed to parse float32"

(** Test negative numbers *)
let test_negative_numbers () =
  let msg = Message {
    address = "/neg";
    args = [Int32 (-1l); Float32 (-99.5)];
  } in
  let data = Serialize.serialize msg in
  let parsed = Parse.parse data in
  match parsed with
  | Ok (Message { args = [Int32 i; Float32 f]; _ }) ->
    Alcotest.(check int32) "negative int32" (-1l) i;
    Alcotest.(check (float 0.001)) "negative float32" (-99.5) f
  | _ ->
    Alcotest.fail "failed to parse negative numbers"

(** Test bundle *)
let test_bundle () =
  let msg1 = Message { address = "/a"; args = [Int32 1l] } in
  let msg2 = Message { address = "/b"; args = [Int32 2l] } in
  let bundle = Bundle {
    timetag = timetag_immediately;
    elements = [msg1; msg2];
  } in
  let data = Serialize.serialize bundle in

  (* Check bundle header *)
  Alcotest.(check string) "bundle header" "#bundle\x00"
    (String.sub data 0 8);

  (* Roundtrip *)
  let parsed = Parse.parse data in
  Alcotest.(check (result osc_packet string)) "bundle roundtrip"
    (Ok bundle) parsed

(** Test blob type *)
let test_blob () =
  let blob_data = Bytes.of_string "\x01\x02\x03\x04\x05" in
  let msg = Message {
    address = "/blob";
    args = [Blob blob_data];
  } in
  let data = Serialize.serialize msg in
  let parsed = Parse.parse data in
  match parsed with
  | Ok (Message { args = [Blob b]; _ }) ->
    Alcotest.(check bytes) "blob content" blob_data b
  | _ ->
    Alcotest.fail "failed to parse blob"

(** Test Reaper-style addresses *)
let test_reaper_addresses () =
  let addresses = [
    "/play";
    "/stop";
    "/track/1/volume";
    "/track/1/mute";
    "/tempo/raw";
    "/action/40044";
  ] in
  List.iter (fun addr ->
    let msg = Message { address = addr; args = [Float32 1.0] } in
    let data = Serialize.serialize msg in
    match Parse.parse data with
    | Ok (Message { address = a; _ }) ->
      Alcotest.(check string) ("address " ^ addr) addr a
    | _ ->
      Alcotest.fail ("failed to roundtrip " ^ addr)
  ) addresses

(** Test invalid input *)
let test_invalid_input () =
  (* Empty input *)
  let result = Parse.parse "" in
  Alcotest.(check bool) "empty fails" true (Result.is_error result);

  (* Invalid start character *)
  let result2 = Parse.parse "not/osc" in
  Alcotest.(check bool) "invalid start fails" true (Result.is_error result2)

(** All tests *)
let () =
  Alcotest.run "OSC" [
    "padding", [
      Alcotest.test_case "string padding" `Quick test_string_padding;
    ];
    "type_tags", [
      Alcotest.test_case "type tag generation" `Quick test_type_tags;
    ];
    "roundtrip", [
      Alcotest.test_case "simple message" `Quick test_roundtrip_simple;
      Alcotest.test_case "various types" `Quick test_roundtrip_types;
    ];
    "encoding", [
      Alcotest.test_case "int32 big-endian" `Quick test_int32_encoding;
      Alcotest.test_case "float32" `Quick test_float32_encoding;
      Alcotest.test_case "negative numbers" `Quick test_negative_numbers;
    ];
    "bundle", [
      Alcotest.test_case "bundle roundtrip" `Quick test_bundle;
    ];
    "blob", [
      Alcotest.test_case "blob roundtrip" `Quick test_blob;
    ];
    "reaper", [
      Alcotest.test_case "reaper addresses" `Quick test_reaper_addresses;
    ];
    "errors", [
      Alcotest.test_case "invalid input" `Quick test_invalid_input;
    ];
  ]
