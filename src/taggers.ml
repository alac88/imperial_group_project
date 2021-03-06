open Core
open TracerTypes
open FullTrace

let with_result f db full_trace =
  Option.iter ~f:(fun res -> f db res full_trace) full_trace.result

let tag_output' db result { args; _ } =
  let f arg = FactDb.add_int_rel2 db "is_output" (result.StackValue.id, arg.StackValue.id) in
  List.iter ~f args
let tag_output = with_result tag_output'

let tag_storage' db result { trace; _ } =
  match trace.Trace.op with
  | Sload -> FactDb.add_int_rel1 db "uses_storage" result.StackValue.id;
  | _ -> ()
let tag_storage = with_result tag_storage'

let tag_uint_size' db result { trace; args; _ } =
  match trace.Trace.op, args with
  | Op.And, [a; b] ->
    let succ_a = BigInt.add a.StackValue.value BigInt.one in
    if a.StackValue.value < b.StackValue.value &&
      BigInt.is_power succ_a ~power:16 &&
      BigInt.is_power (BigInt.of_int (BigInt.log ~base:16 succ_a)) ~power:2
        then FactDb.add_int_rel2 db "has_uint_size" (result.StackValue.id, BigInt.log ~base:2 succ_a)
  | _ -> ()
let tag_uint_size = with_result tag_uint_size'

let tag_signed db { trace; args; _ } =
  match trace.Trace.op, args with
  | Op.Signextend, [_bits; value] ->
    FactDb.add_int_rel1 db "is_signed_operand" value.StackValue.id
  | (Op.Sdiv | Op.Smod | Op.Slt | Op.Sgt), [a; b] ->
    FactDb.add_int_rel1 db "is_signed_operand" a.StackValue.id;
    FactDb.add_int_rel1 db "is_signed_operand" b.StackValue.id
  | _ -> ()

let tag_int_size db { trace; args; _ } =
  match trace.Trace.op, args with
  | Op.Signextend, [bits; value] ->
    let int_size = ((BigInt.to_int bits.StackValue.value) + 1) * 8 in
    FactDb.add_int_rel2 db "has_int_size" (value.StackValue.id, int_size)
  | _ -> ()

let tag_used_in_condition db { trace; args; _ } =
  match trace.Trace.op, args with
  | Op.Jumpi, [_dest; condition] ->
    FactDb.add_int_rel1 db "used_in_condition" condition.StackValue.id
  | _ -> ()


let tag_overflow ~get_size ~should_check ~cast_value ~name db result { trace; args; _ } =
  let open StackValue in
  let max_value = BigInt.(pow two 256 - one) in
  let is_gas id = FactDb.get_bool db (Printf.sprintf "is_gas(%d)" id) in
  let negated_const id = FactDb.get_bool db (Printf.sprintf "negated_const(%d)" id) in
  let should_do_check result a b =
    should_check result.id
      && not (is_gas a.id || is_gas b.id) (* gas related computation are inserted by the compiler *)
      && not (negated_const a.id || negated_const b.id) (* compiler inserts ADD (NOT CONST) *)
      (* TODO: check for sload/mload *)
  in
  match trace.Trace.op, args with
  | Op.Add, (a :: b :: _)
      when a.value = max_value && b.value = BigInt.of_int 256 -> ()
  | (Op.Add | Op.Sub | Op.Mul | Op.Div | Op.Sdiv | Op.Exp) as op, [a; b]
      when should_do_check result a b ->
    let output_bits = Option.value ~default:256 (get_size result.id) in
    let actual_result = Op.execute_binary_op op a.value b.value in
    let expected_result = cast_value actual_result output_bits in
    if expected_result <> actual_result then
      FactDb.add_int_rel1 db name result.id
  | _ -> ()

let tag_const' db result { trace; _ } =
  match trace.op with
  | Op.Push _ ->
    FactDb.add_int_rel1 db "const" result.StackValue.id
  | _ -> ()
let tag_const = with_result tag_const'


let tag_not' db result { trace; _ } =
  match trace.op with
  | Op.Not -> FactDb.add_int_rel1 db "not" result.StackValue.id
  | _ -> ()
let tag_not = with_result tag_not'


