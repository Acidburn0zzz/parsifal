(* Constrained parsing *)

open NewParsingEngine
open Asn1



let instead_of a b = Some ((string_of_int a) ^ " instead of " ^ (string_of_int b))
let at_least a b = Some ((string_of_int a) ^ ", at least " ^ (string_of_int b) ^ " expected")
let at_most a b = Some ((string_of_int a) ^ ", at most " ^ (string_of_int b) ^ " expected")


type 'a asn1_constraint =
  | Anything of (asn1_object -> 'a)
  | Simple_cons of (asn1_class * bool * int * string * (parsing_state -> 'a))
  | Complex_cons of (asn1_class -> bool -> int -> (string * (parsing_state -> 'a)) option)

type number_constraint =
  | AlwaysOK
  | Exactly of int * severity
  | AtLeast of int * severity
  | AtMost of int * severity
  | Between of int * int * severity

type ('a, 'b) alternative =
  | Left of 'a
  | Right of 'b

type 'a sequence_constraint = {
  severity_if_too_many_objects : severity;
  constraint_list : ('a asn1_constraint * severity) list
}

let common_constrained_parse (cons : 'a asn1_constraint) (pstate : parsing_state)
    : (asn1_errors, 'a) alternative =

  let aux to_discard name f =
    drop_bytes pstate to_discard;
    let new_pstate = extract_length pstate name in
    let content = f new_pstate in
    if not (eos new_pstate) then asn1_emit UnexpectedJunk None None pstate;
    Right content
  in

  (* TODO: Details ? *)
  if eos pstate then Left TooFewObjects else begin
    let offset = pstate.cur_offset in
    let (c, isC, t), to_discard = extract_header_rewindable pstate in
    match cons with
      | Anything postprocess ->
	drop_bytes pstate to_discard;
	let new_pstate = extract_length pstate (string_of_header_pretty c isC t) in
	let len = Common.pop_option new_pstate.cur_length (-1) in
	let content = (choose_parse_fun pstate c isC t) new_pstate in
	let res = mk_object (string_of_header_pretty c isC t) c t offset to_discard len content in
	if not (eos new_pstate) then asn1_emit UnexpectedJunk None None pstate;
	Right (postprocess res)

      | Simple_cons (c', isC', t', name, f) when c = c' && isC = isC' && t = t' ->
	aux to_discard name f
      | Simple_cons (c', isC', t', _, _) ->    
	(* TODO: Details ? *)
	Left (UnexpectedHeader)

      | Complex_cons get_f ->
	match get_f c isC t with
	  (* TODO: Details ? *)
	  | None -> Left (UnexpectedHeader)
	  | Some (name, f) -> aux to_discard name f
  end


let constrained_parse_opt (cons : 'a asn1_constraint) (sev : severity) (pstate : parsing_state) : 'a option =
  let res = common_constrained_parse cons pstate in
  match res with
    | Left err ->
      if sev <> s_ok then asn1_emit err None None pstate;
      None
    | Right x -> Some x


let constrained_parse_def (cons : 'a asn1_constraint) (sev : severity)
                          (default_value : 'a) (pstate : parsing_state) : 'a =
  let res = common_constrained_parse cons pstate in
  match res with
    | Left err ->
      if sev <> s_ok then asn1_emit err None None pstate;
      default_value
    | Right x -> x


let constrained_parse (cons : 'a asn1_constraint) (pstate : parsing_state) : 'a =
  let res = common_constrained_parse cons pstate in
  match res with
    | Left err ->
      asn1_emit err (Some s_fatal) None pstate;
      failwith "constrained_parse"
    | Right x -> x


let rec parse_sequenceof (postprocess : 'a list -> 'b) (cons : 'a asn1_constraint)
                         (n : number_constraint) (pstate : parsing_state) : 'b =
  
  let rec parse_aux n =
    if eos pstate
    then [], n
    else 
      let next = constrained_parse cons pstate in
      let tail, len = parse_aux (n + 1) in
      next::tail, len
  in
  let res, res_len = parse_aux 0 in begin
    match n with
      | AlwaysOK -> ()
      | Exactly (num, sev) ->
	let e = if res_len < num then TooFewObjects else TooManyObjects in
	asn1_emit e (Some sev) (instead_of res_len num) pstate
	
      | AtLeast (num, sev) ->
	if res_len < num
	then asn1_emit TooFewObjects (Some sev) (at_least res_len num) pstate
	
      | AtMost (num, sev) ->
	if res_len > num
	then asn1_emit TooManyObjects (Some sev) (at_most res_len num) pstate
	  
      | Between (n1, n2, sev) ->
	if res_len < n1
	then asn1_emit TooFewObjects (Some sev) (at_least res_len n1) pstate;
	if n2 < res_len
	then asn1_emit TooManyObjects (Some sev) (at_most res_len n2) pstate
  end;
  postprocess res

	
let rec parse_constrained_sequence (postprocess : 'a list -> 'b) (conss : 'a sequence_constraint)
                                   (pstate : parsing_state) : 'b =

  let rec parse_aux cons_list =
    match cons_list with
      | [] -> 
	if not (eos pstate)
	then asn1_emit UnexpectedJunk (Some conss.severity_if_too_many_objects) None pstate;
	[]

      | (cons, sev)::r -> 
	match constrained_parse_opt cons sev pstate with
	  | None -> parse_aux r
	  | Some next -> next::(parse_aux r)
  in
  postprocess (parse_aux conss.constraint_list)


let rec parse_constrained_pair (postprocess : 'a option * 'b option -> 'c)
                               (cons1 : 'a asn1_constraint) (cons2 : 'b asn1_constraint)
                               (sev : severity) (pstate : parsing_state) : 'c =
  let a = constrained_parse_opt cons1 sev pstate in
  let b = constrained_parse_opt cons2 sev pstate in
  postprocess (a, b)


let bool_cons = Simple_cons (C_Universal, false, 1, "Boolean", raw_der_to_boolean)
let int_cons = Simple_cons (C_Universal, false, 2, "Integer", raw_der_to_int)
let bitstring_cons = Simple_cons (C_Universal, false, 3, "Bit String", raw_der_to_bitstring 54)
let null_cons = Simple_cons (C_Universal, false, 5, "Null", raw_der_to_null)
let oid_cons = Simple_cons (C_Universal, false, 6, "OId", raw_der_to_oid)


let seqOf_cons postprocess name cons n =
  Simple_cons (C_Universal, true, 16, name, parse_sequenceof postprocess cons n)
let setOf_cons postprocess name cons n =
  Simple_cons (C_Universal, true, 17, name, parse_sequenceof postprocess cons n)
let custom_seq_cons c t name postprocess conss =
  Simple_cons (c, true, t, name, parse_constrained_sequence postprocess conss)
let custom_pair_cons c t name postprocess cons1 cons2 sev =
  Simple_cons (c, true, t, name, parse_constrained_pair postprocess cons1 cons2 sev)


let validating_parser_simple_cons c isC t name parse_fun =
  let aux pstate = mk_object' name c t (parse_fun pstate) in
  Simple_cons (c, isC, t, name, aux)

let validating_parser_complex_cons_from_list c isC t_list parse_fun =
  let aux c t name pstate = mk_object' name c t (parse_fun pstate) in
  let cons_fun c' isC' t' =
    if c = c' && isC = isC' && (List.mem t' t_list)
    then begin
      let name = string_of_header_pretty c' isC' t' in
      Some (name, aux c' t' name)
    end else None
  in
  Complex_cons cons_fun



let null_obj_cons = validating_parser_simple_cons C_Universal false 5 "Null" der_to_null
let int_obj_cons = validating_parser_simple_cons C_Universal false 2 "Integer" der_to_int

let printablestring_cons =
  validating_parser_simple_cons C_Universal false 19 "Printable String" (der_to_octetstring false)
let ia5string_cons =
  validating_parser_simple_cons C_Universal false 22 "IA5 String" (der_to_octetstring false)

let directory_name_cons =
  validating_parser_complex_cons_from_list C_Universal false [12; 19; 20; 28; 30] (der_to_octetstring false)

let seqOf_obj_cons name cons n =
  validating_parser_simple_cons C_Universal true 16 name
    (parse_sequenceof (fun l -> Constructed l) cons n)
