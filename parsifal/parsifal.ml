open Lwt


(********************)
(* Useful functions *)
(********************)


let pop_opt default = function
  | None -> default
  | Some x -> x


let hexa_char = "0123456789abcdef"

let hexdump s =
  let len = String.length s in
  let res = String.make (len * 2) ' ' in
  for i = 0 to (len - 1) do
    let x = int_of_char (String.get s i) in
    res.[i * 2] <- hexa_char.[(x lsr 4) land 0xf];
    res.[i * 2 + 1] <- hexa_char.[x land 0xf];
  done;
  res


let quote_string s =
  let n = String.length s in

  let estimate_len_char c =
    match c with
      | '\n' | '\t' | '\\' | '"' -> 2
      | c -> let x = int_of_char c in
	     if x >= 32 && x < 128 then 1 else 4
  in
  let rec estimate_len accu offset =
    if offset = n then accu
    else estimate_len (accu + estimate_len_char (s.[offset])) (offset + 1)
  in

  let newlen = estimate_len 0 0 in
  let res = String.make newlen ' ' in

  let mk_two_char c offset =
    res.[offset] <- '\\';
    res.[offset + 1] <- c;
    offset + 2
  in
  let write_char c offset =
    match c with
      | '\n' -> mk_two_char 'n' offset
      | '\t' -> mk_two_char 't' offset
      | '\\' -> mk_two_char '\\' offset
      | '"' -> mk_two_char '"' offset
      | c ->
	let x = int_of_char c in
	if x >= 32 && x < 128
	then begin
	  res.[offset] <- c;
	  offset + 1
	end else begin
	  res.[offset] <- '\\';
	  res.[offset + 1] <- 'x';
	  res.[offset + 2] <- hexa_char.[x lsr 4];
	  res.[offset + 3] <- hexa_char.[x land 15];
	  offset + 4
	end
  in
  let rec write_string src_offset dst_offset =
    if src_offset < n then begin
      let new_offset = write_char s.[src_offset] dst_offset in
      write_string (src_offset + 1) (new_offset)
    end
  in
  write_string 0 0;
  res




(**********************)
(* Parsing structures *)
(**********************)


(* String and Lwt input definitions *)

type string_input = {
  str : string;
  cur_name : string;
  cur_base : int;
  mutable cur_offset : int;
  cur_length : int;
  history : (string * int * int option) list
}

type lwt_input = {
  lwt_ch : Lwt_io.input_channel;
  lwt_name : string;
  mutable lwt_offset : int;
  lwt_rewindable : bool;
  lwt_length : int;
}

let print_string_input i =
  let rec print_history accu = function
    | [] -> String.concat ", " (List.rev accu)
    | (n, o, None)::r ->
      print_history ((Printf.sprintf "%s (%d/?)" n o)::accu) r
    | (n, o, Some l)::r ->
      print_history ((Printf.sprintf "%s (%d/%d)" n o l)::accu) r
  in
  Printf.sprintf "%s (%d/%d) [%s]" i.cur_name i.cur_offset i.cur_length (print_history [] i.history)

let print_lwt_input i =
  Printf.sprintf "%s (%d/?)" i.lwt_name i.lwt_offset

type fuzzy_input =
  | StringInput of string_input
  | LwtInput of lwt_input

let print_fuzzy_input = function
  | StringInput s -> print_string_input s
  | LwtInput l -> print_lwt_input l


type parsing_exception =
  | OutOfBounds
  | UnexpectedTrailingBytes
  | EmptyHistory
  | NonEmptyHistory
  | UnableToRewind
  | CustomException of string
  | NotImplemented of string

let print_parsing_exception = function
  | OutOfBounds -> "OutOfBounds"
  | UnexpectedTrailingBytes -> "UnexpectedTrailingBytes"
  | EmptyHistory -> "EmptyHistory"
  | NonEmptyHistory -> "NonEmptyHistory"
  | UnableToRewind -> "UnableToRewind"
  | CustomException e -> e
  | NotImplemented feat -> "Not implemented (" ^ feat ^ ")"

exception ParsingException of parsing_exception * fuzzy_input

let emit_parsing_exception fatal e i =
  if fatal
  then raise (ParsingException (e, StringInput i))
  else Printf.fprintf stderr "%s in %s\n" (print_parsing_exception e) (print_string_input i)

