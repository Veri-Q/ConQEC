struct ExternalQECCSubject
    name::String
    origin::String
    code_kind::Symbol
    bug_mode::Symbol
    qubits::Int
    rounds::Int
    trigger_index::Int
    wrong_index::Int
end

function ExternalQECCSubject(name::AbstractString, origin::AbstractString,
    code_kind::Symbol, bug_mode::Symbol; qubits::Integer, rounds::Integer=1,
    trigger_index::Integer=2, wrong_index::Integer=1)

    code_kind in (:quantumse_repetition, :steane_css, :stim_detector) ||
        error("unsupported external code kind: $(code_kind)")
    bug_mode in (:decoder_decision_error, :recovery_application_error,
        :unhandled_syndrome, :repeated_round_control_error) ||
        error("unsupported external bug mode: $(bug_mode)")
    qubits > 0 || error("qubits must be positive")
    rounds > 0 || error("rounds must be positive")
    subject = ExternalQECCSubject(String(name), String(origin), code_kind,
        bug_mode, Int(qubits), Int(rounds), Int(trigger_index), Int(wrong_index))
    nvars = length(external_fault_vars(subject))
    1 <= trigger_index <= nvars || error("trigger_index outside external fault vars")
    1 <= wrong_index <= nvars || error("wrong_index outside external fault vars")
    wrong_index != trigger_index || error("wrong_index must differ from trigger_index")
    return subject
end

external_subject_prefix(subject::ExternalQECCSubject) =
    replace(lowercase(subject.name), r"[^a-z0-9]+" => "_")

function external_fault_vars(subject::ExternalQECCSubject)
    prefix = external_subject_prefix(subject)
    if subject.code_kind == :quantumse_repetition
        return [Symbol(prefix, "_x", lpad(string(idx), 2, '0'))
            for idx in 1:subject.qubits]
    elseif subject.code_kind == :steane_css
        return vcat(
            [Symbol(prefix, "_x", lpad(string(idx), 2, '0')) for idx in 1:7],
            [Symbol(prefix, "_z", lpad(string(idx), 2, '0')) for idx in 1:7],
        )
    end
    detectors_per_round = max(1, subject.qubits - 1)
    return [
        Symbol(prefix, "_d", lpad(string(round), 2, '0'), "_",
            lpad(string(detector), 2, '0'))
        for round in 1:subject.rounds
        for detector in 1:detectors_per_round
    ]
end

external_syndrome_bits(subject::ExternalQECCSubject) =
    max(1, ceil(Int, log2(length(external_fault_vars(subject)) + 1)))

function external_hardness_bin(budget::Integer, assignments::Integer)
    ratio = Float64(budget) / Float64(max(assignments, 1))
    ratio > 0.5 && return "Easy"
    0.05 <= ratio <= 0.2 && return "Medium"
    ratio < 0.01 && return "Hard"
    return "Medium"
end

function external_label(subject::ExternalQECCSubject, index::Integer)
    idx = Int(index)
    if idx == 0
        return Dict{String,Any}(
            "decoder" => "none",
            "pauli" => "I",
            "target" => "none",
            "round" => nothing,
            "detector" => nothing,
        )
    elseif subject.code_kind == :quantumse_repetition
        return Dict{String,Any}(
            "decoder" => "q$(idx)",
            "pauli" => "X",
            "target" => "q$(idx)",
            "round" => nothing,
            "detector" => nothing,
        )
    elseif subject.code_kind == :steane_css
        pauli = idx <= 7 ? "X" : "Z"
        qubit = idx <= 7 ? idx : idx - 7
        return Dict{String,Any}(
            "decoder" => string(pauli, ":q", qubit),
            "pauli" => pauli,
            "target" => "q$(qubit)",
            "round" => nothing,
            "detector" => nothing,
        )
    end
    detectors_per_round = max(1, subject.qubits - 1)
    round = fld(idx - 1, detectors_per_round) + 1
    detector = mod(idx - 1, detectors_per_round) + 1
    target = "q$(min(detector, subject.qubits))"
    return Dict{String,Any}(
        "decoder" => "r$(round)_d$(detector)",
        "pauli" => "X",
        "target" => target,
        "round" => round,
        "detector" => detector,
    )
end

function external_recovery_action(label::AbstractDict)
    action = Dict{String,Any}(
        "pauli" => string(label["pauli"]),
        "target" => string(label["target"]),
        "source" => "external_subject_adapter",
    )
    round = get(label, "round", nothing)
    round === nothing || (action["inferred_round"] = round)
    return action
end

function external_action_signature(action::AbstractDict)
    base = string(get(action, "pauli", "unknown"), "@",
        get(action, "target", "unknown"))
    round = get(action, "inferred_round", nothing)
    round === nothing && return base
    return string(base, ":round=", round)
