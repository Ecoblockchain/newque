open Core.Std
open Lwt
(* Not opening Sqlite3, to make it more explicit and to wrap all calls to it *)
module S3 = Sqlite3
module Rc = Sqlite3.Rc
module Data = Sqlite3.Data

module Logger = Log.Make (struct let path = Log.outlog let section = "Sqlite" end)

type statements = {
  count: Sqlite3.stmt * string;
  read_one: Sqlite3.stmt * string;
  begin_transaction: Sqlite3.stmt * string;
  commit_transaction: Sqlite3.stmt * string;
  rollback_transaction: Sqlite3.stmt * string;
}
type t = {
  db: Sqlite3.db sexp_opaque;
  file: string;
  mutex: Mutex.t sexp_opaque;
  avg_read: int;
  stmts: statements sexp_opaque;
} [@@deriving sexp]

(* Ridiculously high number of retries by default,
   because it is only retried when the db is locked.
   We only want it to fail in catastrophic cases. *)
let default_retries = 10

let throw_if_fail ~str rc =
  match rc with
  | Rc.OK -> ()
  | _ -> failwith str

let clean_sync ~destroy stmt =
  match destroy with
  | true -> ignore (S3.finalize stmt)
  | false ->
    begin try
        throw_if_fail ~str:"Failed to reset statement" (S3.reset stmt)
      with
      | ex ->
        ignore (async (fun () -> Logger.error (Exn.to_string ex)));
        S3.recompile stmt
    end

let exec_sync db ?(retry=default_retries) ~destroy (stmt, sql) =
  ignore (async (fun () -> Logger.debug_lazy (lazy (Printf.sprintf "Executing %s" sql))));
  let rec run count =
    match S3.step stmt with
    | Rc.DONE -> S3.changes db
    | (Rc.BUSY as code) | (Rc.LOCKED as code) ->
      begin match count <= retry with
        | true ->
          ignore (async (fun () -> Logger.warning (Printf.sprintf "Retrying execution (%s)" (Rc.to_string code))));
          Thread.yield ();
          run (count + 1)
        | false ->
          failwith (Printf.sprintf "Execution failed after %d retries with code %s" retry (Rc.to_string code))
      end
    | code ->
      failwith (Printf.sprintf "Execution failed with code %s" (Rc.to_string code))
  in
  let result = run 1 in
  clean_sync ~destroy stmt;
  result

let execute db ~destroy stmt =
  Lwt_preemptive.detach (fun () ->
      Mutex.critical_section db.mutex ~f:(fun () ->
          exec_sync db.db ~destroy stmt
        )
    ) ()

let query_sync db ?(retry=default_retries) ~destroy (stmt, sql) =
  Lwt_preemptive.detach (fun () ->
      Mutex.critical_section db.mutex ~f:(fun () ->
          ignore (async (fun () -> Logger.debug_lazy (lazy (Printf.sprintf "Querying %s" sql))));
          let queue = Queue.create ~capacity:db.avg_read () in
          let rec run count =
            match S3.step stmt with
            | Rc.ROW ->
              Queue.enqueue queue (S3.row_data stmt);
              run 0
            | Rc.DONE -> ()
            | (Rc.BUSY as code) | (Rc.LOCKED as code) ->
              begin match count <= retry with
                | true ->
                  ignore (async (fun () -> Logger.warning (Printf.sprintf "Retrying execution (%s)" (Rc.to_string code))));
                  Thread.yield ();
                  run (count + 1)
                | false ->
                  failwith (Printf.sprintf "Execution failed after %d retries with code %s" retry (Rc.to_string code))
              end
            | code ->
              failwith (Printf.sprintf "Execution failed with code %s" (Rc.to_string code))
          in
          let () = run 1 in
          clean_sync ~destroy stmt;
          Queue.to_array queue
        )
    ) ()

let transaction db ~destroy stmts =
  Lwt_preemptive.detach (fun () ->
      Mutex.critical_section db.mutex ~f:(fun () ->
          ignore (exec_sync db.db ~destroy:false db.stmts.begin_transaction);
          try
            let total_changed = List.fold stmts ~init:0 ~f:(fun acc stmt ->
                let changed = exec_sync db.db ~destroy stmt in
                acc + changed
              )
            in
            ignore (exec_sync db.db ~destroy:false db.stmts.commit_transaction);
            total_changed
          with
          | ex ->
            ignore (async (fun () -> Logger.error (Exn.to_string ex)));
            exec_sync db.db ~destroy:false db.stmts.rollback_transaction
        )
    ) ()

