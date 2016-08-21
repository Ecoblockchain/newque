Printexc.record_backtrace true

open Core.Std
open Lwt
open Http

let () = Lwt_engine.set ~transfer:true ~destroy:true (new Lwt_engine.libev)
let () = Lwt.async_exception_hook := fun ex -> print_endline ("UNCAUGHT EXCEPTION: " ^ (Exn.to_string ex))

(* Only for startup, replaced by newque.json settings later *)
let () = Lwt_log.add_rule "*" Lwt_log.Debug

let start config_path =
  let%lwt () = Log.stdout Lwt_log.Info "Starting Newque" in
  (* Make directories for logs and channels *)
  let check_directory path =
    let dir = Fs.is_directory ~create:true path in
    if%lwt dir then return_unit else
      Log.stderr Lwt_log.Error (path ^ " is not a directory or can't be created as one")
  in
  let%lwt () = Lwt_list.iter_s check_directory [Fs.log_dir; Fs.log_chan_dir; Fs.conf_dir; Fs.conf_chan_dir] in

  (* Make logger *)
  let module Logger = Log.Make (struct let path = Log.outlog let section = "Main" end) in

  (* Load main config *)
  let%lwt () = Logger.info ("Loading " ^ config_path) in
  let%lwt config = Configtools.parse_main config_path in
  let router = Router.create () in
  let watcher = Watcher.create router in
  let%lwt listeners = Configtools.apply_main config watcher in

  (* Load channel config files *)
  let%lwt channels = Configtools.parse_channels Fs.conf_chan_dir in
  let chain = Configtools.apply_channels channels listeners router in
  let%lwt () = match chain with
    | Ok () ->
      Printf.sprintf "Current router state: %s" (Router.sexp_of_t router |> Log.pretty_sexp)
      |> Logger.info
    | Error ll ->
      String.concat ~sep:", " ll
      |> Logger.error
  in

  let%lwt () = Lwt_unix.sleep 60. in
  return_unit

let _ =
  Lwt_unix.run (start (Fs.conf_dir ^ "newque.json"))