end

function external_active_index(subject::ExternalQECCSubject, model::AbstractDict)
    for (idx, var) in enumerate(external_fault_vars(subject))
        model_bool(model, var) && return idx
    end
    return 0
end

function external_outputs(subject::ExternalQECCSubject, active_index::Integer)
    expected_label = external_label(subject, active_index)
    actual_label = expected_label
    failed = active_index == subject.trigger_index
    actual_decoder = string(expected_label["decoder"])
    expected_decoder = string(expected_label["decoder"])
    expected_recovery = external_recovery_action(expected_label)
    actual_recovery = expected_recovery
    if failed && subject.bug_mode == :decoder_decision_error
        actual_label = external_label(subject, subject.wrong_index)
        actual_decoder = string(actual_label["decoder"])
        actual_recovery = external_recovery_action(actual_label)
    elseif failed && subject.bug_mode == :recovery_application_error
        actual_label = external_label(subject, subject.wrong_index)
        actual_recovery = external_recovery_action(actual_label)
    elseif failed && subject.bug_mode == :unhandled_syndrome
        actual_decoder = "missing"
        actual_recovery = Dict{String,Any}(
            "pauli" => "missing",
            "target" => "missing",
            "source" => "external_subject_adapter",
        )
    elseif failed && subject.bug_mode == :repeated_round_control_error
        actual_label = external_label(subject, subject.wrong_index)
        actual_decoder = string(actual_label["decoder"])
        actual_recovery = external_recovery_action(actual_label)
    end
    return actual_decoder, expected_decoder, actual_recovery, expected_recovery, failed
end

function external_bug_class(subject::ExternalQECCSubject)
    subject.bug_mode == :decoder_decision_error && return "decoder_decision_error"
    subject.bug_mode == :recovery_application_error && return "recovery_application_error"
    subject.bug_mode == :unhandled_syndrome && return "unhandled_syndrome"
    return "repeated_round_control_error"
end

function external_mutation_operator(subject::ExternalQECCSubject)
    subject.bug_mode == :decoder_decision_error && return "decoder_table_entry_swap"
    subject.bug_mode == :recovery_application_error && return "wrong_recovery_target"
    subject.bug_mode == :unhandled_syndrome && return "missing_decoder_arm"
    return "path_sensitive_relational_control"
end

function external_divergence(subject::ExternalQECCSubject)
    subject.bug_mode == :decoder_decision_error && return "decoder"
    subject.bug_mode == :recovery_application_error && return "recovery"
    subject.bug_mode == :unhandled_syndrome && return "decoder"
    return "repeated_round_control"
end

function external_expected_oracles(subject::ExternalQECCSubject)
    subject.bug_mode == :decoder_decision_error &&
        return ["O1_LOGICAL_MISMATCH", "O2_DECODER_MISMATCH",
            "O3_RESIDUAL_CORRECTABLE_ERROR"]
    subject.bug_mode == :recovery_application_error &&
        return ["O1_LOGICAL_MISMATCH", "O3_RESIDUAL_CORRECTABLE_ERROR"]
    subject.bug_mode == :unhandled_syndrome &&
        return ["O1_LOGICAL_MISMATCH", "O2_DECODER_MISMATCH",
            "O3_RESIDUAL_CORRECTABLE_ERROR", "O4_DEAD_RECOVERY_BRANCH"]
    return ["O5_INCONSISTENT_CONTROL"]
end

function external_subject_metadata(subject::ExternalQECCSubject)
    vars = external_fault_vars(subject)
    budget = subject.code_kind == :stim_detector ? 10 : 8
    assignments = length(vars) + 1
    ratio = budget / assignments
    trigger = string(vars[subject.trigger_index])
    protected = Set([subject.trigger_index, subject.wrong_index])
    return Dict{String,Any}(
        "subject_family" => "ExternalSubjects",
        "benchmark_family" => "ExternalSubjects",
        "origin" => subject.origin,
        "external_subject" => true,
        "code_kind" => string(subject.code_kind),
        "bug_mode" => string(subject.bug_mode),
        "path_sensitive" => subject.bug_mode in
            (:decoder_decision_error, :recovery_application_error,
                :unhandled_syndrome, :repeated_round_control_error),
        "qubits" => subject.qubits,
        "fault_variables" => length(vars),
        "max_fault_weight" => 1,
        "admissible_assignments" => assignments,
        "syndrome_bits" => external_syndrome_bits(subject),
        "reachable_syndromes" => assignments,
        "decoder_arms" => assignments,
        "recovery_actions" => assignments,
        "rounds" => subject.rounds,
        "history_states" => subject.rounds > 1 ? assignments : 0,
        "failing_assignments" => 1,
        "seeded_failing_assignments" => 1,
        "estimated_bug_probability" => 1.0 / assignments,
        "bug_hit_probability" => 1.0 / assignments,
        "budget" => budget,
        "recommended_budget" => budget,
        "exhaustibility_ratio" => ratio,
        "hardness_bin" => external_hardness_bin(budget, assignments),
        "trigger_faults" => [trigger],
        "interesting_faults" => [trigger],
        "boring_faults" => [
            string(var)
            for (idx, var) in enumerate(vars)
            if !(idx in protected)
        ],
    )
