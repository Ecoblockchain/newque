open Core.Std
open Lwt

type redis_t = {
  conn: unit;
  host: string;
  port: int;
  auth: string option;
} [@@deriving sexp]

let create host port auth =
  let instance = {conn = (); host; port; auth;} in
  return instance

module M = struct

  type t = redis_t [@@deriving sexp]

  let close instance = return_unit

  let push instance ~msgs ~ids ack =
    return 1

  let pull instance ~mode =
    return [| |]

  let size instance =
    return 20

end
