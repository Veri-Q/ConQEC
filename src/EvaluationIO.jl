const ICSE_RAW_SCHEMA_VERSION = "conqec-icse-eval-row-v1"

const ICSE_RAW_ROW_FIELDS = [
    "schema_version",
    "experiment",
    "timestamp",
    "git_commit",
    "julia_version",
    "os",
    "backend",
    "backend_preset",
    "optimization_layers",
    "solver_path",
    "solver_version",
    "subject",
    "bug_id",
    "bug_class",
    "hardness_bin",
    "exhaustibility_ratio",
    "baseline",
    "seed",
    "mode",
    "priority_profile",
    "budget",
    "test_index",
    "generated_test_index",
    "generated_fault",
    "syndrome",
    "decoder",
    "recovery",
    "oracle",
    "earliest_divergence",
    "found",
    "first_failure_trial",
    "replay_success",
    "diagnostic_contract_match",
    "fault_weight_before",
    "fault_weight_after",
    "coverage_s",
    "coverage_d",
    "coverage_r",
    "coverage_b",
    "coverage_fsr",
    "coverage_fsdr",
    "query_bytes",
    "query_hash",
    "solver_status",
    "solve_time_ms",
    "timeout",
]

function icse_timestamp()
    return string(round(Int, time()))
end

function icse_os_string()
    return string(Sys.KERNEL, "-", Sys.MACHINE)
end

function normalized_fault_pattern(trace::ConcolicTrace)
    active = String[]
    for var in trace.fault_vars
        model_bool(trace.fault_assignments, var) && push!(active, string(var))
    end
    sort!(active)
    return isempty(active) ? "clean" : join(active, "+")
end

function normalized_fault_pattern(model::AbstractDict)
    active = String[]
    for key in keys(model)
        Bool(model[key]) && push!(active, string(key))
    end
    sort!(active)
    return isempty(active) ? "clean" : join(active, "+")
end

decoder_output_key(trace::ConcolicTrace) =
    canonical_value_string(get(trace.decoder_decisions, "actual", "none"))

function recovery_action_key(trace::ConcolicTrace)
    return recovery_signature(trace)
end

function branch_id_key(trace::ConcolicTrace)
    ids = sort!(String[guard.id for guard in trace.branch_guards])
    return isempty(ids) ? "none" : join(ids, "+")
end

function branch_source_key(guard::BranchGuard)
    source = branch_control_group(guard)
    return isempty(source) ? string(guard.stage) : source
end

function path_branch_source_counts(trace::ConcolicTrace)
    counts = Dict{String,Int}()
    for guard in trace.branch_guards
        guard.path_constraint || continue
        source = branch_source_key(guard)
        counts[source] = get(counts, source, 0) + 1
    end
    return counts
end

function path_branch_source_counts_string(trace::ConcolicTrace)
    counts = path_branch_source_counts(trace)
    isempty(counts) && return "none"
    return join(
        [
            source * "=" * string(counts[source])
            for source in sort!(collect(keys(counts)))
        ],
        ";",
    )
end

function path_branch_provenance_counts(trace::ConcolicTrace)
    counts = Dict{String,Int}()
    for guard in trace.branch_guards
        guard.path_constraint || continue
        source = string(guard.source)
        counts[source] = get(counts, source, 0) + 1
    end
    return counts
end

function path_branch_provenance_counts_string(trace::ConcolicTrace)
    counts = path_branch_provenance_counts(trace)
    isempty(counts) && return "none"
    return join(
        [
            source * "=" * string(counts[source])
            for source in sort!(collect(keys(counts)))
        ],
        ";",
    )
end

fsr_tuple_key(trace::ConcolicTrace) =
    normalized_fault_pattern(trace) * "|" * syndrome_key(trace) * "|" *
    recovery_action_key(trace)

fsdr_tuple_key(trace::ConcolicTrace) =
    syndrome_key(trace) * "|" * decoder_output_key(trace) * "|" *
    recovery_action_key(trace)

