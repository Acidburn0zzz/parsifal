open MapLang
open MapEval


let one_value_fun f = function
  | [e] -> f e
  | _ -> raise WrongNumberOfArguments

let one_string_fun f = function
  | [e] -> f (eval_as_string e)
  | _ -> raise WrongNumberOfArguments

let one_string_fun_with_env f env = function
  | [e] -> f env (eval_as_string e)
  | _ -> raise WrongNumberOfArguments

let one_list_fun f = function
  | [e] -> f (eval_as_list e)
  | _ -> raise WrongNumberOfArguments

let two_value_fun f = function
  | [e1; e2] -> f e1 e2
  | _ -> raise WrongNumberOfArguments

let two_value_fun_with_env f env = function
  | [e1; e2] -> f env e1 e2
  | _ -> raise WrongNumberOfArguments

let two_string_fun f = function
  | [e1; e2] -> f (eval_as_string e1) (eval_as_string e2)
  | _ -> raise WrongNumberOfArguments

let three_value_fun f = function
  | [e1; e2; e3] -> f e1 e2 e3
  | _ -> raise WrongNumberOfArguments


let typeof v = V_String (string_of_type v)


let print env args =
  let separator = getv_str env "_separator" "," in
  let endline = getv_str env "_endline" "\n" in
  print_string ((String.concat separator (List.map eval_as_string args)) ^ endline);
  V_Unit


let length = function
  | V_String s -> V_Int (String.length s)
  | V_List l -> V_Int (List.length l)
  | _ -> raise (ContentError "String or list expected")



let open_file filename =
  let f = open_in filename in
  Gc.finalise close_in_noerr f;
  V_Stream (filename, Stream.of_channel f)


let encode format input = match format with
  | "hex" -> V_String (Common.hexdump input)
  | _ -> raise (ContentError ("Unknown format"))

let decode format input = match format with
  | "hex" -> V_String (Common.hexparse input)
  | _ -> raise (ContentError ("Unknown format"))


let asn1_ehf = Asn1.Engine.default_error_handling_function
  Asn1.Asn1EngineParams.s_specfatallyviolated
  Asn1.Asn1EngineParams.s_ok

let parse_constrained_asn1 cons input =
  let pstate = match input with
    | V_String s ->
      Asn1.Engine.pstate_of_string asn1_ehf "(inline)" s
    | V_Stream (filename, s) ->
      Asn1.Engine.pstate_of_stream asn1_ehf filename s
    | _ -> raise (ContentError "String or stream expected")
  in
  Asn1Constraints.constrained_parse cons pstate

let parse_answer_dump input =
  let pstate = match input with
    | V_String s ->
      AnswerDump.pstate_of_string "(inline)" s
    | V_Stream (filename, s) ->
      AnswerDump.pstate_of_stream filename s
    | _ -> raise (ContentError "String or stream expected")
  in
  V_AnswerRecord (AnswerDump.parse_answer_record pstate)

let parse_tls_record input =
  let pstate = match input with
    | V_String s ->
      Tls.pstate_of_string "(inline)" s
    | V_Stream (filename, s) ->
      Tls.pstate_of_stream filename s
    | _ -> raise (ContentError "String or stream expected")
  in
  V_TlsRecord (Tls.parse_record asn1_ehf pstate)

let parse format input =
  try
    match format with
      | V_String "x509" ->
	V_Certificate (parse_constrained_asn1 (X509.certificate_constraint X509.object_directory) input)
      | V_String "dn" ->
	V_DN (parse_constrained_asn1 (X509.dn_constraint X509.object_directory "dn") input)
      | V_String "asn1" ->
	V_Asn1 (parse_constrained_asn1 (Asn1Constraints.Anything Common.identity) input)
      | V_String "tls" ->
	parse_tls_record input
      | V_String "answer" ->
	parse_answer_dump input
      | _ -> raise (ContentError ("Unknown format"))
  with
    | Asn1.Engine.ParsingError (err, sev, pstate) ->
      output_string stderr ("Asn1 parsing error: " ^ (Asn1.Engine.string_of_exception err sev pstate) ^ "\n");
      flush stderr;
      V_Unit
    | Tls.Engine.ParsingError (err, sev, pstate) ->
      output_string stderr ("Tls parsing error: " ^ (Tls.Engine.string_of_exception err sev pstate) ^ "\n");
      flush stderr;
      V_Unit
    | AnswerDump.Engine.ParsingError (err, sev, pstate) ->
      output_string stderr ("Answer parsing error: " ^ (AnswerDump.Engine.string_of_exception err sev pstate) ^ "\n");
      flush stderr;
      V_Unit;;

let stream_of_string n s =
  V_Stream (n, Stream.of_string s)

let concat_strings sep l =
  V_String (String.concat (eval_as_string sep)
	      (List.map (fun x -> eval_as_string x) (eval_as_list l)))


