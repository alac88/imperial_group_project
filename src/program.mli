open Core

type t = Opcode.t List.t

val to_string: ?split_instructions:bool -> t -> String.t