function first_failure_trial(traces)
    for (idx, trace) in enumerate(traces)
        trace_has_bug(trace) && return idx
    end
    return nothing
end

function cumulative_semantic_coverage(traces)
    syndromes = Set{String}()
    decoders = Set{String}()
    recoveries = Set{String}()
    branch_ids_seen = Set{String}()
    fsr = Set{String}()
    fsdr = Set{String}()
    records = Dict{String,Int}[]
    for trace in traces
        push!(syndromes, syndrome_key(trace))
        push!(decoders, decoder_output_key(trace))
        push!(recoveries, recovery_action_key(trace))
        for guard in trace.branch_guards
            push!(branch_ids_seen, guard.id)
        end
        push!(fsr, fsr_tuple_key(trace))
        push!(fsdr, fsdr_tuple_key(trace))
        push!(records, Dict{String,Int}(
            "coverage_s" => length(syndromes),
            "coverage_d" => length(decoders),
            "coverage_r" => length(recoveries),
            "coverage_b" => length(branch_ids_seen),
            "coverage_fsr" => length(fsr),
            "coverage_fsdr" => length(fsdr),
        ))
    end
    return records
end

function coverage_auc(records::AbstractVector, key::AbstractString)
    return sum(Int(get(record, key, 0)) for record in records; init=0)
end

function trace_query_metadata(trace::ConcolicTrace)
    metadata = get(trace.metadata, "input_solver_query", nothing)
    metadata isa AbstractDict || return Dict{String,Any}()
    return Dict{String,Any}(metadata)
end

function solver_status_from_query(metadata::AbstractDict)
    return string(get(metadata, "solver_status", get(metadata, "status", "not_applicable")))
end

function solve_time_from_query(metadata::AbstractDict)
    value = get(metadata, "solve_time_ms", 0.0)
    parsed = tryparse(Float64, string(value))
    return parsed === nothing ? 0.0 : parsed
end

function query_bytes_from_query(metadata::AbstractDict)
    value = get(metadata, "query_bytes", 0)
    parsed = tryparse(Int, string(value))
    return parsed === nothing ? 0 : parsed
end

function timeout_from_query(metadata::AbstractDict)
    status = uppercase(solver_status_from_query(metadata))
    return status == "TIMEOUT" || Bool(get(metadata, "timeout", false))
end

function query_field_from_query(metadata::AbstractDict, keys...; default="n/a")
    for key in keys
        haskey(metadata, key) && return metadata[key]
    end
    return default
end

function raw_row_defaults()
    return Dict{String,Any}(
        "schema_version" => ICSE_RAW_SCHEMA_VERSION,
        "experiment" => "unknown",
        "timestamp" => icse_timestamp(),
        "git_commit" => "unknown",
        "julia_version" => string(VERSION),
        "os" => icse_os_string(),
        "backend" => "unknown",
        "backend_preset" => "unknown",
        "optimization_layers" => "unknown",
        "solver_path" => "unknown",
        "solver_version" => "unknown",
        "subject" => "unknown",
        "bug_id" => "none",
        "bug_class" => "clean",
        "hardness_bin" => "unknown",
        "exhaustibility_ratio" => 0.0,
        "baseline" => "unknown",
        "seed" => 0,
        "mode" => "unknown",
        "priority_profile" => "unknown",
        "budget" => 0,
        "test_index" => 0,
        "generated_test_index" => 0,
        "generated_fault" => "none",
        "syndrome" => "none",
        "decoder" => "none",
        "recovery" => "none",
        "oracle" => "none",
        "earliest_divergence" => "none",
        "found" => false,
        "first_failure_trial" => "none",
        "replay_success" => "n/a",
        "diagnostic_contract_match" => "n/a",
        "fault_weight_before" => 0,
        "fault_weight_after" => 0,
        "coverage_s" => 0,
        "coverage_d" => 0,
        "coverage_r" => 0,
        "coverage_b" => 0,
        "coverage_fsr" => 0,
        "coverage_fsdr" => 0,
        "query_bytes" => 0,
        "query_hash" => "n/a",
        "solver_status" => "not_applicable",
        "solve_time_ms" => 0.0,
        "timeout" => false,
    )
