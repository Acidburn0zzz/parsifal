open Lwt
open Parsifal
open PTypes
open AnswerDump
open TlsEnums
open Tls
open Ssl2
open Getopt
open X509Basics
open X509

type action = IP | Dump | All | Suite | SKE | Subject | ServerRandom | Scapy | Pcap | AnswerType | RecordTypes | Get
let action = ref IP
let verbose = ref false
let raw_records = ref false
let filter_ip = ref ""
let junk_length = ref 16
let path = ref []

let enrich_style = ref DefaultEnrich
let set_enrich_level l =
  if l > 0 then begin
    enrich_style := EnrichLevel l;
    ActionDone
  end else ShowUsage (Some "enrich level should be a positive number.")
let update_enrich_level l =
  let new_style = match !enrich_style with
    | DefaultEnrich | NeverEnrich -> EnrichLevel l
    | EnrichLevel x -> EnrichLevel (max x l)
    | AlwaysEnrich -> AlwaysEnrich
  in enrich_style := new_style

let do_get_action path_str =
  action := Get;
  path := (!path)@[path_str];
  ActionDone


let options = [
  mkopt (Some 'h') "help" Usage "show this help";
  mkopt (Some 'v') "verbose" (Set verbose) "print more info to stderr";

  mkopt None "raw-records" (Set raw_records) "show raw records (do not try to reassemble them)";

  mkopt (Some 'a') "all" (TrivialFun (fun () -> action := All)) "show all the information and records of an answer";
  mkopt (Some 'I') "ip" (TrivialFun (fun () -> action := IP)) "only show the IP of the answers";
  mkopt (Some 'D') "dump" (TrivialFun (fun () -> action := Dump)) "dumps the answers";
  mkopt (Some 's') "ciphersuite" (TrivialFun (fun () -> action := Suite; update_enrich_level 2)) "only show the ciphersuite chosen";
  mkopt (Some 'S') "ske" (TrivialFun (fun () -> action := SKE; update_enrich_level 2)) "only show information relative to ServerKeyExchange";
  mkopt None "server-random" (TrivialFun (fun () -> action := ServerRandom; update_enrich_level 2)) "only output the server random";
  mkopt None "scapy-style" (TrivialFun (fun () -> action := Scapy)) "outputs the records as independant scapy-style packets";
  mkopt None "output-pcap" (TrivialFun (fun () -> action := Pcap)) "export the answer as a PCAP";
  mkopt None "answer-type" (TrivialFun (fun () -> action := AnswerType; update_enrich_level 5)) "prints the answer types";
  mkopt None "record-types" (TrivialFun (fun () -> action := RecordTypes; update_enrich_level 2)) "prints the records received";
  mkopt None "junk-length" (IntVal junk_length) "Sets the max length of junk stuff to print";
  mkopt None "cn" (TrivialFun (fun () -> action := Subject; update_enrich_level 2)) "show the subect";
  mkopt (Some 'g') "get" (StringFun do_get_action) "Walks through the answers using a get string";

  mkopt None "always-enrich" (TrivialFun (fun () -> enrich_style := AlwaysEnrich)) "always enrich the structure parsed";
  mkopt None "never-enrich" (TrivialFun (fun () -> enrich_style := NeverEnrich)) "never enrich the structure parsed";
  mkopt None "enrich-level" (IntFun set_enrich_level) "enrich the structure parsed up to a certain level";

  mkopt None "filter-ip" (StringVal filter_ip) "only print info regarding this ip"
]


let handle_exn f x =
  try Some (f x)
  with
  | ParsingException (e, h) ->
    if !verbose then prerr_endline (string_of_exception e h);
    None
  | e ->
    if !verbose then prerr_endline (Printexc.to_string e);
    None