let emit_lwt_parsing_exception fatal e i =
  if fatal
  then fail (ParsingException (e, LwtInput i))
  else begin
    Printf.fprintf stderr "%s in %s\n" (print_parsing_exception e) (print_lwt_input i);
    return ()
  end



(* string_input manipulation *)

let input_of_string name s = {
    str = s;
    cur_name = name;
    cur_base = 0;
    cur_offset = 0;
    cur_length = String.length s;
    history = []
  }

let get_in input name len =
  if input.cur_offset + len <= input.cur_length
  then {
    str = input.str;
    cur_name = name;
    cur_base = input.cur_base + input.cur_offset;
    cur_offset = 0;
    cur_length = len;
    history = (input.cur_name, input.cur_offset, Some input.cur_length)::input.history
  } else raise (ParsingException (OutOfBounds, StringInput input))

let get_out old_input input =
  if input.cur_offset < input.cur_length
  then raise (ParsingException (UnexpectedTrailingBytes, StringInput input))
  else old_input.cur_offset <- old_input.cur_offset + input.cur_length


let append_to_input input next_string =
  if input.cur_base = 0 && input.history = []
  then { input with
    str =  (String.sub input.str input.cur_offset (input.cur_length - input.cur_offset)) ^ next_string;
    cur_offset = 0;
    cur_length = String.length input.str
  } else { input with
    str = input.str ^ next_string;
    cur_length = input.cur_length + (String.length next_string);
  }

let drop_used_string input =
  if input.cur_base = 0 && input.history = []
  then { input with
    str = (String.sub input.str input.cur_offset (input.cur_length - input.cur_offset));
    cur_offset = 0;
    cur_length = String.length input.str
  } else raise (ParsingException (NonEmptyHistory, StringInput input))


let eos input =
  input.cur_offset >= input.cur_length

let check_empty_input fatal input =
  if not (eos input) then emit_parsing_exception fatal UnexpectedTrailingBytes input

let try_parse parse_fun input =
  if eos input then None else begin
    let saved_offset = input.cur_offset in
    try Some (parse_fun input)
    with ParsingException _ ->
      input.cur_offset <- saved_offset;
      None
  end

let exact_parse parse_fun input =
  let res = parse_fun input in
  check_empty_input true input;
  res



(* lwt_input manipulation *)

let channel_length ch =
  let handle_unix_error = function
    | Unix.Unix_error (Unix.ESPIPE, "lseek", "") -> return None
    | e -> fail e
  and get_length () = Lwt_io.length ch
  and is_not_null x = return (Some (Int64.to_int x))  (* TODO: Warning, integer overflow is possible! *)
  in try_bind get_length is_not_null handle_unix_error

let input_of_channel name ch =
  channel_length ch >>= fun l ->
  let rewindable, length = match l with
    | None -> false, 0
    | Some len -> true, len
  in
  return { lwt_ch = ch; lwt_name = name;
	   lwt_offset = Int64.to_int (Lwt_io.position ch);
	   (* TODO: Possible integer overflow in 32-bit *)
	   lwt_rewindable = rewindable;
	   lwt_length = length }

let input_of_fd name fd =
  let ch = Lwt_io.of_fd Lwt_io.input fd in
  input_of_channel name ch

let input_of_filename filename =
  Lwt_unix.openfile filename [Unix.O_RDONLY] 0 >>= fun fd ->
  input_of_fd filename fd


let lwt_really_read input len =
  let buf = String.make len ' ' in
  let _really_read () =
    Lwt_io.read_into_exactly input.lwt_ch buf 0 len
  and finalize_ok () =
    input.lwt_offset <- input.lwt_offset + len;
    return buf
  and finalize_nok = function
    | End_of_file -> fail (ParsingException (OutOfBounds, LwtInput input))
    | e -> fail e
  in
    try_bind _really_read finalize_ok finalize_nok

let lwt_get_in input name len =
  lwt_really_read input len >>= fun s ->
  return {
    str = s;
    cur_name = name;
    cur_base = 0;
    cur_offset = 0;
    cur_length = len;
    history = [input.lwt_name, input.lwt_offset, None]
  }

let lwt_get_out old_input input =
  if input.cur_offset < input.cur_length
  then fail (ParsingException (UnexpectedTrailingBytes, StringInput input))
  else begin
    old_input.lwt_offset <- old_input.lwt_offset + input.cur_length;
    return ()
  end