end

function complete_raw_row(values::AbstractDict)
    row = raw_row_defaults()
    for (key, value) in values
        row[string(key)] = value
    end
    haskey(values, "generated_test_index") ||
        haskey(values, :generated_test_index) ||
        (row["generated_test_index"] = get(row, "test_index", 0))
    for field in ICSE_RAW_ROW_FIELDS
        haskey(row, field) || error("missing ICSE raw field $(field)")
    end
    return row
end

function trace_raw_rows(traces;
    experiment::AbstractString,
    context::AbstractDict,
    subject::AbstractString,
    bug_id::AbstractString="none",
    bug_class::AbstractString="clean",
    baseline::AbstractString,
    seed::Integer=0,
    mode::AbstractString=experiment == "rq1_coverage" ? "coverage" : "bugfinding",
    priority_profile::AbstractString=mode == "coverage" ? "coverage" : "bugfinding",
    budget::Integer,
    replay_success="n/a",
    diagnostic_contract_match="n/a",
    fault_weight_before=0,
    fault_weight_after=0,
    extras=Dict{String,Any}())

    coverage = cumulative_semantic_coverage(traces)
    first_failure = first_failure_trial(traces)
    rows = Dict{String,Any}[]
    for (idx, trace) in enumerate(traces)
        query = trace_query_metadata(trace)
        oracle_ids = triggered_failure_oracle_ids(trace)
        row = complete_raw_row(merge(
            Dict{String,Any}(
                "experiment" => experiment,
                "timestamp" => get(context, "timestamp", icse_timestamp()),
                "git_commit" => get(context, "git_commit", "unknown"),
                "julia_version" => get(context, "julia_version", string(VERSION)),
                "os" => get(context, "os", icse_os_string()),
                "backend" => get(context, "backend", "unknown"),
                "backend_preset" => get(context, "backend_preset", "unknown"),
                "optimization_layers" => get(context, "optimization_layers", "unknown"),
                "solver_path" => get(context, "solver_path", "unknown"),
                "solver_version" => get(context, "solver_version", "unknown"),
                "subject" => subject,
                "bug_id" => bug_id,
                "bug_class" => bug_class,
                "hardness_bin" => get(extras, "hardness_bin", "unknown"),
                "exhaustibility_ratio" => get(extras, "exhaustibility_ratio", 0.0),
                "baseline" => baseline,
                "seed" => Int(seed),
                "mode" => String(mode),
                "priority_profile" => String(priority_profile),
                "budget" => Int(budget),
                "test_index" => idx,
                "generated_test_index" => idx,
                "generated_fault" => normalized_fault_pattern(trace),
                "syndrome" => syndrome_key(trace),
                "decoder" => decoder_output_key(trace),
                "recovery" => recovery_action_key(trace),
                "oracle" => isempty(oracle_ids) ? "none" : join(oracle_ids, "+"),
                "earliest_divergence" =>
                    trace_has_bug(trace) ? earliest_divergence(trace) : "none",
                "found" => trace_has_bug(trace),
                "first_failure_trial" =>
                    first_failure === nothing ? "none" : string(first_failure),
                "replay_success" => replay_success,
                "diagnostic_contract_match" => diagnostic_contract_match,
                "fault_weight_before" => fault_weight_before,
                "fault_weight_after" => fault_weight_after,
                "query_bytes" => query_bytes_from_query(query),
                "query_hash" => query_field_from_query(query,
                    "query_hash", "query_full_hash", "full_query_hash"),
                "solver_status" => solver_status_from_query(query),
                "solve_time_ms" => solve_time_from_query(query),
                "timeout" => timeout_from_query(query),
                "query_branch_index" => query_field_from_query(query,
                    "branch_index", "selected_branch_index"),
                "query_branch_rank" => query_field_from_query(query,
                    "branch_rank", "parallel_branch_rank"),
                "query_candidate_branch_count" => query_field_from_query(query,
                    "candidate_branch_count"),
                "query_selected_branch_id" => query_field_from_query(query,
                    "selected_branch_id"),
                "query_selected_branch_stage" => query_field_from_query(query,
                    "selected_branch_stage"),
                "query_selected_branch_source" => query_field_from_query(query,
                    "selected_branch_source"),
                "query_selected_branch_provenance" => query_field_from_query(query,
                    "selected_branch_provenance"),
                "query_priority_profile" => query_field_from_query(query,
                    "priority_profile"),
                "query_priority_reason" => query_field_from_query(query,
                    "priority_reason"),
                "path_branch_count" => count(guard -> guard.path_constraint, trace.branch_guards),
                "path_branch_sources" => path_branch_source_counts_string(trace),
                "path_branch_provenance" => path_branch_provenance_counts_string(trace),
            ),
            coverage[idx],
            Dict{String,Any}(extras),
        ))
        push!(rows, row)
    end
    return rows