let tag_signed_overflow' db result full_trace =
  let should_check id = FactDb.get_bool db (Printf.sprintf "is_signed(%d)" id) in
  let get_size id = FactDb.get_int db 1 (Printf.sprintf "int_size(%d, N)" id) in
  tag_overflow ~get_size ~should_check ~cast_value:BigInt.twos_complement ~name:"is_signed_overflow"
                db result full_trace
let tag_signed_overflow = with_result tag_signed_overflow'

let tag_unsigned_overflow' db result full_trace =
  let should_check id = FactDb.get_bool db (Printf.sprintf "is_unsigned(%d)" id) in
  let get_size id = FactDb.get_int db 1 (Printf.sprintf "uint_size(%d, N)" id) in
  tag_overflow ~get_size ~should_check ~cast_value:BigInt.limit_bits ~name:"is_unsigned_overflow"
                db result full_trace
let tag_unsigned_overflow = with_result tag_unsigned_overflow'

let tag_failed_call' db result { trace; _ } =
  match trace.op, result.StackValue.value with
  | Op.Call, v when v = BigInt.zero ->
    FactDb.add_int_rel1 db "failed_call" result.StackValue.id
  | _ -> ()
let tag_failed_call = with_result tag_failed_call'

let tag_empty_delegate_call' db result { trace; args; _ } =
  let open StackValue in
  let call_entry_rel = FactDb.get_rel2 "call_entry" ~k1:FactDb.Types.int ~k2:FactDb.Types.bigint_key in
  match trace.op, args, result with
  | (Op.Delegatecall | Op.Staticcall),
        { id = top_id; _ ;} :: { value = address; _; } :: _, { id = result_id; _; } ->
    FactDb.add_rel2 db call_entry_rel (top_id, address);
    FactDb.add_int_rel1 db "call_exit" result_id;
  | _ -> ()
let tag_empty_delegate_call = with_result tag_empty_delegate_call'

let tag_call' db result { trace; env; args; _ } =
  let module T = FactDb.Types in
  let open Op in
  match trace.op, args with
  | (Call | Callcode), (gas :: addr :: value :: _rest)
      when result.StackValue.value = BigInt.one ->
    let db_args = (gas.StackValue.id, env.Env.address, addr.value, value.value) in
    FactDb.add_rel4 db FactDb.Relations.direct_call db_args
  | _ -> ()
let tag_call = with_result tag_call'

let tag_tx_sstore db { trace; env; args; _ } =
  match trace.op, args with
  | Op.Sstore, key :: _ ->
    let db_args = (env.Env.block_number, env.Env.tx_hash, key.value) in
    FactDb.add_rel3 db FactDb.Relations.tx_sstore db_args
  | _ -> ()

let tag_tx_sload db { trace; env; args; _ } =
  match trace.op, args with
  | Op.Sload, key :: _ ->
    let db_args = (env.Env.block_number, env.Env.tx_hash, key.value) in
    FactDb.add_rel3 db FactDb.Relations.tx_sload db_args
  | _ -> ()

let tag_gas' db result { trace; _ } =
  match trace.op with
  | Op.Gas -> FactDb.add_int_rel1 db "is_gas" result.StackValue.id
  | _ -> ()
let tag_gas = with_result tag_gas'


let all = [
  [tag_output;
   tag_storage;
   tag_uint_size;
   tag_used_in_condition;
   tag_signed;
   tag_int_size;
   tag_failed_call;
   tag_empty_delegate_call;
   tag_call;
   tag_const;
   tag_not;
  ];

  [tag_signed_overflow;
   tag_unsigned_overflow;
  ]
]

let for_vulnerability vulnerability_type = match vulnerability_type with
  | "integer-overflow" ->
    [[tag_output; tag_uint_size; tag_int_size; tag_signed;
      tag_gas; tag_const; tag_not];
     [tag_signed_overflow; tag_unsigned_overflow]]
  | "unhandled-exception" ->
    [[tag_failed_call; tag_used_in_condition;]]
  | "reentrancy" ->
    [[tag_call;]]
  | "locked-ether" ->
    [[tag_empty_delegate_call;]]
  | "tod" ->
    [[tag_tx_sload; tag_tx_sstore;]]
  | _ -> failwithf "unknown vulnerability %s" vulnerability_type ()
