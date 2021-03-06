open Parsifal
open BasePTypes

(* Varint *)

type varint = int

(* TODO: This version does handle signed var ints *)
(* let varint_of_bytelist bytes h = *)
(*   let rec add_bytes accu = function *)
(*     | [] -> accu *)
(*     | x::r -> add_bytes ((accu lsl 7) lor x) r *)
(*   in *)
(*   if (List.length bytes) > 4 *)
(*   then raise (ParsingException (NotImplemented "parse_varint on more than 4 bytes", h)); *)
(*   let base = match bytes with *)
(*     | [] -> 0 *)
(*     | x::_ -> *)
(*       if (x land 0x40) == 0 then 0 else -1 *)
(*   in add_bytes base bytes *)

let varint_of_bytelist bytes h =
  let rec add_bytes accu = function
    | [] -> accu
    | x::r -> add_bytes ((accu lsl 7) lor x) r
  in
  if (List.length bytes) > 4
  then raise (ParsingException (NotImplemented "parse_varint on more than 4 bytes", h));
  add_bytes 0 bytes

let parse_varint input =
  let rec parse_bytelist accu input =
    let b = parse_byte input in
    if (b land 0x80) == 0
    then b::accu
    else parse_bytelist ((b land 0x7f)::accu) input
  in
  let bytes = parse_bytelist [] input in
  varint_of_bytelist bytes (_h_of_si input)

let dump_varint (_buf : POutput.t) (_i : int) = not_implemented "dump_varint"

let value_of_varint i = VInt i


(* Protobuf key *)

enum wire_type (3, Exception) =
  | 0 -> WT_Varint, "Varint"
  | 1 -> WT_Fixed64bit, "Fixed64bit"
  | 2 -> WT_LengthDelimited, "LengthDelimited"
  | 3 -> WT_StartGroup, "StartGroup"
  | 4 -> WT_EndGroup, "EndGroup"
  | 5 -> WT_Fixed32bit, "Fixed32bit"

type protobuf_key = wire_type * int

let parse_protobuf_key input =
  let x = parse_varint input in
  (wire_type_of_int (x land 7), x lsr 3)

let dump_protobuf_key buf (wt, fn) =
  dump_varint buf ((fn lsl 3) lor (int_of_wire_type wt))

let string_of_protobuf_key (wt, fn) =
  Printf.sprintf "(%s, %d)" (string_of_wire_type wt) fn

let value_of_protobuf_key (wt, fn) =
  VRecord [
    "@name", VString ("protobuf_key", false);
    "@string_of", VString (string_of_protobuf_key (wt, fn), false);
    "wire_type", value_of_wire_type wt;
    "field_number", VInt fn
  ]


(* Length defined stuff *)

type 'a length_delimited_container = 'a

let parse_length_delimited_container name parse_fun input =
  let len = parse_varint input in
  parse_container len name parse_fun input

let dump_length_delimited_container dump_fun buf v =
  dump_varlen_container dump_varint dump_fun buf v

let value_of_length_delimited_container = value_of_container


(* Protobuf value *)

alias bothstring = binstring
let string_of_bothstring s =
  Printf.sprintf "%s (%s)" (hexdump s) (quote_string s)

union protobuf_value [enrich; exhaustive] (Unparsed_Protobuf) =
  | WT_Varint, _ -> Varint of varint
  | WT_Fixed64bit, _ -> Fixed64bit of binstring(8)
  | WT_LengthDelimited, _ -> LengthDelimited of (length_delimited_container of bothstring)
  | WT_StartGroup, _ -> StartGroup
  | WT_EndGroup, _ -> EndGroup
  | WT_Fixed32bit, _ -> Fixed32bit of uint32




(* Simple Protobuf key/value *)

struct protobuf [top] = {
  key : protobuf_key;
  value : protobuf_value (key)
}



(* Recursive parsing *)

type rec_protobuf_value =
  | R_Varint of varint
  | R_Fixed64bit of string
  | R_String of string
  | R_List of rec_protobuf list
  | R_StartGroup
  | R_EndGroup
  | R_Fixed32bit of int

and rec_protobuf = int * rec_protobuf_value

let rec parse_rec_protobuf input =
  let protobuf = parse_protobuf input in
  let v = match protobuf.value with
    | Varint i -> R_Varint i
    | Fixed64bit s -> R_Fixed64bit s
    | LengthDelimited s -> begin
      let new_input = input_of_string ("Field number " ^ (string_of_int (snd protobuf.key))) s in
      try R_List (parse_rem_list "Protobuf field" parse_rec_protobuf new_input)
      with _ -> R_String s
    end
    | StartGroup -> R_StartGroup
    | EndGroup -> R_EndGroup
    | Fixed32bit i -> R_Fixed32bit i
    | Unparsed_Protobuf _ ->
      raise (ParsingException (CustomException "parse_rec_protobuf on Unparsed_Protobuf", _h_of_si input))
  in (snd protobuf.key, v)


let rec print_rec_protobuf ?indent:(indent="") (num, value) =
  let default_fun t v =
    Printf.sprintf "%s%s_%s: %s\n" indent t (string_of_int num) (string_of_value (value_of_protobuf_value v))
  in
  match value with
  | R_Varint i -> default_fun "Varint" (Varint i)
  | R_Fixed64bit s -> default_fun "Fixed64bit" (Fixed64bit s)
  | R_String s -> default_fun "String" (LengthDelimited s)
  | R_List l ->
    (Printf.sprintf "%sSeq_%d {\n" indent num) ^
      (String.concat "" (List.map (fun x -> print_rec_protobuf ~indent:(indent ^ "  ") x) l)) ^
      (Printf.sprintf "%s}\n" indent)
  | R_StartGroup -> default_fun "StartGroup" StartGroup
  | R_EndGroup -> default_fun "StartGroup" EndGroup
  | R_Fixed32bit i -> default_fun "Fixed32bit" (Fixed32bit i)
