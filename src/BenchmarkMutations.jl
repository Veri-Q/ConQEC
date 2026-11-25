const HIGH_LEVEL_BUG_CLASSES = (
    "syndrome_extraction_wiring",
    "measurement_result_misuse",
    "decoder_decision_error",
    "unhandled_syndrome",
    "recovery_application_error",
    "repeated_round_control_error",
)

const MUTATION_OPERATORS = Dict{String,String}(
    "wrong_stabilizer_check_support" =>
        "A syndrome bit is computed from the wrong stabilizer support.",
    "swapped_syndrome_bit" =>
        "Two syndrome bits or syndrome expressions are swapped before decoding.",
    "wrong_measurement_register_read" =>
        "Decoder code reads the wrong measurement-register slot.",
    "stale_measurement_value_reuse" =>
        "A previous measurement value is reused instead of the current one.",
    "overwritten_measurement_result" =>
        "A later measurement overwrites a still-needed syndrome result.",
    "decoder_table_entry_swap" =>
        "A decoder table arm returns the neighboring correction.",
    "decoder_neighbor_mapping" =>
        "A nearest-neighbor decoder maps an edge syndrome to the adjacent qubit.",
    "missing_decoder_arm" =>
        "A reachable syndrome arm falls through to missing or uncorrectable.",
    "missing_recovery_branch" =>
        "The decoder chooses a correction, but recovery code has no branch for it.",
    "wrong_recovery_target" =>
        "The correct Pauli is applied to the wrong data qubit.",
    "wrong_pauli_recovery" =>
        "Recovery applies the wrong Pauli type for the selected correction.",
    "recovery_applied_under_wrong_condition" =>
        "Recovery is gated by a stale or neighboring decoder condition.",
    "off_by_one_round_count" =>
        "Repeated-round decoder control drops or shifts one syndrome round.",
    "missing_syndrome_history_update" =>
        "A current syndrome snapshot is not committed to history.",
    "stale_syndrome_history_reuse" =>
        "Repeated-round control reuses an old syndrome-history key.",
    "missing_ancilla_reset" =>
        "A modeled ancilla/result register is not reset before reuse.",
    "path_sensitive_late_decoder_branch" =>
        "The bug-revealing decoder arm is behind several decoy path constraints.",
    "path_sensitive_relational_control" =>
        "The bug is exposed only by comparing equivalent repeated-round control states.",
)

struct BenchmarkSubjectSpec
    name::String
    base_subject
    mutation_operator::String
    trigger_decoder::Union{Nothing,String}
    actual_decoder::Union{Nothing,String}
    recovery_override::Union{Nothing,Dict{String,Any}}
    divergence::String
    verdict_overrides::Dict{String,Any}
    metadata::Dict{String,Any}
end

function benchmark_recovery(pauli::AbstractString, target::AbstractString;
    source::AbstractString="benchmark_mutation")

    return Dict{String,Any}(
        "pauli" => String(pauli),
        "target" => String(target),
        "source" => String(source),
    )
end

function seeded_bug_metadata(; bug_id,
    subject_family,
    subject_size,
    bug_class,
    mutation_operator,
    path_sensitive=false,
    expected_earliest_divergence,
    expected_oracle_classes,
    expected_actual_decoder=nothing,
    expected_reference_decoder=nothing,
    expected_actual_recovery=nothing,
    expected_reference_recovery=nothing,
    expected_min_fault_weight=nothing,
    notes="")

    op = String(mutation_operator)
    haskey(MUTATION_OPERATORS, op) ||
        error("unknown mutation operator $(op)")
    bug_class_text = String(bug_class)
    bug_class_text in HIGH_LEVEL_BUG_CLASSES ||
        error("bug_class must be one of $(join(HIGH_LEVEL_BUG_CLASSES, ", ")), got $(bug_class_text)")
    return Dict{String,Any}(
        "bug_id" => String(bug_id),
        "subject_family" => String(subject_family),
        "subject_size" => Int(subject_size),
        "bug_class" => bug_class_text,
        "mutation_operator" => op,
        "mutation_operator_description" => MUTATION_OPERATORS[op],
        "path_sensitive" => Bool(path_sensitive),
        "expected_earliest_divergence" => String(expected_earliest_divergence),
        "expected_oracle_classes" => [String(id) for id in expected_oracle_classes],
        "expected_actual_decoder" =>
            expected_actual_decoder === nothing ? nothing : String(expected_actual_decoder),
        "expected_reference_decoder" =>
            expected_reference_decoder === nothing ? nothing : String(expected_reference_decoder),
        "expected_actual_recovery" =>
            expected_actual_recovery === nothing ? nothing : String(expected_actual_recovery),
        "expected_reference_recovery" =>
            expected_reference_recovery === nothing ? nothing : String(expected_reference_recovery),
        "expected_min_fault_weight" =>
            expected_min_fault_weight === nothing ? nothing : Int(expected_min_fault_weight),
        "notes" => String(notes),
    )
end