end

function compact_json_value(value)
    if value === nothing
        return "null"
    elseif value isa Bool
        return value ? "true" : "false"
    elseif value isa Integer || value isa AbstractFloat
        return string(value)
    elseif value isa Symbol
        return "\"" * escape_json(string(value)) * "\""
    elseif value isa AbstractString
        return "\"" * escape_json(String(value)) * "\""
    elseif value isa AbstractDict
        parts = String[]
        for key in sort!(collect(keys(value)), by=string)
            push!(parts, compact_json_value(string(key)) * ":" * compact_json_value(value[key]))
        end
        return "{" * join(parts, ",") * "}"
    elseif value isa AbstractVector || value isa Tuple
        return "[" * join(compact_json_value.(value), ",") * "]"
    end
    return "\"" * escape_json(string(value)) * "\""
end

compact_json_string(value) = compact_json_value(value)

function write_jsonl(path::AbstractString, rows::AbstractVector)
    mkpath(dirname(path))
    open(path, "w") do io
        for row in rows
            write(io, compact_json_string(row))
            write(io, "\n")
        end
    end
    return path
end

function append_jsonl(path::AbstractString, rows::AbstractVector)
    mkpath(dirname(path))
    open(path, "a") do io
        for row in rows
            write(io, compact_json_string(row))
            write(io, "\n")
        end
    end
    return path
end

function _parse_json_string(text::AbstractString, idx::Int)
    text[idx] == '"' || error("expected JSON string at byte $(idx)")
    idx += 1
    out = IOBuffer()
    while idx <= lastindex(text)
        ch = text[idx]
        if ch == '"'
            return String(take!(out)), idx + 1
        elseif ch == '\\'
            idx += 1
            idx <= lastindex(text) || error("unterminated JSON escape")
            esc = text[idx]
            if esc == 'n'
                write(out, '\n')
            elseif esc == 'r'
                write(out, '\r')
            elseif esc == 't'
                write(out, '\t')
            else
                write(out, esc)
            end
        else
            write(out, ch)
        end
        idx += 1
    end
    error("unterminated JSON string")
end

function _skip_ws(text::AbstractString, idx::Int)
    while idx <= lastindex(text) && text[idx] in (' ', '\t', '\r', '\n')
        idx += 1
    end
    return idx
end