let lwt_eos input =
  input.lwt_rewindable && (input.lwt_offset >= input.lwt_length)

let lwt_check_empty_input fatal input =
  if lwt_eos input
  then return ()
  else emit_lwt_parsing_exception fatal UnexpectedTrailingBytes input


let lwt_try_parse lwt_parse_fun input =
  if lwt_eos input then return None else begin
    let saved_offset = input.lwt_offset in
    let finalize_ok x = return (Some x)
    and finalize_nok = function
      | ParsingException _ ->
	input.lwt_offset <- saved_offset;
	if input.lwt_rewindable
	then begin
	  Lwt_io.set_position input.lwt_ch (Int64.of_int saved_offset) >>= fun () ->
	  return None
	end else fail (ParsingException (UnableToRewind, LwtInput input))
      | e -> fail e
    in try_bind (fun () -> lwt_parse_fun input) finalize_ok finalize_nok
  end

let lwt_exact_parse lwt_parse_fun input =
  lwt_parse_fun input >>= fun res ->
  lwt_check_empty_input true input >>= fun () ->
  return res



(**************)
(* Base types *)
(**************)


(* Integers *)

let parse_uint8 input =
  if input.cur_offset < input.cur_length then begin
    let res = int_of_char (input.str.[input.cur_base + input.cur_offset]) in
    input.cur_offset <- input.cur_offset + 1;
    res
  end else raise (ParsingException (OutOfBounds, StringInput input))

let parse_char input =
  if input.cur_offset < input.cur_length then begin
    let res = input.str.[input.cur_base + input.cur_offset] in
    input.cur_offset <- input.cur_offset + 1;
    res
  end else raise (ParsingException (OutOfBounds, StringInput input))

let peek_uint8 input =
  if input.cur_offset < input.cur_length then begin
    int_of_char (input.str.[input.cur_base + input.cur_offset])
  end else raise (ParsingException (OutOfBounds, StringInput input))

let lwt_parse_uint8 input =
  lwt_really_read input 1 >>= fun s ->
  return (int_of_char (s.[0]))

let lwt_parse_char input =
  lwt_really_read input 1 >>= fun s ->
  return (s.[0])

let dump_uint8 v = String.make 1 (char_of_int (v land 0xff))

let dump_char c = String.make 1 c

let print_uint8 ?indent:(indent="") ?name:(name="uint8") v =
  Printf.sprintf "%s%s: %d (%2.2x)\n" indent name v v

let print_char ?indent:(indent="") ?name:(name="char") c =
  Printf.sprintf "%s%s: %c (%2.2x)\n" indent name c (int_of_char c)


let parse_uint16 input =
  if input.cur_offset + 2 <= input.cur_length then begin
    let res =
      (int_of_char (input.str.[input.cur_base + input.cur_offset]) lsl 8) lor
	(int_of_char (input.str.[input.cur_base + input.cur_offset + 1]))
    in
    input.cur_offset <- input.cur_offset + 2;
    res
  end else raise (ParsingException (OutOfBounds, StringInput input))

let peek_uint16 input =
  if input.cur_offset + 2 <= input.cur_length then begin
    (int_of_char (input.str.[input.cur_base + input.cur_offset]) lsl 8) lor
      (int_of_char (input.str.[input.cur_base + input.cur_offset + 1]))
  end else raise (ParsingException (OutOfBounds, StringInput input))

let lwt_parse_uint16 input =
  lwt_really_read input 2 >>= fun s ->
  return (((int_of_char s.[0]) lsl 8) lor (int_of_char s.[1]))

let dump_uint16 v =
  let c0 = char_of_int ((v lsr 8) land 0xff)
  and c1 = char_of_int (v land 0xff) in
  let res = String.make 2 c0 in
  res.[1] <- c1;
  res

let print_uint16 ?indent:(indent="") ?name:(name="uint16") v =
  Printf.sprintf "%s%s: %d (%4.4x)\n" indent name v v


let parse_uint24 input =
  if input.cur_offset + 3 <= input.cur_length then begin
    let res =
      (int_of_char (input.str.[input.cur_base + input.cur_offset]) lsl 16) lor
      (int_of_char (input.str.[input.cur_base + input.cur_offset + 1]) lsl 8) lor
	(int_of_char (input.str.[input.cur_base + input.cur_offset + 2]))
    in
    input.cur_offset <- input.cur_offset + 3;
    res
  end else raise (ParsingException (OutOfBounds, StringInput input))