end

function external_record_syndrome!(trace::ConcolicTrace,
    subject::ExternalQECCSubject, active_index::Integer)

    width = external_syndrome_bits(subject)
    vars = external_fault_vars(subject)
    for bit in 1:width
        terms = BoolExpr[]
        mask = 1 << (bit - 1)
        for idx in eachindex(vars)
            (idx & mask) == 0 && continue
            push!(terms, boolvar(vars[idx]))
        end
        expr = isempty(terms) ? bconst(false) : bor(terms...)
        value = ((Int(active_index) >> (bit - 1)) & 1) == 1
        record_syndrome!(trace, "s$(bit)", value, expr)
        record_branch!(trace, "syndrome:external_s$(bit)", :syndrome,
            expr, value; path_constraint=false)
    end
    return trace
end

function external_record_verdicts!(trace::ConcolicTrace,
    subject::ExternalQECCSubject, failed::Bool)

    class = external_bug_class(subject)
    record_logical_verdict!(trace, "syndrome_mismatch", false)
    record_logical_verdict!(trace, "measurement_misuse", false)
    record_logical_verdict!(trace, "decoder_mismatch",
        failed && class in ("decoder_decision_error", "unhandled_syndrome"))
    record_logical_verdict!(trace, "recovery_mismatch",
        failed && class in ("decoder_decision_error", "recovery_application_error",
            "unhandled_syndrome"))
    record_logical_verdict!(trace, "missing_recovery_branch",
        failed && class == "unhandled_syndrome")
    record_logical_verdict!(trace, "history_mismatch",
        failed && class == "repeated_round_control_error")
    record_logical_verdict!(trace, "inconsistent_control",
        failed && class == "repeated_round_control_error")
    record_logical_verdict!(trace, "logical_mismatch",
        failed && class != "repeated_round_control_error")
    record_logical_verdict!(trace, "residual_weight",
        failed && class != "repeated_round_control_error" ? 1 : 0)
    record_logical_verdict!(trace, "oracle_verdict", !failed)
    return trace
end

subject_name(subject::ExternalQECCSubject) = subject.name
subject_fault_vars(subject::ExternalQECCSubject) = external_fault_vars(subject)
subject_metadata(subject::ExternalQECCSubject) = external_subject_metadata(subject)

function run_subject(subject::ExternalQECCSubject, input::AbstractDict)
    vars = external_fault_vars(subject)
    model = normalize_assignment(vars, input)
    trace = ConcolicTrace(
        subject.name;
        code_size=subject.qubits,
        distance=subject.code_kind == :steane_css ? 3 : subject.rounds + 2,
        fault_vars=vars,
        fault_assignments=model,
        metadata=external_subject_metadata(subject),
    )
    active = external_active_index(subject, model)
    external_record_syndrome!(trace, subject, active)

    for (idx, var) in enumerate(vars)
        idx == subject.trigger_index && continue
        idx == subject.wrong_index && continue
        record_branch!(trace, "fault:external_decoy_$(idx)", :fault,
            boolvar(var), model[var];
            description="external adapter non-trigger fault branch",
            path_constraint=idx <= min(length(vars), 12))
    end
    trigger = vars[subject.trigger_index]
    trigger_stage = subject.bug_mode == :repeated_round_control_error ?
        :repeated_round_control : :decoder
    record_branch!(trace, "decoder:external_trigger", trigger_stage,
        boolvar(trigger), model[trigger];
        description="external adapter bug-triggering branch")

    actual, expected, actual_recovery, expected_recovery, failed =
        external_outputs(subject, active)
    record_decoder_decision!(trace, "actual", actual)
    record_decoder_decision!(trace, "expected", expected)
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    trace.metadata["expected_recovery_signature"] =
        external_action_signature(expected_recovery)
    trace.metadata["actual_recovery_signature"] =
        external_action_signature(actual_recovery)
    trace.metadata["external_origin"] = subject.origin
    failed && (trace.metadata["earliest_divergence_stage"] =
        external_divergence(subject))
    external_record_verdicts!(trace, subject, failed)
    return trace
end
