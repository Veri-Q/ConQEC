struct FailureOracleDefinition
    id::String
    name::String
    verdict_key::String
    description::String
end

const FAILURE_ORACLE_DEFINITIONS = (
    FailureOracleDefinition(
        "O1_LOGICAL_MISMATCH",
        "Logical mismatch",
        "logical_mismatch",
        "residual error changes the decoded logical value",
    ),
    FailureOracleDefinition(
        "O2_DECODER_MISMATCH",
        "Decoder mismatch",
        "decoder_mismatch",
        "decoder decision disagrees with the reference decoder on a matching syndrome trace",
    ),
    FailureOracleDefinition(
        "O3_RESIDUAL_CORRECTABLE_ERROR",
        "Residual correctable error",
        "residual_error",
        "a correctable input fault leaves residual physical error after recovery",
    ),
    FailureOracleDefinition(
        "O4_DEAD_RECOVERY_BRANCH",
        "Dead recovery branch",
        "missing_recovery_branch",
        "a reachable syndrome has no implemented recovery arm",
    ),
    FailureOracleDefinition(
        "O5_INCONSISTENT_CONTROL",
        "Inconsistent control behavior",
        "inconsistent_control",
        "the same recorded control state is not used consistently for recovery selection",
    ),
)

failure_oracle_definitions() = collect(FAILURE_ORACLE_DEFINITIONS)

function failure_oracle_by_id(id::AbstractString)
    requested = String(id)
    for oracle in FAILURE_ORACLE_DEFINITIONS
        oracle.id == requested && return oracle
    end
    error("unknown failure oracle id: $(id)")
end

primary_oracle_id(::Nothing) = nothing
primary_oracle_id(oracle::FailureOracleDefinition) = oracle.id
primary_oracle_id(oracle::AbstractString) = String(oracle)
primary_oracle_id(oracle::AbstractDict) =
    haskey(oracle, "id") ? String(oracle["id"]) : nothing

function failure_oracle_record(oracle)
    oracle === nothing && return nothing
    if oracle isa FailureOracleDefinition
        return _oracle_dict(oracle)
    elseif oracle isa AbstractString
        return _oracle_dict(failure_oracle_by_id(oracle))
    elseif oracle isa AbstractDict
        id = primary_oracle_id(oracle)
        id === nothing && error("oracle record is missing id")
        definition = failure_oracle_by_id(id)
        return Dict{String,Any}(
            "id" => id,
            "name" => String(get(oracle, "name", definition.name)),
            "verdict_key" => String(get(oracle, "verdict_key", definition.verdict_key)),
            "description" => String(get(oracle, "description", definition.description)),
        )
    end
    error("unsupported failure oracle record: $(typeof(oracle))")
end

function _verdict_bool(verdicts::AbstractDict, key::AbstractString)
    return get(verdicts, String(key), false) === true
end

function residual_error_weight(verdicts::AbstractDict)
    explicit = get(verdicts, "residual_weight", nothing)
    explicit isa Integer && return Int(explicit)

    residual = get(verdicts, "residual_error", nothing)
    residual isa AbstractDict &&
        return count(value -> value === true, values(residual))
    residual isa AbstractVector &&
        return count(value -> value === true, residual)
    return 0
end

function correction_capacity(distance)
    distance === nothing && return nothing
    distance isa Integer || return nothing
    distance <= 0 && return nothing
    return fld(Int(distance) - 1, 2)
end

function input_fault_weight(trace::ConcolicTrace)
    return fault_weight(trace.fault_assignments, trace.fault_vars)
end

function input_fault_weight(witness::AbstractDict)
    pattern = get(witness, "fault_pattern", nothing)
    pattern isa AbstractVector || return 0
    return count(pattern) do item
        item isa AbstractDict && get(item, "active", false) === true
    end
end

function _distance_from_witness(witness::AbstractDict)
    distance = get(witness, "distance", nothing)
    distance isa Integer && return Int(distance)
    return nothing
end

function _correctable_input(fault_weight_value::Integer, distance)
    capacity = correction_capacity(distance)
    capacity === nothing && return fault_weight_value <= 1
    return fault_weight_value <= capacity
end