let lwt_parse_uint24 input =
  lwt_really_read input 3 >>= fun s ->
  return (((int_of_char s.[0]) lsl 16) lor
    ((int_of_char s.[1]) lsl 8) lor (int_of_char s.[2]))

let dump_uint24 v =
  let c0 = char_of_int ((v lsr 16) land 0xff)
  and c1 = char_of_int ((v lsr 8) land 0xff)
  and c2 = char_of_int (v land 0xff) in
  let res = String.make 3 c0 in
  res.[1] <- c1;
  res.[2] <- c2;
  res

let print_uint24 ?indent:(indent="") ?name:(name="uint24") v =
  Printf.sprintf "%s%s: %d (%6.6x)\n" indent name v v


let parse_uint32 input =
  if input.cur_offset + 2 <= input.cur_length then begin
    let res =
      (int_of_char (input.str.[input.cur_base + input.cur_offset]) lsl 24) lor
      (int_of_char (input.str.[input.cur_base + input.cur_offset + 1]) lsl 16) lor
      (int_of_char (input.str.[input.cur_base + input.cur_offset + 2]) lsl 8) lor
	(int_of_char (input.str.[input.cur_base + input.cur_offset + 3]))
    in
    input.cur_offset <- input.cur_offset + 4;
    res
  end else raise (ParsingException (OutOfBounds, StringInput input))

let lwt_parse_uint32 input =
  lwt_really_read input 4 >>= fun s ->
  return (((int_of_char s.[0]) lsl 24) lor ((int_of_char s.[1]) lsl 16)
    lor ((int_of_char s.[2]) lsl 8) lor (int_of_char s.[3]))

let dump_uint32 v =
  let c0 = char_of_int ((v lsr 24) land 0xff)
  and c1 = char_of_int ((v lsr 16) land 0xff)
  and c2 = char_of_int ((v lsr 8) land 0xff)
  and c3 = char_of_int (v land 0xff) in
  let res = String.make 4 c0 in
  res.[1] <- c1;
  res.[2] <- c2;
  res.[3] <- c3;
  res

let print_uint32 ?indent:(indent="") ?name:(name="uint32") v =
  Printf.sprintf "%s%s: %d (%8.8x)\n" indent name v v



(* Enums *)

let print_enum string_of_val int_of_val nchars ?indent:(indent="") ?name:(name="enum") v =
  Printf.sprintf "%s%s: %s (%*.*x)\n" indent name (string_of_val v) nchars nchars (int_of_val v)


(* Unions *)

(* TODO: local_arg should be more than just a boolean *)
let should_enrich global_ref local_arg =
  !global_ref || local_arg



(* Strings *)

let parse_string n input =
  if input.cur_offset + n <= input.cur_length then begin
    let res = String.sub input.str (input.cur_base + input.cur_offset) n in
    input.cur_offset <- input.cur_offset + n;
    res
  end else raise (ParsingException (OutOfBounds, StringInput input))

let lwt_parse_string n input = lwt_really_read input n

let parse_rem_string input =
  let res = String.sub input.str (input.cur_base + input.cur_offset) (input.cur_length - input.cur_offset) in
  input.cur_offset <- input.cur_length;
  res

let lwt_parse_rem_string input =
  if input.lwt_rewindable
  then lwt_really_read input (input.lwt_length - input.lwt_offset)
  else fail (ParsingException (NotImplemented "lwt_parse_rem_string", LwtInput input))


let parse_varlen_string name len_fun input =
  let n = len_fun input in
  let new_input = get_in input name n in
  let res = parse_rem_string new_input in
  get_out input new_input;
  res

let lwt_parse_varlen_string name len_fun input =
  len_fun input >>= fun n ->
  lwt_get_in input name n >>= fun str_input ->
  let res = parse_rem_string str_input in
  lwt_get_out input str_input >>= fun () ->
  return res


let drop_bytes n input =
  if input.cur_offset + n <= input.cur_length
  then input.cur_offset <- input.cur_offset + n
  else raise (ParsingException (OutOfBounds, StringInput input))

let lwt_drop_bytes n input =
  lwt_really_read input n >>= fun _ -> return ()

