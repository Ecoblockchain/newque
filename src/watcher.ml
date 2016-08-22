open Core.Std
open Lwt
open Listener

module Logger = Log.Make (struct let path = Log.outlog let section = "Watcher" end)

type t = {
  router: Router.t;
  table: Listener.t Int.Table.t;
}

(* Listener by port *)
let create () = { table = Int.Table.create ~size:5 (); router = Router.create ();}

let router watcher = watcher.router
let listeners watcher = Int.Table.data watcher.table

let start_http watcher generic specific =
  (* Partially apply the routing function *)
  let open Config_t in
  Http.start generic specific (Router.route watcher.router ~listen_name:generic.name)

let rec monitor watcher listen =
  match listen.server with
  | HTTP (http, wakener) ->
    let open Http in
    let must_restart = begin try%lwt
        let%lwt () = choose [http.thread; waiter_of_wakener wakener; waiter_of_wakener http.close] in
        if not (is_sleeping http.thread) then return_true else return_false
      with
      | Unix.Unix_error (code, name, param) ->
        let%lwt () = Logger.error (Fs.format_unix_exn code name param) in
        return_true
      | ex ->
        let%lwt () = Logger.error (Exn.to_string ex) in
        return_true
    end in
    begin match%lwt must_restart with
      | false -> return_unit (* Just stop monitoring it *)
      | true ->
        (* Restart the server and monitor it recursively *)
        let g = http.generic in
        let open Config_t in
        let%lwt () = Printf.sprintf "Restarting HTTP listener %s on HTTP %s:%s" g.name g.host (Int.to_string g.port)
                     |> Logger.notice in
        let%lwt () = Http.close http in
        let%lwt restarted = start_http watcher http.generic http.specific in
        let (_, new_wakener) = wait () in
        monitor watcher {id=listen.id; server=(HTTP (restarted, new_wakener))}
    end
  | ZMQ (zmq, wakener) -> failwith "Unimplemented"

let create_listeners watcher endpoints =
  let open Config_t in
  Lwt_list.iter_p (fun generic ->
      (* Stop and replace possible existing listener on the same port *)
      let%lwt () = match Int.Table.find_and_remove watcher.table generic.port with
        | Some {server=(HTTP (existing, _));_} -> Http.stop existing
        | Some {server=(ZMQ (existing, _));_} -> failwith "Unimplemented"
        | None -> return_unit
      in
      let%lwt started = match generic.settings with
        | Http_proto specific ->
          let%lwt () = Logger.notice (Printf.sprintf "Starting %s on HTTP %s:%s" generic.name generic.host (Int.to_string generic.port)) in
          let%lwt http = start_http watcher generic specific in
          let (_, wakener) = wait () in
          return {id=generic.name; server=(HTTP (http, wakener))}
        | Zmq_proto specific -> failwith "Unimplemented"
      in
      async (fun () -> monitor watcher started);
      Int.Table.add_exn watcher.table ~key:generic.port ~data:started;
      return_unit
    ) endpoints