let head = function
  | [] -> raise Not_found
  | h::_ -> h

let tail = function
  | [] -> raise Not_found
  | _::r -> V_List r

let nth n l =
  let rec nth_aux n = function
  | [] -> raise Not_found
  | h::r -> if n = 0 then h else nth_aux (n-1) r
  in nth_aux (eval_as_int n) (eval_as_list l)


let rec import_list arg =
  let rec import_aux_stream accu s =
    if Common.eos s
    then V_List (List.rev accu)
    else import_aux_stream ((V_String (Common.pop_line s))::accu) s
  in
  match arg with
    | V_List l -> V_List l
    | V_Set s -> V_List (List.map (fun x -> V_String x) (StringSet.elements s))
    | V_Stream (_, s) -> import_aux_stream [] s
    | v -> V_List ([v])


let rec import_set args =
  let rec import_aux_list accu = function
    | [] -> accu
    | elt::r -> import_aux_list (StringSet.add (eval_as_string_non_recursive elt) accu) r
  in
  let rec import_aux_stream accu s =
    if Common.eos s
    then accu
    else import_aux_stream (StringSet.add (Common.pop_line s) accu) s
  in
  let rec aux accu = function
    | [] -> accu
    | (V_List l)::r -> aux (import_aux_list accu l) r
    | (V_Stream (_, s))::r -> aux (import_aux_stream accu s) r
    | (V_Set s):: r -> aux (StringSet.union accu s) r
    | v::r -> aux (StringSet.add (eval_as_string_non_recursive v) accu) r
  in
  V_Set (aux StringSet.empty args)


let filter env f arg =
  let real_f = eval_as_function f in
  let filter_aux elt = eval_as_bool (eval_function env real_f [elt]) in
  let filter_aux_set elt = filter_aux (V_String elt) in
  match arg with
    | V_List l -> V_List (List.filter filter_aux l)
    | V_Set s -> V_Set (StringSet.filter filter_aux_set s)
    | _ -> raise (ContentError "Iterable value expected")

let map env f l =
  let real_f = eval_as_function f in
  let real_l = eval_as_list l in
  V_List (List.map (fun elt -> eval_function env real_f [elt]) real_l)

let iter env f arg =
  let real_f = eval_as_function f in
  let iter_aux elt = ignore (eval_function env real_f [elt]) in
  let iter_aux_set elt = iter_aux (V_String elt) in
  let iter_aux_dict k v = ignore (eval_function env real_f [k; v]) in
  begin
    match arg with
      | V_List l -> List.iter iter_aux l
      | V_Set s -> StringSet.iter iter_aux_set s
      | V_Dict d -> Hashtbl.iter iter_aux_dict d
      | _ -> raise (ContentError "Iterable value expected")
  end;
  V_Unit


let hash_make n = V_Dict (Hashtbl.create (eval_as_int (n)))
let hash_get h f = Hashtbl.find (eval_as_dict h) f
let hash_get_def h f v = try Hashtbl.find (eval_as_dict h) f with Not_found -> v
let hash_set h f v = Hashtbl.replace (eval_as_dict h) f v; V_Unit
let hash_unset h f = Hashtbl.remove (eval_as_dict h) f; V_Unit


let add_native name f =
  Hashtbl.replace global_env name (V_Function (NativeFun f))

let add_native_with_env name f =
  Hashtbl.replace global_env name (V_Function (NativeFunWithEnv f))

let _ =
  (* Generic functions *)
  add_native "typeof" (one_value_fun typeof);
  add_native_with_env "print" print;
  add_native "length" (one_value_fun length);
  add_native_with_env "eval" (one_string_fun_with_env interpret_string);

  (* File and string functions *)
  add_native "open" (one_string_fun open_file);
  add_native "encode" (two_string_fun encode);
  add_native "decode" (two_string_fun decode);
  add_native "parse" (two_value_fun parse);
  add_native "stream" (two_string_fun stream_of_string);
  add_native "concat" (two_value_fun concat_strings);

  (* List and set functions *)
  add_native "head" (one_list_fun head);
  add_native "tail" (one_list_fun tail);
  add_native "nth" (two_value_fun nth);
  add_native "list" (one_value_fun import_list);
  add_native "set" import_set;

  (* Dict functions *)
  add_native "dict" (one_value_fun hash_make);
  add_native "dget" (two_value_fun hash_get);
  add_native "dget_def" (three_value_fun hash_get_def);
  add_native "dset" (three_value_fun hash_set);
  add_native "dunset" (two_value_fun hash_unset);

  (* Iterable functions *)
  add_native_with_env "filter" (two_value_fun_with_env filter);
  add_native_with_env "map" (two_value_fun_with_env map);
  add_native_with_env "iter" (two_value_fun_with_env iter);