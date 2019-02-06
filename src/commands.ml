open Core

let opcodes_command ?output ~show_pc ~show_sourcemap input_file =
  let program =
    if input_file = "-"
      then Program.of_channel In_channel.stdin
      else Program.from_file input_file
  in
  let stringified = Program.format_ops ~show_pc ~show_sourcemap program in
  match output with
  | Some filepath -> Out_channel.write_all filepath ~data:stringified
  | None -> Out_channel.output_string Out_channel.stdout stringified


let analyze_traces ~debug ~contract_address filepath query =
  let json = Yojson.Safe.from_file filepath in
  let struct_logs = Yojson.Safe.Util.member "structLogs" json in
  let traces = TraceParser.parse_json struct_logs in
  let contract_address = Option.value ~default:"0x0" contract_address in
  let tracer = Tracer.create contract_address Taggers.all in
  let db = Tracer.execute_traces ~debug tracer traces in
  let trace_indexes = FactDb.query1 db (FactDb.get_rel1 ~k:FactDb.Types.int query) in
  let traces = List.map ~f:(Fn.flip Yojson.Safe.Util.index struct_logs) trace_indexes in
  List.iter ~f:(Fn.compose print_endline Yojson.Safe.to_string) traces


let analyze_vulnerabilities ~output ~addresses vulnerability =
  let addresses = match addresses with
  | [] -> None
  | list -> Some list
  in
  let result = VulnerabilityAnalyzer.analyze_vulnerabilities ~output ?addresses vulnerability in
  PgMonad.full_run result