function _parse_json_scalar(text::AbstractString, idx::Int)
    idx = _skip_ws(text, idx)
    idx <= lastindex(text) || error("unexpected end of JSON scalar")
    if text[idx] == '"'
        return _parse_json_string(text, idx)
    end
    start = idx
    while idx <= lastindex(text) && !(text[idx] in (',', '}'))
        idx += 1
    end
    token = strip(text[start:idx - 1])
    token == "true" && return true, idx
    token == "false" && return false, idx
    token == "null" && return nothing, idx
    if occursin(".", token)
        parsed = tryparse(Float64, token)
        parsed === nothing || return parsed, idx
    else
        parsed_int = tryparse(Int, token)
        parsed_int === nothing || return parsed_int, idx
        parsed_float = tryparse(Float64, token)
        parsed_float === nothing || return parsed_float, idx
    end
    return token, idx
end

function parse_jsonl_object(line::AbstractString)
    text = strip(String(line))
    isempty(text) && return Dict{String,Any}()
    idx = _skip_ws(text, firstindex(text))
    text[idx] == '{' || error("JSONL row is not an object")
    idx += 1
    row = Dict{String,Any}()
    while true
        idx = _skip_ws(text, idx)
        idx > lastindex(text) && error("unterminated JSON object")
        text[idx] == '}' && return row
        key, idx = _parse_json_string(text, idx)
        idx = _skip_ws(text, idx)
        text[idx] == ':' || error("expected ':' after JSON key $(key)")
        idx += 1
        value, idx = _parse_json_scalar(text, idx)
        row[key] = value
        idx = _skip_ws(text, idx)
        if text[idx] == ','
            idx += 1
        elseif text[idx] == '}'
            return row
        else
            error("expected ',' or '}' in JSON object")
        end
    end
end

function read_jsonl(path::AbstractString)
    rows = Dict{String,Any}[]
    isfile(path) || return rows
    for line in eachline(path)
        isempty(strip(line)) && continue
        push!(rows, parse_jsonl_object(line))
    end
    return rows
end

function read_jsonl_dir(raw_dir::AbstractString)
    rows = Dict{String,Any}[]
    isdir(raw_dir) || return rows
    for path in sort!(filter(endswith(".jsonl"), readdir(raw_dir; join=true)))
        append!(rows, read_jsonl(path))
    end
    return rows
end

function latex_escape(value::AbstractString)
    text = String(value)
    replacements = [
        "\\" => "\\textbackslash{}",
        "&" => "\\&",
        "%" => "\\%",
        "\$" => "\\\$",
        "#" => "\\#",
        "_" => "\\_",
        "{" => "\\{",
        "}" => "\\}",
        "~" => "\\textasciitilde{}",
        "^" => "\\textasciicircum{}",
    ]
    for (from, to) in replacements
        text = replace(text, from => to)
    end
    return text
end

function write_latex_table(path::AbstractString, caption::AbstractString,
    label::AbstractString, headers::Vector{String}, rows::Vector{Vector{String}};
    source::AbstractString="raw JSONL")

    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "% Generated from ", source, "; do not edit by hand.")
        println(io, "\\begin{table}[t]")
        println(io, "\\centering")
        println(io, "\\caption{", latex_escape(caption), "}")
        println(io, "\\label{", latex_escape(label), "}")
        println(io, "\\begin{tabular}{", repeat("l", length(headers)), "}")
        println(io, "\\toprule")
        println(io, join(latex_escape.(headers), " & "), " \\\\")
        println(io, "\\midrule")
        for row in rows
            println(io, join(latex_escape.(row), " & "), " \\\\")
        end
        println(io, "\\bottomrule")
        println(io, "\\end{tabular}")
        println(io, "\\end{table}")
    end
    return path
end

function csv_escape(value::AbstractString)
    if any(ch -> ch in (',', '"', '\n', '\r'), value)
        return "\"" * replace(value, "\"" => "\"\"") * "\""
    end
    return value
end

function write_csv_table(path::AbstractString, headers::Vector{String}, rows::Vector{Vector{String}})
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, join(csv_escape.(headers), ","))
        for row in rows
            println(io, join(csv_escape.(row), ","))
        end
    end
    return path
end