function _oracle_triggered(oracle::FailureOracleDefinition,
    verdicts::AbstractDict,
    fault_weight_value::Integer,
    distance)

    if oracle.id == "O1_LOGICAL_MISMATCH"
        return _verdict_bool(verdicts, "logical_mismatch")
    elseif oracle.id == "O2_DECODER_MISMATCH"
        return _verdict_bool(verdicts, "decoder_mismatch") &&
            !_verdict_bool(verdicts, "syndrome_mismatch") &&
            !_verdict_bool(verdicts, "measurement_misuse")
    elseif oracle.id == "O3_RESIDUAL_CORRECTABLE_ERROR"
        return residual_error_weight(verdicts) > 0 &&
            _correctable_input(fault_weight_value, distance)
    elseif oracle.id == "O4_DEAD_RECOVERY_BRANCH"
        return _verdict_bool(verdicts, "missing_recovery_branch")
    elseif oracle.id == "O5_INCONSISTENT_CONTROL"
        return _verdict_bool(verdicts, "inconsistent_control")
    end
    return false
end

mutable struct RelationalOracleState
    first_by_control::Dict{String,Dict{String,Any}}
end

RelationalOracleState() = RelationalOracleState(Dict{String,Dict{String,Any}}())

function canonical_value_string(value)
    value === nothing && return "null"
    value isa Bool && return value ? "true" : "false"
    value isa Integer && return string(value)
    value isa AbstractString && return String(value)
    value isa Symbol && return string(value)
    if value isa AbstractDict
        parts = String[]
        for key in sort!(collect(keys(value)), by=string)
            push!(parts, string(key) * "=" * canonical_value_string(value[key]))
        end
        return "{" * join(parts, ",") * "}"
    elseif value isa AbstractVector || value isa Tuple
        return "[" * join(canonical_value_string.(value), ",") * "]"
    end
    return string(value)
end

function recovery_signature(trace::ConcolicTrace)
    return canonical_value_string(trace.recovery_actions)
end

function trace_decoder_state_key(trace::ConcolicTrace)
    explicit = get(trace.metadata, "decoder_state_key", nothing)
    explicit !== nothing && return String(explicit)
    return canonical_value_string(get(trace.decoder_decisions, "actual", "none"))
end

function trace_control_state_key(trace::ConcolicTrace)
    explicit = get(trace.metadata, "control_state_key", nothing)
    explicit !== nothing && return String(explicit)
    return "syndrome=" * syndrome_key(trace) *
        ";decoder_state=" * trace_decoder_state_key(trace)
end

function trace_fault_assignment_record(trace::ConcolicTrace)
    return Dict{String,Any}(
        string(var) => model_bool(trace.fault_assignments, var)
        for var in trace.fault_vars
    )
end

function relational_oracle_snapshot(trace::ConcolicTrace, trace_index::Integer)
    return Dict{String,Any}(
        "trace_index" => Int(trace_index),
        "subject_name" => trace.subject_name,
        "fault_assignments" => trace_fault_assignment_record(trace),
        "fault_pattern" => fault_pattern(trace),
        "observed_syndrome" => Dict{String,Any}(trace.syndrome_values),
        "decoder_output" => get(trace.decoder_decisions, "actual", nothing),
        "decoder_state_key" => trace_decoder_state_key(trace),
        "recovery_actions" => copy(trace.recovery_actions),
        "recovery_signature" => recovery_signature(trace),
    )
end

function apply_relational_oracles!(state::RelationalOracleState,
    trace::ConcolicTrace,
    trace_index::Integer)

    isempty(trace.recovery_actions) && return trace
    control_key = trace_control_state_key(trace)
    current = relational_oracle_snapshot(trace, trace_index)
    prior = get(state.first_by_control, control_key, nothing)
    if prior === nothing
        state.first_by_control[control_key] = current
        return trace
    end

    if String(prior["recovery_signature"]) != String(current["recovery_signature"])
        record_logical_verdict!(trace, "inconsistent_control", true)
        record_logical_verdict!(trace, "oracle_verdict", false)
        haskey(trace.metadata, "earliest_divergence_stage") ||
            (trace.metadata["earliest_divergence_stage"] = "repeated_round_control")
        trace.metadata["relational_counterexample"] = Dict{String,Any}(
            "control_state" => control_key,
            "prior" => prior,
            "current" => current,
        )
    end
    return trace
