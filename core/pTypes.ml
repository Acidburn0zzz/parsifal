open Parsifal
open BasePTypes
open Lwt


(* IPv4 and IPv6 *)

type ipv4 = string

let parse_ipv4 = parse_string 4
let lwt_parse_ipv4 = lwt_parse_string 4

let dump_ipv4 ipv4 = ipv4

let string_of_ipv4 s =
  let elts = [s.[0]; s.[1]; s.[2]; s.[3]] in
  String.concat "." (List.map (fun e -> string_of_int (int_of_char e)) elts)

let print_ipv4 ?indent:(indent="") ?name:(name="ipv4") s =
  let res = string_of_ipv4 s in
  Printf.sprintf "%s%s: %s\n" indent name res

let get_ipv4 = trivial_get dump_ipv4 string_of_ipv4


type ipv6 = string

let parse_ipv6 = parse_string 16
let lwt_parse_ipv6 = lwt_parse_string 16

let dump_ipv6 ipv6 = ipv6

(* TODO: Compress it! *)
let string_of_ipv6 s =
  let res = String.make 39 ':' in
  for i = 0 to 15 do
    let x = int_of_char (String.get s i) in
    res.[(i / 2) + i * 2] <- hexa_char.[(x lsr 4) land 0xf];
    res.[(i / 2) + i * 2 + 1] <- hexa_char.[x land 0xf];
  done;
  res

let print_ipv6 ?indent:(indent="") ?name:(name="ipv6") s =
  let res = string_of_ipv6 s in
  Printf.sprintf "%s%s: %s\n" indent name res

let get_ipv6 = trivial_get dump_ipv6 string_of_ipv6



(* Magic *)

type magic = string

let parse_magic magic_expected input =
  let s = parse_string (String.length magic_expected) input in
  if s = magic_expected then s
  else raise (ParsingException (CustomException ("invalid magic (\"" ^
				  (hexdump s) ^ "\")"), _h_of_si input))

let lwt_parse_magic magic_expected input =
  lwt_parse_string (String.length magic_expected) input >>= fun s ->
  if s = magic_expected then return s
  else fail (ParsingException (CustomException ("invalid magic (\"" ^
				 (hexdump s) ^ "\")"), _h_of_li input))

let dump_magic s = s

let string_of_magic s = hexdump s
let print_magic ?indent:(indent="") ?name:(name="magic") s =
  print_binstring ~indent:indent ~name:name s

let get_magic = trivial_get dump_magic string_of_magic


(* Containers *)

type length_constraint =
  | NoConstraint
  | AtLeast of int
  | AtMost of int
  | Exactly of int
  | Between of int * int

let handle_length_constraint input len = function
  | NoConstraint -> ()
  | AtLeast n ->
    if len < n then raise (ParsingException (TooFewObjects (len, n), _h_of_si input))
  | AtMost n ->
    if len > n then raise (ParsingException (TooManyObjects (len, n), _h_of_si input))
  | Exactly n ->
    if len < n then raise (ParsingException (TooFewObjects (len, n), _h_of_si input));
    if len > n then raise (ParsingException (TooManyObjects (len, n), _h_of_si input))
  | Between (n1, n2) ->
    if len < n1 then raise (ParsingException (TooFewObjects (len, n1), _h_of_si input));
    if len > n2 then raise (ParsingException (TooManyObjects (len, n2), _h_of_si input))


let parse_length_constrained_container len_cons parse_fun input =
  let old_offset = input.cur_offset in
  let content = parse_fun input in
  let len = input.cur_offset - old_offset in
  handle_length_constraint input len len_cons;
  content

let dump_length_constrained_container (* len_cons *) dump_fun o =
  (* Warning if length constraint not validated? *)
  dump_fun o



let parse_enrich_blocker level parse_fun input =
  let new_input = { input with enrich = EnrichLevel level } in
  let res = parse_fun new_input in
  input.cur_offset <- new_input.cur_offset;
  res

let dump_enrich_blocker dump_fun o = dump_fun o



(* Parse checkpoints and raw values *)

let parse_save_offset input = input.cur_offset
let lwt_parse_save_offset input = input.lwt_offset
let parse_seek_offset offset input = input.cur_offset <- offset
let lwt_parse_seek_offset offset input =
  let handle_unix_error = function
    | Unix.Unix_error (Unix.ESPIPE, "lseek", "") -> return ()
    | e -> fail e
  and set_offset () =
    Lwt_io.set_position input.lwt_ch (Int64.of_int offset) >>= fun _ ->
    (* TODO: Warning, integer overflow is possible! *)
      input.lwt_offset <- offset;
      return ()
  in try_bind (set_offset) (fun () -> return ()) handle_unix_error


type raw_value = string option
let parse_raw_value offset input =
  Some (String.sub input.str (input.cur_base + offset) (input.cur_offset - offset))
let lwt_parse_raw_value _offset input =
  fail (ParsingException (NotImplemented "lwt_parse_raw_value", _h_of_li input))

let get_raw_value v path = match v, path with
  | None, [] -> Right (Leaf "None")
  | Some s, []
  | Some s, ["@hex"] -> Right (Leaf "hexdump s")
  | _, path -> Left path


(* Ignore trailing bytes *)
let parse_ignore = drop_rem_bytes