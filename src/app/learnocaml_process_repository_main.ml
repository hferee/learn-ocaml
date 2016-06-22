(* This file is part of Learn-OCaml.
 *
 * Copyright (C) 2016 OCamlPro.
 *
 * Learn-OCaml is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Learn-OCaml is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>. *)

open Server_index

open Lwt.Infix

let index_enc =
  let contents_enc =
    let open Json_encoding in
    mu "group" @@ fun group_enc ->
    union
      [ case
          (obj2
             (req "title" string)
             (req "exercises" (list string)))
          (function
            | (title, `Exercises map) -> Some (title, map)
            | _ -> None)
          (fun (title, map) -> (title, `Exercises map)) ;
        case
          (obj2
             (req "title" string)
             (req "groups" (assoc group_enc)))
          (function
            | (title, `Groups map) -> Some (title, map)
            | _ -> None)
          (fun (title, map) -> (title, `Groups map)) ] in
  let open Json_encoding in
  mu "group" @@ fun group_enc ->
  check_version_1 @@
  union
    [ case
        (obj1 (req "exercises" (list string)))
        (function | `Exercises map -> Some map | _ -> None)
        (fun map -> `Exercises map) ;
      case
        (obj1 (req "groups" (assoc contents_enc)))
        (function | `Groups map -> Some map | _ -> None)
        (fun map -> `Groups map) ]

let exercise_kind_enc =
  let open Json_encoding in
  string_enum
    [ "problem", Problem ;
      "project", Project ;
      "exercise", Exercise ]

let exercise_meta_enc =
  let open Json_encoding in
  check_version_1
    (obj2
       (req "kind" exercise_kind_enc)
       (req "stars" float))

