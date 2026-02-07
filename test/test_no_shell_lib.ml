let string_contains hay needle =
  let hlen = String.length hay in
  let nlen = String.length needle in
  if nlen = 0 then true
  else if nlen > hlen then false
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub hay i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

let rec list_ml_files dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.concat_map (fun name ->
         let path = Filename.concat dir name in
         match (Unix.lstat path).st_kind with
         | Unix.S_DIR ->
             if name = "_build" || name = ".git" then [] else list_ml_files path
         | Unix.S_REG -> if Filename.check_suffix path ".ml" then [ path ] else []
         | _ -> [])

let () =
  if Array.length Sys.argv <> 2 then (
    prerr_endline "usage: test_no_shell_lib <path-to-lib-dir>";
    exit 2
  );

  let lib_dir = Sys.argv.(1) in
  let forbidden =
    [ "open_process_in";
      "open_process_out";
      "open_process_full";
      "Sys.command"
    ]
  in

  let files = list_ml_files lib_dir in
  let check_file path =
    let src = In_channel.(with_open_text path input_all) in
    match List.find_opt (fun needle -> string_contains src needle) forbidden with
    | None -> ()
    | Some needle ->
        Printf.eprintf "forbidden shell-based API found in %s: %s\n" path needle;
        exit 1
  in
  List.iter check_file files