function BenchmarkSubjectSpec(name::AbstractString,
    base_subject;
    mutation_operator,
    trigger_decoder=nothing,
    actual_decoder=nothing,
    recovery_override=nothing,
    divergence,
    verdict_overrides=Dict{String,Any}(),
    metadata=Dict{String,Any}())

    normalized_recovery = recovery_override === nothing ? nothing :
        Dict{String,Any}(string(key) => value for (key, value) in recovery_override)
    return BenchmarkSubjectSpec(
        String(name),
        base_subject,
        String(mutation_operator),
        trigger_decoder === nothing ? nothing : String(trigger_decoder),
        actual_decoder === nothing ? nothing : String(actual_decoder),
        normalized_recovery,
        String(divergence),
        Dict{String,Any}(string(key) => value for (key, value) in verdict_overrides),
        Dict{String,Any}(string(key) => value for (key, value) in metadata),
    )
end

subject_name(subject::BenchmarkSubjectSpec) = subject.name

subject_fault_vars(subject::BenchmarkSubjectSpec) =
    subject_fault_vars(subject.base_subject)

function subject_metadata(subject::BenchmarkSubjectSpec)
    out = subject_metadata(subject.base_subject)
    for (key, value) in subject.metadata
        out[string(key)] = value
    end
    out["subject_name"] = subject.name
    out["base_subject"] = subject_name(subject.base_subject)
    out["mutation_operator"] = subject.mutation_operator
    return out
end

function benchmark_triggered(subject::BenchmarkSubjectSpec, trace::ConcolicTrace)
    subject.trigger_decoder === nothing && return true
    return get(trace.decoder_decisions, "expected", nothing) == subject.trigger_decoder ||
        get(trace.decoder_decisions, "actual", nothing) == subject.trigger_decoder
end

function apply_benchmark_mutation!(trace::ConcolicTrace, subject::BenchmarkSubjectSpec)
    trace.subject_name = subject.name
    for (key, value) in subject.metadata
        trace.metadata[string(key)] = value
    end
    trace.metadata["base_subject"] = subject_name(subject.base_subject)
    trace.metadata["mutation_operator"] = subject.mutation_operator
    trace.metadata["mutation_triggered"] = benchmark_triggered(subject, trace)
    trace.metadata["subject_name"] = subject.name

    benchmark_triggered(subject, trace) || return trace

    if subject.actual_decoder !== nothing
        record_decoder_decision!(trace, "actual", subject.actual_decoder)
    end
    if subject.recovery_override !== nothing
        empty!(trace.recovery_actions)
        record_recovery_action!(trace, subject.recovery_override)
    end

    for (key, value) in subject.verdict_overrides
        record_logical_verdict!(trace, key, value)
    end
    trace.metadata["earliest_divergence_stage"] = subject.divergence
    trace.metadata["benchmark_mutation"] = Dict{String,Any}(
        "operator" => subject.mutation_operator,
        "description" => MUTATION_OPERATORS[subject.mutation_operator],
        "trigger_decoder" => subject.trigger_decoder,
        "actual_decoder" => get(trace.decoder_decisions, "actual", nothing),
        "expected_decoder" => get(trace.decoder_decisions, "expected", nothing),
        "actual_recovery" => copy(trace.recovery_actions),
        "expected_recovery" => get(trace.metadata, "expected_recovery", nothing),
    )
    return trace
end

function run_subject(subject::BenchmarkSubjectSpec, input::AbstractDict)
    trace = run_subject(subject.base_subject, input)
    return apply_benchmark_mutation!(trace, subject)
end

coverage_challenge_fault_vars() =
    vcat([Symbol("decoy", idx) for idx in 1:5], [Symbol("signal", idx) for idx in 1:3])

function run_coverage_challenge_subject(input)
    fault_vars = coverage_challenge_fault_vars()
    model = normalize_assignment(fault_vars, input)
    trace = ConcolicTrace(
        "coverage_challenge_clean";
        code_size=8,
        distance=3,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=Dict{String,Any}(
            "subject_family" => "PathSensitiveChallenges",
            "mode" => "coverage_challenge_clean",
            "fault_model" => "single signal fault with five same-syndrome decoys",
            "max_fault_weight" => 1,
            "path_sensitive" => true,
            "challenge_kind" => "coverage",
        ),
    )

    for idx in 1:5
        var = Symbol("decoy", idx)
        record_branch!(
            trace,
            "fault:decoy_$(idx)",
            :fault,
            boolvar(var),
            model[var];
            description="coverage challenge same-syndrome decoy $(idx)",
        )
    end

    signal_vars = [Symbol("signal", idx) for idx in 1:3]
    for (idx, var) in enumerate(signal_vars)
        value = model[var]
        expr = boolvar(var)
        name = "s$(idx)"
        record_syndrome!(trace, name, value, expr)
        record_branch!(
            trace,
            "syndrome:$(name)_signal",
            :syndrome,
            expr,
            value;
            description="coverage challenge signal syndrome $(name)",
        )
    end

    active = [idx for idx in 1:3 if model[Symbol("signal", idx)]]
    decoder = isempty(active) ? "none" : "q$(first(active))"
    record_decoder_decision!(trace, "actual", decoder)
    record_decoder_decision!(trace, "expected", decoder)
    record_recovery_action!(
        trace,
        Dict(
            "pauli" => decoder == "none" ? "I" : "X",
            "target" => decoder,
            "source" => "coverage_challenge_decoder",
        ),
    )
    trace.metadata["expected_recovery"] = trace.recovery_actions[1]
    record_logical_verdict!(trace, "decoder_mismatch", false)
    record_logical_verdict!(trace, "recovery_mismatch", false)
    record_logical_verdict!(trace, "logical_mismatch", false)
    record_logical_verdict!(trace, "oracle_verdict", true)
    record_logical_verdict!(trace, "residual_weight", 0)
    return trace