end

function _oracle_dict(oracle::FailureOracleDefinition)
    return Dict{String,Any}(
        "id" => oracle.id,
        "name" => oracle.name,
        "verdict_key" => oracle.verdict_key,
        "description" => oracle.description,
    )
end

function _triggered_failure_oracles_from_verdicts(verdicts::AbstractDict;
    fault_weight_value::Integer=0,
    distance=nothing)

    triggered = Dict{String,Any}[]
    for oracle in FAILURE_ORACLE_DEFINITIONS
        _oracle_triggered(oracle, verdicts, fault_weight_value, distance) ||
            continue
        push!(triggered, _oracle_dict(oracle))
    end
    return triggered
end

function triggered_failure_oracles(trace::ConcolicTrace)
    return _triggered_failure_oracles_from_verdicts(
        trace.logical_verdicts;
        fault_weight_value=input_fault_weight(trace),
        distance=trace.distance,
    )
end

function triggered_failure_oracles(value::AbstractDict;
    fault_weight_value=nothing,
    distance=nothing)

    if haskey(value, "logical_verdicts")
        verdicts = get(value, "logical_verdicts", Dict{String,Any}())
        verdicts isa AbstractDict || return Dict{String,Any}[]
        return _triggered_failure_oracles_from_verdicts(
            verdicts;
            fault_weight_value=fault_weight_value === nothing ?
                input_fault_weight(value) : Int(fault_weight_value),
            distance=distance === nothing ? _distance_from_witness(value) : distance,
        )
    end

    return _triggered_failure_oracles_from_verdicts(
        value;
        fault_weight_value=fault_weight_value === nothing ? 0 : Int(fault_weight_value),
        distance=distance,
    )
end

triggered_failure_oracle_ids(value) =
    [String(oracle["id"]) for oracle in triggered_failure_oracles(value)]

function stored_triggered_failure_oracle_ids(witness::AbstractDict)
    stored = get(witness, "triggered_oracles", nothing)
    stored isa AbstractVector || return String[]

    ids = String[]
    for item in stored
        item isa AbstractDict || continue
        id = get(item, "id", nothing)
        id === nothing && continue
        push!(ids, String(id))
    end
    return ids
end

function stored_oracle_summary_text(witness::AbstractDict)
    summary = get(witness, "oracle_summary", nothing)
    if summary isa AbstractDict
        value = get(summary, "summary", nothing)
        value === nothing || return String(value)
    end
    ids = stored_triggered_failure_oracle_ids(witness)
    return isempty(ids) ? "none" : join(ids, "+")
end

function stored_primary_failure_oracle_id(witness::AbstractDict)
    primary = get(witness, "primary_oracle", nothing)
    primary isa AbstractDict || return nothing
    id = get(primary, "id", nothing)
    id === nothing && return nothing
    return String(id)
end

failure_oracle_summary(value) =
    isempty(triggered_failure_oracle_ids(value)) ?
        "none" :
        join(triggered_failure_oracle_ids(value), "+")

function oracle_witnesses(trace::ConcolicTrace)
    fault = fault_pattern(trace)
    divergence = earliest_divergence(trace)
    relational = get(trace.metadata, "relational_counterexample", nothing)
    records = Dict{String,Any}[]
    for oracle in triggered_failure_oracles(trace)
        record = Dict{String,Any}(
            "oracle_id" => oracle["id"],
            "oracle_name" => oracle["name"],
            "subject_name" => trace.subject_name,
            "fault_pattern" => fault,
            "earliest_divergence_stage" => divergence,
        )
        if oracle["id"] == "O5_INCONSISTENT_CONTROL" && relational !== nothing
            record["relational_counterexample"] = relational
        end
        push!(records, record)
    end
    return records
end

function oracle_witnesses(witness::AbstractDict)
    return [
        Dict{String,Any}(
            "oracle_id" => oracle["id"],
            "oracle_name" => oracle["name"],
            "subject_name" => get(witness, "subject_name", nothing),
            "fault_pattern" => get(witness, "fault_pattern", Any[]),
            "earliest_divergence_stage" =>
                get(witness, "earliest_divergence_stage", "unknown"),
        )
        for oracle in triggered_failure_oracles(witness)
    ]
end