let parse_all_records enrich answer =
  let rec read_records accu i =
    if not (eos i)
    then begin
      match handle_exn (parse_tls_record None) i with
      | Some next -> read_records (next::accu) i
      | None -> List.rev accu, true
    end else List.rev accu, false
  in

  (* TODO: Move this function in TlsUtil? *)
  let rec split_records accu ctx str_input recs error = match str_input, recs with
    | None, [] -> List.rev accu, ctx, error
    | None, record::r ->
      let record_input =
	input_of_string ~verbose:(!verbose) ~enrich:enrich (string_of_ipv4 answer.ip)
          (exact_dump_record_content record.record_content)
      in
      let cursor = record.content_type, record.record_version, record_input in
      split_records accu ctx (Some cursor) r error
    | Some (ct, v, i), _ ->
      if eos i then split_records accu ctx None recs error
      else begin
        match handle_exn (parse_record_content ctx ct) i with
        | Some next_content ->
          let next_record = {
            content_type = ct;
            record_version = v;
            record_content = next_content;
          } in
          begin
            match ctx, next_content with
              | None, Handshake {handshake_content = ServerHello sh} ->
                let real_ctx = empty_context () in
                TlsEngine.update_with_server_hello real_ctx sh;
                split_records (next_record::accu) (Some real_ctx) str_input recs error
              | Some c, Handshake {handshake_content = ServerKeyExchange ske} ->
                TlsEngine.update_with_server_key_exchange c ske;
                split_records (next_record::accu) ctx str_input recs error
              | _ -> split_records (next_record::accu) ctx str_input recs error
          end;
        | None -> List.rev accu, ctx, true
     end
  in

  let answer_input = input_of_string ~verbose:(!verbose) (string_of_ipv4 answer.ip) answer.content in
  enrich_record_content := false;
  let raw_recs, err = read_records [] answer_input in
  if !raw_records
  then raw_recs, None, err
  else split_records [] None None (TlsUtil.merge_records ~verbose:(!verbose) ~enrich:NeverEnrich raw_recs) err

let parse_all_ssl2_records enrich answer =
  let rec read_ssl2_records accu i =
    if not (eos i)
    then begin
      match handle_exn (parse_ssl2_record { cleartext = true }) i with
      | Some next -> read_ssl2_records (next::accu) i
      | None -> List.rev accu, true
    end else List.rev accu, false
  in
  let answer_input = input_of_string ~enrich:enrich ~verbose:(!verbose) (string_of_ipv4 answer.ip) answer.content in
  enrich_record_content := false;
  let raw_recs, err = read_ssl2_records [] answer_input in
  raw_recs, None, err



let dump_extract s =
  let len2consider = min !junk_length (String.length s) in
  let s2consider = String.sub s 0 len2consider in
  let hex_s = hexdump s2consider
  and printable_s = String.copy s2consider in
  let rec mk_printable_s i =
    if i < len2consider
    then begin
      let c = int_of_char (printable_s.[i]) in
      if c < 32 || c > 126
      then printable_s.[i] <- '.';
      mk_printable_s (i+1)
    end
  in
  mk_printable_s 0;
  Printf.sprintf "%s (%s)" hex_s printable_s


