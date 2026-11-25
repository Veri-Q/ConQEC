const WITNESS_SCHEMA_VERSION = "conqec-witness-v1"
const WITNESS_GENERATOR = "ConQEC.jl AE prototype"
const WITNESS_SOLVER_BACKEND = "bruteforce_boolean"

function earliest_divergence(trace::ConcolicTrace)
    explicit = get(trace.metadata, "earliest_divergence_stage", nothing)
    if explicit !== nothing
        stage = Symbol(explicit)
        stage in DIVERGENCE_STAGES && return string(stage)
    end

    get(trace.logical_verdicts, "fault_mismatch", false) && return "fault"
    get(trace.logical_verdicts, "history_mismatch", false) &&
        return "repeated_round_control"
    get(trace.logical_verdicts, "inconsistent_control", false) &&
        return "repeated_round_control"
    get(trace.logical_verdicts, "measurement_misuse", false) &&
        return "measurement_result"
    get(trace.logical_verdicts, "syndrome_mismatch", false) && return "syndrome"
    get(trace.logical_verdicts, "decoder_mismatch", false) && return "decoder"
    get(trace.logical_verdicts, "recovery_mismatch", false) && return "recovery"
    get(trace.logical_verdicts, "logical_mismatch", false) && return "logical_check"
    return "unknown"
end

function branch_dict(guard::BranchGuard)
    return Dict{String,Any}(
        "id" => guard.id,
        "stage" => string(guard.stage),
        "condition" => expr_to_string(guard.condition),
        "taken" => guard.taken,
        "concrete_value" => guard.concrete_value,
        "description" => guard.description,
        "path_constraint" => guard.path_constraint,
        "source" => string(guard.source),
    )
end

function default_exploration_policy()
    return Dict{String,Any}(
        "worklist" => "fifo",
        "branch_flip_order" => "qec_priority",
        "branch_priority_levels" => [
            "positive_witness_branch_trace_distance",
            "failure_adjacent_stage",
            "unseen_syndrome",
            "lower_fault_weight",
            "trace_order",
        ],
        "path_constraints" => "flip_one_recorded_path_guard_keep_full_path",
    )
end

function default_witness_minimization(trace::ConcolicTrace)
    weight = count(entry -> get(entry, "active", false), fault_pattern(trace))
    return Dict{String,Any}(
        "strategy" => "not_attempted",
        "original_fault_weight" => weight,
        "minimized_fault_weight" => weight,
        "removed_faults" => String[],
        "replay_consistent" => nothing,
    )
end

function build_witness(trace::ConcolicTrace;
    exploration_settings=Dict{String,Any}(),
    primary_oracle=nothing)

    triggered_oracles = triggered_failure_oracles(trace)
    triggered_ids = [String(oracle["id"]) for oracle in triggered_oracles]
    primary_oracle_record = failure_oracle_record(primary_oracle)
    normalized_settings = Dict{String,Any}(
        string(key) => value for (key, value) in exploration_settings
    )
    solver_backend = string(get(
        normalized_settings,
        "solver_backend",
        WITNESS_SOLVER_BACKEND,
    ))

    return Dict{String,Any}(
        "schema_version" => WITNESS_SCHEMA_VERSION,
        "generated_by" => WITNESS_GENERATOR,
        "solver_backend" => solver_backend,
        "exploration_policy" => default_exploration_policy(),
        "exploration_settings" => normalized_settings,
        "subject_name" => trace.subject_name,
        "code_size" => trace.code_size,
        "distance" => trace.distance,
        "fault_pattern" => fault_pattern(trace),
        "observed_syndrome" => Dict{String,Any}(trace.syndrome_values),
        "decoder_output" => get(trace.decoder_decisions, "actual", nothing),
        "expected_decoder_output" => get(trace.decoder_decisions, "expected", nothing),
        "recovery_actually_applied" => copy(trace.recovery_actions),
        "expected_recovery" => get(trace.metadata, "expected_recovery", nothing),
        "logical_verdicts" => copy(trace.logical_verdicts),
        "oracle_verdict" => get(trace.logical_verdicts, "oracle_verdict", nothing),
        "primary_oracle" => primary_oracle_record,
        "triggered_oracles" => triggered_oracles,
        "oracle_summary" => Dict{String,Any}(
            "triggered" => !isempty(triggered_ids),
            "triggered_count" => length(triggered_ids),
            "triggered_ids" => triggered_ids,
            "summary" => isempty(triggered_ids) ? "none" : join(triggered_ids, "+"),
        ),
        "oracle_witnesses" => oracle_witnesses(trace),
        "relational_counterexample" =>
            get(trace.metadata, "relational_counterexample", nothing),
        "earliest_divergence_stage" => earliest_divergence(trace),
        "path" => [branch_dict(guard) for guard in trace.branch_guards],
        "metadata" => copy(trace.metadata),
        "minimization" => default_witness_minimization(trace),
    )
end

function escape_json(s::AbstractString)
    out = replace(String(s), "\\" => "\\\\")
    out = replace(out, "\"" => "\\\"")
    out = replace(out, "\n" => "\\n")
    out = replace(out, "\r" => "\\r")
    out = replace(out, "\t" => "\\t")
    return out
end

function json_value(value, level::Int, indent::Int)
    pad = repeat(" ", level)
    child_pad = repeat(" ", level + indent)

    if value === nothing
        return "null"
    elseif value isa Bool
        return value ? "true" : "false"
    elseif value isa Integer || value isa AbstractFloat
        return string(value)
    elseif value isa Symbol
        return "\"" * escape_json(string(value)) * "\""
    elseif value isa AbstractString
        return "\"" * escape_json(value) * "\""
    elseif value isa BoolExpr
        return "\"" * escape_json(expr_to_string(value)) * "\""
    elseif value isa AbstractDict
        isempty(value) && return "{}"
        keys_sorted = sort!(collect(keys(value)), by=string)
        parts = String[]
        for key in keys_sorted
            key_s = "\"" * escape_json(string(key)) * "\": "
            push!(parts, child_pad * key_s * json_value(value[key], level + indent, indent))
        end
        return "{\n" * join(parts, ",\n") * "\n" * pad * "}"
    elseif value isa AbstractVector || value isa Tuple
        isempty(value) && return "[]"
        parts = [child_pad * json_value(item, level + indent, indent) for item in value]
        return "[\n" * join(parts, ",\n") * "\n" * pad * "]"
    end

    return "\"" * escape_json(string(value)) * "\""
end

json_string(value; indent=2) = json_value(value, 0, indent)

function write_witness(path::AbstractString, witness::AbstractDict)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, json_string(witness))
        write(io, "\n")
    end
    return path
end