let drop_rem_bytes input =
  input.cur_offset <- input.cur_length

let lwt_drop_rem_bytes input =
  if input.lwt_rewindable then begin
    lwt_really_read input (input.lwt_length - input.lwt_offset) >>= fun _ ->
    return ()
  end else fail (ParsingException (NotImplemented "lwt_drop_rem_bytes", LwtInput input))


let dump_string s = s

let dump_varlen_string len_fun s =
  let n = String.length s in
  (len_fun n) ^ s


let print_string ?indent:(indent="") ?name:(name="string") = function
  | "" -> Printf.sprintf "%s%s\n" indent name
  | s  -> Printf.sprintf "%s%s: \"%s\"\n" indent name (quote_string s)

let print_binstring ?indent:(indent="") ?name:(name="binstring") = function
  | "" -> Printf.sprintf "%s%s\n" indent name
  | s -> Printf.sprintf "%s%s: %s\n" indent name (hexdump s)



(* List and container *)

let parse_list n parse_fun input =
  let rec aux accu = function
    | 0 -> List.rev accu
    | i ->
      let x = parse_fun input in
      aux (x::accu) (i-1)
  in aux [] n

let lwt_parse_list n parse_fun input =
  let rec aux accu = function
    | 0 -> return (List.rev accu)
    | i ->
      parse_fun input >>= fun x ->
      aux (x::accu) (i-1)
  in aux [] n


let parse_rem_list parse_fun input =
  let rec aux accu =
    if eos input
    then List.rev accu
    else begin
      let x = parse_fun input in
      aux (x::accu)
    end
  in aux []

let lwt_parse_rem_list lwt_parse_fun input =
  let rec aux accu =
    if lwt_eos input
    then return (List.rev accu)
    else begin
      let saved_offset = input.lwt_offset in
      let finalize_ok x = aux (x::accu)
      and finalize_nok = function
	| (ParsingException _) as e ->
	    if input.lwt_offset = saved_offset
	    then return (List.rev accu)
	    else fail e
	| e -> fail e
      in try_bind (fun () -> lwt_parse_fun input) finalize_ok finalize_nok
    end
  in aux []


let parse_varlen_list name len_fun parse_fun input =
  let n = len_fun input in
  let new_input = get_in input name n in
  let res = parse_rem_list parse_fun new_input in
  get_out input new_input;
  res

let lwt_parse_varlen_list name len_fun parse_fun input =
  len_fun input >>= fun n ->
  lwt_get_in input name n >>= fun str_input ->
  wrap2 parse_rem_list parse_fun str_input >>= fun res ->
  lwt_get_out input str_input >>= fun () ->
  return res


let dump_list dump_fun l =
  String.concat "" (List.map dump_fun l)

let dump_varlen_list len_fun dump_fun l =
  let res = dump_list dump_fun l in
  let n = String.length res in
  (len_fun n) ^ res

let try_print (print_fun : ?indent:string -> ?name:string -> 'a -> string) ?indent:(indent="") ?name (x:'a option) =
  match name, x with
  | _, None -> ""
  | None, Some x -> print_fun ~indent:indent x
  | Some n, Some x -> print_fun ~indent:indent ~name:n x


let parse_container name n parse_fun input =
  let new_input = get_in input name n in
  let res = parse_fun new_input in
  get_out input new_input;
  res

let lwt_parse_container name n parse_fun input =
  lwt_get_in input name n >>= fun str_input ->
  wrap1 parse_fun str_input >>= fun res ->
  lwt_get_out input str_input >>= fun () ->
  return res

let dump_container len_fun dump_fun content =
  let res = dump_fun content in
  let n = String.length res in
  (len_fun n) ^ res


let parse_varlen_container name len_fun parse_fun input =
  let n = len_fun input in
  parse_container name n parse_fun input

let lwt_parse_varlen_container name len_fun parse_fun input =
  len_fun input >>= fun n ->
  lwt_parse_container name n parse_fun input



(* Misc *)

let try_dump dump_fun = function
  | None -> ""
  | Some x -> dump_fun x

let try_print (print_fun : ?indent:string -> ?name:string -> 'a -> string) ?indent:(indent="") ?name (x:'a option) =
  match name, x with
  | _, None -> ""
  | None, Some x -> print_fun ~indent:indent x
  | Some n, Some x -> print_fun ~indent:indent ~name:n x