end

priority_challenge_fault_vars(; decoys::Int=7) =
    vcat([Symbol("d$(idx)") for idx in 1:decoys], [:bug])

function run_priority_decoder_challenge_subject(input;
    name::AbstractString="priority_decoder_challenge",
    decoys::Int=7)

    fault_vars = priority_challenge_fault_vars(decoys=decoys)
    model = normalize_assignment(fault_vars, input)
    trace = ConcolicTrace(
        name;
        code_size=decoys + 1,
        distance=3,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=Dict{String,Any}(
            "subject_family" => "PathSensitiveChallenges",
            "mode" => String(name),
            "fault_model" => "single Pauli-X data fault with decoy path guards",
            "max_fault_weight" => 1,
            "path_sensitive" => true,
            "challenge_kind" => "late_decoder_branch",
        ),
    )
    for idx in 1:decoys
        var = Symbol("d$(idx)")
        stage = isodd(idx) ? :fault : :syndrome
        stage == :syndrome && record_syndrome!(trace, "d$(idx)", model[var], boolvar(var))
        record_branch!(
            trace,
            "$(stage):decoy_$(idx)",
            stage,
            boolvar(var),
            model[var];
            description="path-sensitive decoy branch $(idx)",
        )
    end
    record_syndrome!(trace, "bug", model[:bug], boolvar(:bug))
    record_branch!(
        trace,
        "decoder:bug_revealing_arm",
        :decoder,
        boolvar(:bug),
        model[:bug];
        description="path-sensitive late bug-revealing decoder branch",
    )
    record_decoder_decision!(trace, "actual", model[:bug] ? "buggy_arm" : "none")
    record_decoder_decision!(trace, "expected", "none")
    record_recovery_action!(trace, Dict("pauli" => "I", "target" => "none"))
    trace.metadata["expected_recovery"] = Dict("pauli" => "I", "target" => "none")
    record_logical_verdict!(trace, "decoder_mismatch", model[:bug])
    record_logical_verdict!(trace, "logical_mismatch", model[:bug])
    record_logical_verdict!(trace, "recovery_mismatch", false)
    record_logical_verdict!(trace, "missing_recovery_branch", false)
    record_logical_verdict!(trace, "oracle_verdict", !model[:bug])
    record_logical_verdict!(trace, "residual_weight", model[:bug] ? 1 : 0)
    model[:bug] && (trace.metadata["earliest_divergence_stage"] = "decoder")
    return trace
end

function high_level_bug_class(raw_class::AbstractString)
    text = String(raw_class)
    text in HIGH_LEVEL_BUG_CLASSES && return text
    key = replace(lowercase(text), "-" => "_")
    key in ("syndrome_wiring", "syndrome_extraction", "wrong_stabilizer_check") &&
        return "syndrome_extraction_wiring"
    key in ("measurement_misuse", "measurement_result_misuse") &&
        return "measurement_result_misuse"
    key in (
        "decoder_table",
        "decoder_table_priority",
        "decoder_neighbor",
        "priority_decoder",
        "unhandled_syndrome",
    ) && return key == "unhandled_syndrome" ? "unhandled_syndrome" : "decoder_decision_error"
    key in (
        "wrong_recovery_target",
        "missing_recovery_branch",
        "wrong_pauli_recovery",
        "recovery_application_error",
    ) && return "recovery_application_error"
    key in (
        "repeated_round_history_drop",
        "repeated_round_inconsistent_control",
        "repeated_round_control",
    ) && return "repeated_round_control_error"
    return text
end

function config_bug_metadata(config)
    hasproperty(config, :bug_metadata) || return nothing
    value = config.bug_metadata
    value === nothing && return nothing
    return Dict{String,Any}(value)
end

config_is_seeded_bug(config) = config_bug_metadata(config) !== nothing

function config_bug_class(config)
    metadata = config_bug_metadata(config)
    metadata !== nothing && return String(metadata["bug_class"])
    return high_level_bug_class(paper_diagnostic_contract_by_name(subject_name(config.subject)).bug_class)
end

function config_path_sensitive(config)
    metadata = config_bug_metadata(config)
    metadata !== nothing && return Bool(get(metadata, "path_sensitive", false))
    return Bool(get(subject_metadata(config.subject), "path_sensitive", false))
end
