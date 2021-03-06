val default_perm : int

val log_dir : string
val log_chan_dir : string
val conf_dir : string
val conf_chan_dir : string
val data_dir : string
val data_chan_dir : string

val format_unix_exn : Unix.error -> string -> string -> string

val is_directory : ?create:bool -> string -> bool Lwt.t

val list_files : string -> string list Lwt.t