let to_channel encoding chan value =
  let json = Json_encoding.construct encoding value in
  let json = match json with
    | `A _ | `O _ as d -> d
    | v -> `A [ v ] in
  Ezjsonm.to_channel ~minify:false chan (json :> Ezjsonm.t) ;
  Printf.fprintf chan "\n%!"

let from_channel encoding chan =
  let json = Ezjsonm.from_channel chan in
  Json_encoding.destruct encoding json

let to_file encoding fn value =
  let chan = open_out fn in
  to_channel encoding chan value ;
  close_out chan

let from_file encoding fn =
  let chan = open_in fn in
  let value = from_channel encoding chan in
  close_in chan ;
  value

module StringMap = Map.Make (String)

let read_exercise exercise_dir =
  let open Lwt.Infix in
  let read_field field =
    let fn = Filename.concat exercise_dir field in
    Lwt_unix.file_exists fn >>= fun exists ->
    if not exists then
      Lwt.return None
    else
      Lwt_io.with_file ~mode:Lwt_io.Input fn Lwt_io.read >>= fun content ->
      Lwt.return (Some content)
  in
  Lwt_main.run
    (Exercise.read_lwt ~read_field
       ~id:(Filename.basename exercise_dir)
       ~decipher:false ())

let exercises_dir = ref "./exercises"

let dest_dir = ref "./www"

let dump_outputs = ref None

let dump_reports = ref None

let n_processes = ref 1

let args = Arg.align @@
  [ "-exercises-dir", Arg.Set_string exercises_dir,
    "PATH path to the exercise repository (default: [./exercises])" ;
    "-dest-dir", Arg.Set_string dest_dir,
    "PATH path to the exercise repository (default: [./www])" ;
    "-display-outcomes", Arg.Set Grader_cli.display_outcomes,
    " display the toplevel's outcomes" ;
    "-display-progression", Arg.Set Grader_cli.display_callback,
    " display grading progression messages" ;
    "-display-stdouts", Arg.Set Grader_cli.display_std_outputs,
    " display the toplevel's standard outputs" ;
    "-dump-outputs", Arg.String (fun s -> dump_outputs := Some s),
    "PATH save the outputs in the given directory" ;
    "-dump-reports", Arg.String (fun s -> dump_reports := Some s),
    "PATH save the reports in the given directory" ;
    "-j", Arg.Set_int n_processes,
    "NUMBER grader processes to launch in parallel" ]


let () =
  try
    ignore (Unix.getenv "LEARNOCAML_PROCESS_REPOSITORY_TASK") ;
    Grader_cli.main () ;
    exit 0
  with Not_found -> ()

let spawn_grader args =
  Lwt_process.exec
    ~env: (Array.concat [ [| "LEARNOCAML_PROCESS_REPOSITORY_TASK=YES" |] ;
                          Unix.environment () ])
    (Sys.argv.(0), Array.concat [ [| Sys.argv.(0) |] ; args ])

let () =
  try
    Arg.parse args
      (fun anon -> raise (Arg.Bad "unexpected anonymous argument"))
      "Usage: ./learnocaml-grader [options]" ;
    let (/) dir f =
      String.concat Filename.dir_sep [ dir ; f ] in
    let structure =
      if Sys.file_exists (!exercises_dir / "index.json") then
        from_file index_enc (!exercises_dir / "index.json")
      else
        match
          Array.to_list (Sys.readdir !exercises_dir) |>
          List.filter (fun dir -> Sys.file_exists (!exercises_dir / dir / "meta.json"))
        with
        | [] ->
            Format.eprintf "No index file, no exercise directory.@." ;
            Format.eprintf "This does not look like a LearnOCaml repository, exiting.@." ;
            exit 2
        | dirs ->
            Format.eprintf "Missing index file, using all exercise directories.@." ;
            `Exercises dirs in
    let all_exercises = ref [] in
    let rec fill_structure = function
      | `Groups groups ->
          let groups =
            List.fold_left
              (fun acc (id, (group_title, str)) ->
                 let group_contents = fill_structure str in
                 StringMap.add id { group_title ; group_contents } acc)
              StringMap.empty groups in
          Groups groups
      | `Exercises ids ->
          let exercises =
            List.fold_left
              (fun acc id ->
                 all_exercises := id :: !all_exercises ;
                 let exercise_kind, exercise_stars =
                   from_file exercise_meta_enc (!exercises_dir / id / "meta.json") in
                 let exercise_short_description = None in
                 let exercise =
                   read_exercise (!exercises_dir / id) in
                 let exercise =
                   { exercise_kind ; exercise_stars ;
                     exercise_title = Exercise.(get title) exercise ;
                     exercise_short_description} in
                 StringMap.add id exercise acc)
              StringMap.empty ids in
          Exercises exercises in
    let index = fill_structure structure in
    to_file exercise_index_enc (!dest_dir / "exercises.json") index ;
    let processes_arguments =
      List.map
        (fun id ->
           let exercise_dir = !exercises_dir / id in
           let json_path = !dest_dir / ("exercise_" ^ id ^ ".json") in
           let changed = try
               let { Unix.st_mtime = json_time } = Unix.stat json_path in
               Sys.readdir exercise_dir |>
               Array.to_list |>
               List.map (fun f -> (Unix.stat (exercise_dir / f)).Unix.st_mtime ) |>
               List.exists (fun t -> t >= json_time)
             with _ -> true in
           let dump_outputs =
             match !dump_outputs with
             | None -> None
             | Some dir -> Some (dir / id) in
           let dump_reports =
             match !dump_reports with
             | None -> None
             | Some dir -> Some (dir / id) in
           id, exercise_dir, json_path, changed, dump_outputs,dump_reports)
        (List.sort_uniq compare !all_exercises) in
    let results = Lwt_main.run @@
      if !n_processes = 1 then
        Lwt_list.map_s (fun (id, exercise_dir, json_path, changed, dump_outputs,dump_reports) ->
            if not changed then begin
              Format.printf "%-12s (no changes)@." id ;
              Lwt.return true
            end else begin
              Grader_cli.dump_outputs := dump_outputs ;
              Grader_cli.dump_reports := dump_reports ;
              Grader_cli.grade exercise_dir (Some json_path) >>= fun result ->
              match result with
              | 0 ->
                  Format.printf "%-12s     [OK]@." id ;
                  Lwt.return true
              | _ ->
                  Format.printf "%-12s   [FAILED]@." id ;
                  Lwt.return false
            end)
          processes_arguments
      else
        let pool = Lwt_pool.create !n_processes (fun () -> Lwt.return ()) in
        Lwt_list.map_p (fun (id, exercise_dir, json_path, changed, dump_outputs, dump_reports) ->
            Lwt_pool.use pool @@ fun () ->
            if not changed then begin
              Format.printf "%-12s (no changes)@." id ;
              Lwt.return true
            end else begin
              let args = Array.concat [
                  (match dump_outputs with
                   | None -> [||]
                   | Some prefix -> [| "-dump-outputs" ; prefix |]) ;
                  (match dump_reports with
                   | None -> [||]
                   | Some prefix -> [| "-dump-reports" ; prefix |]) ;
                  (if !Grader_cli.display_outcomes then [| "-display-outcomes" |] else [||]) ;
                  (if !Grader_cli.display_callback then [| "-display-progression" |] else [||]) ;
                  (if !Grader_cli.display_std_outputs then [| "-display-stdouts"  |] else [||]) ;
                  [| "-output-json" ; json_path |] ;
                  [| exercise_dir |] ]in
              spawn_grader args >>= function
              | Unix.WEXITED 0 ->
                  Format.printf "%-12s     [OK]@." id ;
                  Lwt.return true
              | _ ->
                  Format.printf "%-12s   [FAILED]@." id ;
                  Lwt.return false
            end)
          processes_arguments in
    if List.exists ((=) false) results then
      exit 1
    else
      exit 0
  with exn ->
    Json_encoding.print_error Format.err_formatter exn ;
    Format.eprintf "@." ;
    exit 2
