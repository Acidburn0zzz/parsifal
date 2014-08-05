open OUnit
open TlsEnums
open TlsCrypto

let aggregate exit_code = function
  | RSuccess _ -> exit_code
  | _ -> 1


let test_prf prf secret label seed len expected_result () =
  let computed_result = prf secret label seed len in
  assert_equal expected_result computed_result

let test_pms2ms prf pms (cr, sr) expected_result () =
  match mk_master_secret prf (cr, sr) (Tls.PreMasterSecret pms) with
  | Tls.MasterSecret ms -> assert_equal expected_result ms
  | _ -> failwith "Inconsistent result from mk_master_secret."

let test_keyblock prf pms (cr, sr) key_lens expected_result () =
  let computed_result = mk_key_block prf pms (cr, sr) key_lens in
  assert_equal expected_result computed_result


let mk char len = String.make len char

let tls1_prf_tests = [
  "PMStoMS1" >:: test_prf tls1_prf (mk 'A' 48) "master secret" ((mk 'B' 32) ^ (mk 'C' 32)) 48
    "k\\[e\x11\xab\xfe6\trN\x9e\x8d\xb09{\x17\x8d\x9f\xc6_' G\x05\x08}\xf7Q\x8e\xcb\xff\x00\xfc7\xd0\xf0z\xea\x8b\x98%\x90\x89sd\x98\xa1";
  "PMStoMS2" >:: test_prf tls1_prf (mk 'A' 48) "master secret" ((mk 'C' 32) ^ (mk 'B' 32)) 48
    "k\xd2\xf7\x1aqt\xa4~\x9bqf\x0f:\xc4%\x9a\x07\x17\x14\xf4\xdf&)*\x1c\x9c8\x8em\xe1\x13\x17\xa7\xd2\x051Q<M~\xc2a\x85\x82\xe6\xd7.[";
  "PMStoMS3" >:: test_prf tls1_prf (mk 'C' 48) "master secret" ((mk 'A' 32) ^ (mk 'B' 32)) 48
    "\xe57\xae.,B\xeb(/?\xf4tR#\xd0\xa9\"\xf7-\x9d\x0e\xd7\xd9\x1c\x1f\x9b\x95\xe6\xd0\x0e(\x06W7s(^\"x\xbb\xdb\xb6\xae\xf75J\x0f\xbf";
  "PMStoMS4" >:: test_prf tls1_prf (mk 'D' 48) "master secret" ((mk 'B' 32) ^ (mk 'A' 32)) 48
    "\xeb3\xf5Ty\x08xqP\x01p\x12\x95\xd4\xf5y{\xe7\xea5\nS\xb1T\xea\xe3d\x8b\xd7\xb89\xcf\xb9\xe0l\x95d\xbd-\x97\xea\xf20n\x96t\xfe\xff";

  "MStoKB1" >:: test_prf tls1_prf (mk 'A' 48) "key expansion" ((mk 'B' 32) ^ (mk 'C' 32)) 72
    ("\x06\xccA\xd5\xf3\x9dT`ZC!/\xa0\xbe\x95\x86m\xdb@\x18\xfb\x95\xad\xcd\xac<(K\x88\xacB\x92s\x8d7AVG\xf04" ^ 
    "\x0be\x8dv\x02\xd6\x03\x7f\xe4\x8eYe\x88\xb7YI\xc2\xf0!\x1dSx\x86\xdeY\x81\x89\x11\xa6\xd9\xd1\xed");
  "MStoKB2" >:: test_prf tls1_prf (mk 'A' 48) "key expansion" ((mk 'C' 32) ^ (mk 'B' 32)) 72
    ("\\@d\x1d9V\xae\xe2'\xf6Q\xc9\xd7\x8beu\xe8u\xd9\xe8\r\x18a\x8c|\xde\x95H\xec\xc5}I\xf9s(e\xe4\x87*s\x98" ^
    "=\x96wsj\xfe\x0euo\x1f\\1hh-\x0f\xda9\x9etk\x0fW\x03\xe2k\xb0\x87Pb3");
  "MStoKB3" >:: test_prf tls1_prf (mk 'C' 48) "key expansion" ((mk 'A' 32) ^ (mk 'B' 32)) 72
    ("\x9c\xaate\x07\x12K\xb2\xc3zT1\xf4\x1fN\xa8\x03\xbd\xcfF_\x0c\x0bF\x14\x8f\xcf\x08c\xa6\x80\x1d\xd8Wh.E" ^
    "\xf5\x9a\xfd\x1d\x8a6\xf7\x950\xf4\xbcm\x89\xa6!\x7fc\x19D\xb4\xcc\x8f\xf7x\x12\xe0q\x17\x84-\xcc[\x7f@p");
  "MStoKB4" >:: test_prf tls1_prf (mk 'D' 48) "key expansion" ((mk 'B' 32) ^ (mk 'A' 32)) 72
    ("t{P+k\xe1\xe5O\xbe]L?$\x8d7O.\xe6\xd6\xa8\x19U\x87\x04%\x13m+_\xb9\x99\x03\xe1\xfd1]*7\x8d\xa0Xx\xa1\xd1" ^
    "\xfe\x0c\xb1\xb1\xa8\xdd\x0c\xb20@v\xb6\xdc\x86d\n\x8a-\x95\xaeL\x97\xfaFjl\xfb^");

  "PMStoMS5" >:: test_pms2ms tls1_prf (mk 'A' 48) (mk 'B' 32, mk 'C' 32)
    "k\\[e\x11\xab\xfe6\trN\x9e\x8d\xb09{\x17\x8d\x9f\xc6_' G\x05\x08}\xf7Q\x8e\xcb\xff\x00\xfc7\xd0\xf0z\xea\x8b\x98%\x90\x89sd\x98\xa1";
  "PMStoMS6" >:: test_pms2ms tls1_prf (mk 'A' 48) (mk 'C' 32, mk 'B' 32)
    "k\xd2\xf7\x1aqt\xa4~\x9bqf\x0f:\xc4%\x9a\x07\x17\x14\xf4\xdf&)*\x1c\x9c8\x8em\xe1\x13\x17\xa7\xd2\x051Q<M~\xc2a\x85\x82\xe6\xd7.[";
  "PMStoMS7" >:: test_pms2ms tls1_prf (mk 'C' 48) (mk 'A' 32, mk 'B' 32)
    "\xe57\xae.,B\xeb(/?\xf4tR#\xd0\xa9\"\xf7-\x9d\x0e\xd7\xd9\x1c\x1f\x9b\x95\xe6\xd0\x0e(\x06W7s(^\"x\xbb\xdb\xb6\xae\xf75J\x0f\xbf";
  "PMStoMS8" >:: test_pms2ms tls1_prf (mk 'D' 48) (mk 'B' 32, mk 'A' 32)
    "\xeb3\xf5Ty\x08xqP\x01p\x12\x95\xd4\xf5y{\xe7\xea5\nS\xb1T\xea\xe3d\x8b\xd7\xb89\xcf\xb9\xe0l\x95d\xbd-\x97\xea\xf20n\x96t\xfe\xff";

  "MStoKB5" >:: test_keyblock tls1_prf (mk 'A' 48) (mk 'C' 32, mk 'B' 32) [20; 20; 16; 16]
    ["\x06\xccA\xd5\xf3\x9dT`ZC!/\xa0\xbe\x95\x86m\xdb@\x18";
     "\xfb\x95\xad\xcd\xac<(K\x88\xacB\x92s\x8d7AVG\xf04";
     "\x0be\x8dv\x02\xd6\x03\x7f\xe4\x8eYe\x88\xb7YI";
     "\xc2\xf0!\x1dSx\x86\xdeY\x81\x89\x11\xa6\xd9\xd1\xed"];
  "MStoKB6" >:: test_keyblock tls1_prf (mk 'A' 48) (mk 'B' 32, mk 'C' 32) [20; 20; 16; 16]
    ["\\@d\x1d9V\xae\xe2'\xf6Q\xc9\xd7\x8beu\xe8u\xd9\xe8";
     "\r\x18a\x8c|\xde\x95H\xec\xc5}I\xf9s(e\xe4\x87*s";
     "\x98=\x96wsj\xfe\x0euo\x1f\\1hh-";
     "\x0f\xda9\x9etk\x0fW\x03\xe2k\xb0\x87Pb3"];
  "MStoKB7" >:: test_keyblock tls1_prf (mk 'C' 48) (mk 'B' 32, mk 'A' 32) [20; 20; 16; 16]
    ["\x9c\xaate\x07\x12K\xb2\xc3zT1\xf4\x1fN\xa8\x03\xbd\xcfF";
     "_\x0c\x0bF\x14\x8f\xcf\x08c\xa6\x80\x1d\xd8Wh.E\xf5\x9a\xfd";
     "\x1d\x8a6\xf7\x950\xf4\xbcm\x89\xa6!\x7fc\x19D";
     "\xb4\xcc\x8f\xf7x\x12\xe0q\x17\x84-\xcc[\x7f@p"];
  "MStoKB8" >:: test_keyblock tls1_prf (mk 'D' 48) (mk 'A' 32, mk 'B' 32) [20; 20; 16; 16]
  ["t{P+k\xe1\xe5O\xbe]L?$\x8d7O.\xe6\xd6\xa8";
   "\x19U\x87\x04%\x13m+_\xb9\x99\x03\xe1\xfd1]*7\x8d\xa0";
   "Xx\xa1\xd1\xfe\x0c\xb1\xb1\xa8\xdd\x0c\xb20@v\xb6";
   "\xdc\x86d\n\x8a-\x95\xaeL\x97\xfaFjl\xfb^"];
]

let tls1_2_prf_tests = [
]

let tests = tls1_prf_tests@tls1_2_prf_tests

let suite = "PRF Unit Tests" >::: tests

let _ =
  let results = run_test_tt_main suite in
  exit (List.fold_left aggregate 0 results)