let handle_answer answer =
  let ip = string_of_ipv4 answer.ip in
  let this_one, again =
    if !filter_ip = ""
    then true, true
    else if !filter_ip = ip
    then true, false
    else false, true
  in
  if this_one then begin
    match !action with
      | IP -> print_endline ip
      | Dump -> print_string (exact_dump_answer_dump answer)
      | All ->
        print_endline ip;
        let records, _, error = parse_all_records !enrich_style answer in
        List.iter (fun r -> print_endline (print_value ~verbose:!verbose ~indent:"  " (value_of_tls_record r))) records;
        if error then begin
          let records, _, error = parse_all_ssl2_records !enrich_style answer in
          List.iter (fun r -> print_endline (print_value ~verbose:!verbose ~indent:"  " (value_of_ssl2_record r))) records;
          if error then print_endline "  ERROR"
        end
      | Suite ->
        let _, ctx, _ = parse_all_records !enrich_style answer in
        let cs = match ctx with
          | None -> if !verbose then (Some "ERROR") else None
          | Some ctx -> Some (string_of_ciphersuite ctx.future.s_ciphersuite.suite_name)
        in
        begin
          match cs with
            | None -> ()
            | Some s -> Printf.printf "%s: %s\n" ip s
        end
      | SKE ->
        let _, ctx, _ = parse_all_records !enrich_style answer in
        let ske = match ctx with
          | None -> if !verbose then (Some "ERROR") else None
          | Some { future = { s_server_key_exchange = (SKE_DHE { params = params } ) } } ->
            Some (Printf.sprintf "%s,%s,%s" (hexdump params.dh_p) (hexdump params.dh_g) (hexdump params.dh_Ys))
          | Some { future = { s_server_key_exchange = (Unparsed_SKEContent "" ) } } ->
            if !verbose then (Some "NO_SKE") else None
          | Some _ -> if !verbose then (Some "NOT PARSED YET") else None
        in
        begin
          match ske with
            | None -> ()
            | Some s -> Printf.printf "%s: %s\n" ip s
        end
      | ServerRandom ->
        let records, _, _ = parse_all_records !enrich_style answer in
        begin
          match records with
          | { content_type = CT_Handshake;
              record_content = Handshake {
                handshake_type = HT_ServerHello;
                handshake_content = ServerHello {server_random = r} }}::_
            -> Printf.printf "%s: %s\n" ip (hexdump r)
          | _ -> ()
        end;
      | Scapy ->
        let records, _, _ = parse_all_records !enrich_style answer in
        let rec convert_to_scapy (len, ps) = function
          | [] -> List.rev ps
          | r::rs ->
            let dump = exact_dump_tls_record r in
            let new_p =
              Printf.sprintf "IP(src=\"%s\")/TCP(sport=%d,dport=12345,seq=%d,flags=\"\")/(\"%s\".decode(\"hex\"))"
                ip answer.port len (hexdump dump)
            in
            convert_to_scapy (len + (String.length dump), new_p::ps) rs
        in
        Printf.printf "ps = [%s]\n" (String.concat ",\n  " (convert_to_scapy (0, []) records))
      | Pcap ->
        let records, _, _ = parse_all_records !enrich_style answer in
        let rec convert_to_pcap len ps = function
          | [] -> ()
          | r::rs ->
            let dump = exact_dump_tls_record r in
            let new_p = Pcap.mk_packet answer.ip answer.port dump len in
            print_string (Parsifal.exact_dump Pcap.dump_packet new_p);
            convert_to_pcap (len + (String.length dump)) (new_p::ps) rs
        in
        convert_to_pcap 0 [] records
      | AnswerType ->
        let records =
          let tls_records, _, _ = parse_all_records !enrich_style answer in
          if tls_records <> []
          then Right tls_records
          else begin
            let ssl2_records, _, _ = parse_all_ssl2_records !enrich_style answer in
            Left ssl2_records
          end
        in
        begin
          match records, answer.content with
          | _, "" ->
            Printf.printf "%s\tE\n" ip
          | Right [{ content_type = CT_Alert;
              record_content = Alert a }], _ ->
            Printf.printf "%s\tA\t%s\t%s\n" ip (string_of_tls_alert_level a.alert_level) (string_of_tls_alert_type a.alert_type)

          | Left [{ ssl2_content = SSL2Handshake {
                      ssl2_handshake_type = SSL2_HT_ERROR;
                      ssl2_handshake_content = SSL2Error e }}], _ ->
            Printf.printf "%s\tA\tSSLv2_ALERT\t%s\n" ip (string_of_ssl2_error e)

          | Right ({ content_type = CT_Handshake;
(*        TODO:             record_version = ext_v; *)
                     record_content = Handshake {
                       handshake_type = HT_ServerHello;
                       handshake_content = ServerHello {server_version = v; ciphersuite = c} }}::
                  { content_type = CT_Handshake;
                    record_content = Handshake {
                      handshake_type = HT_Certificate;
                      handshake_content = Certificate ((Parsed cert)::_) }}::_), _
            -> Printf.printf "%s\tH\t%s\t%s\t%s\n" ip (string_of_tls_version v) (string_of_ciphersuite c)
            (quote_string (String.concat "" (List.map string_of_atv (List.flatten cert.tbsCertificate.subject))))

          | Left ({ ssl2_content = SSL2Handshake {
              ssl2_handshake_type = SSL2_HT_SERVER_HELLO;
              ssl2_handshake_content = SSL2ServerHello {
                ssl2_server_version = v;
                ssl2_server_certificate = Parsed cert;
                ssl2_server_cipher_specs = cs
              }
            }}::_), _
            -> Printf.printf "%s\tH\t%s\t%s\t%s\n" ip (string_of_tls_version v)
            (String.concat "," (List.map (fun c -> string_of_value (value_of_ssl2_cipher_spec c)) cs))
            (quote_string (String.concat "" (List.map string_of_atv (List.flatten cert.tbsCertificate.subject))))

          | Right ({ content_type = CT_Handshake;
                     record_content = Handshake {
                       handshake_type = HT_ServerHello;
                       handshake_content = ServerHello {server_version = v; ciphersuite = c} }}::_), _
            -> Printf.printf "%s\tH\t%s\t%s\tNoCertParsed\n" ip (string_of_tls_version v) (string_of_ciphersuite c)

          | Right ({ content_type = CT_Handshake;
                     record_content = Handshake {
                       handshake_type = HT_ClientHello;
                       handshake_content = ClientHello _ }}::_), _
            -> Printf.printf "%s\tJ\tClientHello\n" ip

          | _, s ->
	    if (String.length s >= 7) && (String.sub s 0 7 = "\x15\x03\x01\x00\x02\xff\xff")
	    then Printf.printf "%s\tJ\tAlert-FF-FF\n" ip
	    else if String.length s >= 5 then begin
	      match (String.sub s 0 5) with
	      | "SSH-1" -> Printf.printf "%s\tJ\tSSH-1\n" ip
	      | "SSH-2" -> Printf.printf "%s\tJ\tSSH-2\n" ip
	      | "HTTP/"
	      | "<!DOC" -> Printf.printf "%s\tJ\tHTTP\n" ip (* Do better ? *)
		(* qui contient "<!DOCTYPE html" ou "<html>" ou "<HTML>" ou "404 Not Found" *)
	      (* Handle SMTP? "220 main2 ESMTP." *)
	      | _ -> Printf.printf "%s\tJ\t%s\n" ip (dump_extract s)
	    end else Printf.printf "%s\tJ\t%s\n" ip (dump_extract s)
        end;
      | RecordTypes ->
        let records, _, err = parse_all_records !enrich_style answer in
        let rec get_type = function
          | [], false -> []
          | [], true -> ["ERROR"]
          | { content_type = CT_Alert; record_content = Alert a }::r, err ->
            let al = int_of_tls_alert_level a.alert_level
            and at = int_of_tls_alert_type  a.alert_type in
            (Printf.sprintf "Alert(%d,%d)" al at)::(get_type (r, err))
          | { content_type = CT_Handshake ; record_content = Handshake h }::r, err ->
            (string_of_hs_message_type h.handshake_type)::(get_type (r, err))
          | _::r, err -> "UNKNOWN"::(get_type (r, err))
        in
        let res = String.concat " " (get_type (records, err)) in
        Printf.printf "%s\t%s\n" ip res
      | Subject ->
        let records, _, _ = parse_all_records !enrich_style answer in
        let rec extractSubjectOfFirstCert = function
          | [] -> None
          | { content_type = CT_Handshake;
              record_content = Handshake {
                handshake_type = HT_Certificate;
                handshake_content = Certificate ((Unparsed cert_string)::_) }}::_ ->
            begin
              try
                let cert = parse_certificate (input_of_string ~verbose:(!verbose) "" cert_string) in
                Some (String.concat ", " (List.map string_of_atv (List.flatten cert.tbsCertificate.subject)))
              with _ -> None
            end
          | { content_type = CT_Handshake;
              record_content = Handshake {
                handshake_type = HT_Certificate;
                handshake_content = Certificate ((Parsed cert)::_) }}::_ ->
            Some (String.concat ", " (List.map string_of_atv (List.flatten cert.tbsCertificate.subject)))
          | _::r -> extractSubjectOfFirstCert r
        in
        begin
          match extractSubjectOfFirstCert records with
            | None -> ()
            | Some subject -> Printf.printf "%s: %s\n" ip subject
        end;
      | Get ->
        let records, _, _ = parse_all_records !enrich_style answer in
        let get_one_path p = 
          match get (VList (List.map value_of_tls_record records)) p with
          | Left err -> if !verbose then prerr_endline (ip ^ ": " ^ err); []
          | Right s -> [s]
        in
        let results = List.flatten (List.map get_one_path !path) in
        if results <> [] then Printf.printf "%s: %s\n" ip (String.concat ", " results)
  end;
  return again

let rec handle_one_file input =
  lwt_try_parse lwt_parse_answer_dump input >>= function
    | None -> return ()
    | Some answer ->
      handle_answer answer >>= fun again ->
      if again then handle_one_file input else return ()

let _ =
  try
    let args = parse_args ~progname:"test_answerDump" options Sys.argv in
    if !action = Pcap
    then print_string (Pcap.std_pcap_hdr_str);
    let open_files = function
      | [] -> input_of_channel ~verbose:(!verbose) "(stdin)" Lwt_io.stdin >>= fun x -> return [x]
      | _ -> Lwt_list.map_s input_of_filename args
    in
    Lwt_unix.run (open_files args >>= Lwt_list.iter_s handle_one_file);
  with
    | End_of_file -> ()
    | e -> prerr_endline (Printexc.to_string e)