let prepare db mutex sql =
  Lwt_preemptive.detach (fun () ->
      Mutex.critical_section mutex ~f:(fun () ->
          ((S3.prepare db sql), sql)
        )
    ) ()

let bind db ?(retry=default_retries) stmt args =
  Lwt_preemptive.detach (fun () ->
      Mutex.critical_section db.mutex ~f:(fun () ->
          let rec run pos arg count =
            match S3.bind stmt pos arg with
            | Rc.OK -> ()
            | (Rc.BUSY as code) | (Rc.LOCKED as code) ->
              begin match count <= retry with
                | true ->
                  ignore (async (fun () -> Logger.warning (Printf.sprintf "Retrying bind (%s)" (Rc.to_string code))));
                  Thread.yield ();
                  run pos arg (count + 1)
                | false ->
                  failwith (Printf.sprintf "Bind failed after %d retries with code %s" retry (Rc.to_string code))
              end
            | code ->
              failwith (Printf.sprintf "Bind failed with code %s" (Rc.to_string code))
          in
          Array.iter ~f:(fun (i, arg) -> run i arg 0) args
        )
    ) ()

let create_table_sql = "CREATE TABLE IF NOT EXISTS MESSAGES (uuid BLOB NOT NULL, timens BIGINT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(uuid));"
let create_timens_index_sql = "CREATE INDEX IF NOT EXISTS MESSAGES_TIMENS_IDX ON MESSAGES (timens);"
let read_one_sql = "SELECT uuid, timens, raw FROM MESSAGES ORDER BY ROWID ASC LIMIT 1;"
let count_sql = "SELECT COUNT(*) FROM MESSAGES;"
let begin_sql = "BEGIN;"
let commit_sql = "COMMIT;"
let rollback_sql = "ROLLBACK;"
let insert_sql count =
  let arr = Array.create ~len:count "(?,?,?)" in
  Printf.sprintf "INSERT OR IGNORE INTO MESSAGES (uuid,timens,raw) VALUES %s;" (String.concat_array ~sep:"," arr)

let create file ~avg_read =
  let mutex = Mutex.create () in
  let%lwt db = wrap (fun () -> S3.db_open file) in

  (* These queries directly call exec_sync because the instance doesn't yet exist *)
  let%lwt create_table = prepare db mutex create_table_sql in
  let%lwt (_ : int) = wrap (fun () -> exec_sync db ~destroy:false create_table) in
  let%lwt create_timens_index = prepare db mutex create_timens_index_sql in
  let%lwt (_ : int) = wrap (fun () -> exec_sync db ~destroy:false create_timens_index) in

  let%lwt count = prepare db mutex count_sql in
  let%lwt read_one = prepare db mutex read_one_sql in
  let%lwt begin_transaction = prepare db mutex begin_sql in
  let%lwt commit_transaction = prepare db mutex commit_sql in
  let%lwt rollback_transaction = prepare db mutex rollback_sql in

  let stmts = {count; read_one; begin_transaction; commit_transaction; rollback_transaction} in
  let instance = {db; file; mutex; avg_read; stmts} in
  return instance

let push db ~msgs ~ids =
  let time = Id.time_ns () in
  let make_stmt slice =
    let%lwt ((st, _) as stmt) = prepare db.db db.mutex (insert_sql (Array.length slice)) in
    let args = Array.concat_mapi slice ~f:(fun i (raw, id) ->
        let pos = i * 3 in
        [| ((pos + 1), Data.BLOB id); ((pos + 2), Data.INT time); ((pos + 3), Data.BLOB raw) |]
      )
    in
    let%lwt () = bind db st args in
    return stmt
  in
  match%lwt Util.zip_group ~size:100 msgs ids with
  | (group::[]) ->
    let%lwt stmt = make_stmt group in
    execute db ~destroy:true stmt
  | groups ->
    let%lwt stmts = Lwt_list.map_s make_stmt groups in
    transaction db ~destroy:true stmts

let pull db ~mode =
  match mode with
  | `One ->
    begin match%lwt query_sync db ~destroy:false db.stmts.read_one with
      | [| |] -> return [| |]
      | [| [| Data.BLOB uuid; Data.INT timens; Data.BLOB raw |] |] ->
        return [| raw |]
      | dataset -> failwith (Printf.sprintf "Select One failed for %s, dataset size: %d" db.file (Array.length dataset))
    end
  | _ -> return [| |]

let size db =
  match%lwt query_sync db ~destroy:false db.stmts.count with
  | [| [| Data.INT x |] |] -> return (Int64.to_int_exn x)
  | dataset -> failwith (Printf.sprintf "Count failed for %s, dataset size: %d" db.file (Array.length dataset))
