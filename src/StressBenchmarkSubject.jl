struct SiblingBugSubject
    name::String
    qubits::Int
    first_var::Int
    second_var::Int
    bug_class::String
end

struct MinimizationStressSubject
    name::String
    qubits::Int
    trigger_vars::Vector{Int}
    minimal_var::Int
    bug_class::String
end

stress_var(prefix::AbstractString, idx::Integer) =
    Symbol(prefix, "_f", lpad(string(idx), 4, '0'))

stress_prefix(name::AbstractString) =
    replace(lowercase(String(name)), r"[^a-z0-9]+" => "_")

function stress_fault_vars(name::AbstractString, qubits::Integer)
    prefix = stress_prefix(name)
    [stress_var(prefix, idx) for idx in 1:Int(qubits)]
end

subject_name(subject::SiblingBugSubject) = subject.name
subject_fault_vars(subject::SiblingBugSubject) =
    stress_fault_vars(subject.name, subject.qubits)

subject_name(subject::MinimizationStressSubject) = subject.name
subject_fault_vars(subject::MinimizationStressSubject) =
    stress_fault_vars(subject.name, subject.qubits)

function stress_hardness_bin(budget::Integer, assignments::Integer)
    ratio = Float64(budget) / Float64(max(assignments, 1))
    ratio > 0.5 && return "easy"
    ratio < 0.01 && return "hard"
    return "medium"
end

function sibling_metadata(subject::SiblingBugSubject)
    budget = 16
    assignments = subject.qubits
    ratio = budget / assignments
    prefix = stress_prefix(subject.name)
    trigger_indices = Set([subject.first_var, subject.second_var])
    return Dict{String,Any}(
        "subject_family" => "failure_adjacent_sibling",
        "benchmark_family" => "FailureAdjacentSiblings",
        "benchmark_family_alias" => "FailureAdjacentSiblingBugs",
        "path_sensitive" => true,
        "qubits" => subject.qubits,
        "fault_variables" => subject.qubits,
        "max_fault_weight" => 1,
        "admissible_assignments" => assignments,
        "syndrome_bits" => ceil(Int, log2(subject.qubits + 1)),
        "reachable_syndromes" => subject.qubits + 1,
        "decoder_arms" => subject.qubits + 1,
        "recovery_actions" => subject.qubits + 1,
        "rounds" => 1,
        "history_states" => 0,
        "failing_assignments" => 2,
        "estimated_bug_probability" => 2 / assignments,
        "budget" => budget,
        "exhaustibility_ratio" => ratio,
        "hardness_bin" => stress_hardness_bin(budget, assignments),
        "first_witness_trial" => 2,
        "second_witness_trial_full" => 3,
        "second_witness_trial_no_failure_adjacent" => min(budget, 9),
        "branch_trace_distance" => 1,
        "trigger_faults" => [
            string(stress_var(stress_prefix(subject.name), subject.first_var)),
        ],
        "second_trigger_faults" => [
            string(stress_var(stress_prefix(subject.name), subject.second_var)),
        ],
        "interesting_faults" => [
            string(stress_var(prefix, subject.first_var)),
            string(stress_var(prefix, subject.second_var)),
        ],
        "boring_faults" => [
            string(stress_var(prefix, idx))
            for idx in 1:subject.qubits
            if !(idx in trigger_indices)
        ],
    )
end

function minimization_metadata(subject::MinimizationStressSubject)
    budget = 16
    assignments = subject.qubits + fld(subject.qubits * (subject.qubits - 1), 2)
    ratio = budget / assignments
    prefix = stress_prefix(subject.name)
    trigger_indices = Set(subject.trigger_vars)
    protected_indices = union(trigger_indices, Set([subject.minimal_var]))
    return Dict{String,Any}(
        "subject_family" => "minimization_stress",
        "benchmark_family" => "MinimizationStress",
        "path_sensitive" => true,
        "qubits" => subject.qubits,
        "fault_variables" => subject.qubits,
        "max_fault_weight" => length(subject.trigger_vars),
        "admissible_assignments" => assignments,
        "syndrome_bits" => ceil(Int, log2(subject.qubits + 1)),
        "reachable_syndromes" => subject.qubits + 1,
        "decoder_arms" => subject.qubits + 1,
        "recovery_actions" => subject.qubits + 1,
        "rounds" => 1,
        "history_states" => 0,
        "failing_assignments" => 1,
        "estimated_bug_probability" => 1 / assignments,
        "budget" => budget,
        "exhaustibility_ratio" => ratio,
        "hardness_bin" => stress_hardness_bin(budget, assignments),
        "initial_fault_weight" => length(subject.trigger_vars),
        "minimized_fault_weight" => 1,
        "oracle_preserved" => true,
        "earliest_divergence_preserved" => true,
        "trigger_faults" => [
            string(stress_var(prefix, idx))
            for idx in subject.trigger_vars
        ],
        "minimal_faults" => [
            string(stress_var(prefix, subject.minimal_var)),
        ],
        "interesting_faults" => [
            string(stress_var(prefix, subject.minimal_var)),
        ],
        "boring_faults" => [
            string(stress_var(prefix, idx))
            for idx in 1:subject.qubits
            if !(idx in protected_indices)
        ],
    )
end

subject_metadata(subject::SiblingBugSubject) = sibling_metadata(subject)
subject_metadata(subject::MinimizationStressSubject) = minimization_metadata(subject)

function stress_active_index(subject, model::AbstractDict)
    for (idx, var) in enumerate(subject_fault_vars(subject))
        model_bool(model, var) && return idx
    end
    return 0
end

function stress_record_syndrome!(trace::ConcolicTrace, subject, active::Integer)
    width = max(1, ceil(Int, log2(length(subject_fault_vars(subject)) + 1)))
    vars = subject_fault_vars(subject)
    for bit in 1:width
        terms = BoolExpr[]
        mask = 1 << (bit - 1)
        for idx in eachindex(vars)
            (idx & mask) == 0 && continue
            push!(terms, boolvar(vars[idx]))
        end
        expr = isempty(terms) ? bconst(false) : bor(terms...)
        value = ((Int(active) >> (bit - 1)) & 1) == 1
        record_syndrome!(trace, "s$(bit)", value, expr)
    end
    return trace
end

function stress_verdicts!(trace::ConcolicTrace, bug_class::AbstractString, failed::Bool)
    class = String(bug_class)
    record_logical_verdict!(trace, "syndrome_mismatch",
        class == "syndrome_extraction_wiring" && failed)
    record_logical_verdict!(trace, "measurement_misuse",
        class == "measurement_result_misuse" && failed)
    record_logical_verdict!(trace, "decoder_mismatch",
        class in ("decoder_decision_error", "unhandled_syndrome") && failed)
    record_logical_verdict!(trace, "recovery_mismatch",
        class in ("decoder_decision_error", "recovery_application_error",
            "unhandled_syndrome") && failed)
    record_logical_verdict!(trace, "missing_recovery_branch",
        class == "unhandled_syndrome" && failed)
    record_logical_verdict!(trace, "logical_mismatch",
        class != "repeated_round_control_error" && failed)
    record_logical_verdict!(trace, "oracle_verdict", !failed)
    record_logical_verdict!(trace, "residual_weight",
        class == "repeated_round_control_error" ? 0 : (failed ? 1 : 0))
    return trace
end

function stress_outputs(subject, failed::Bool, active::Integer)
    class = subject.bug_class
    expected = active == 0 ? "none" : "q$(active)"
    actual = expected
    if failed && class == "decoder_decision_error"
        actual = "q_bug"
    elseif failed && class == "unhandled_syndrome"
        actual = "missing"
    end
    expected_recovery = Dict("pauli" => expected == "none" ? "I" : "X", "target" => expected)
    actual_recovery = if failed && class == "recovery_application_error"
        Dict("pauli" => "X", "target" => "wrong_target")
    elseif failed && class == "unhandled_syndrome"
        Dict("pauli" => "missing", "target" => "missing")
    else
        Dict("pauli" => actual == "none" ? "I" : "X", "target" => actual)
    end
    return actual, expected, actual_recovery, expected_recovery
end

function run_subject(subject::SiblingBugSubject, input::AbstractDict)
    vars = subject_fault_vars(subject)
    model = normalize_assignment(vars, input)
    trace = ConcolicTrace(
        subject.name;
        code_size=subject.qubits,
        distance=3,
        fault_vars=vars,
        fault_assignments=model,
        metadata=sibling_metadata(subject),
    )
    first = vars[subject.first_var]
    second = vars[subject.second_var]
    active = stress_active_index(subject, model)
    stress_record_syndrome!(trace, subject, active)
    for idx in 1:min(12, length(vars))
        idx in (subject.first_var, subject.second_var) && continue
        record_branch!(trace, "fault:sibling_decoy_$(idx)", :fault,
            boolvar(vars[idx]), model[vars[idx]])
    end
    record_branch!(trace, "decoder:first_sibling_bug", :decoder,
        boolvar(first), model[first])
    record_branch!(trace, "decoder:second_sibling_bug", :decoder,
        boolvar(second), model[second])
    failed = model[first] || model[second]
    actual, expected, actual_recovery, expected_recovery = stress_outputs(subject, failed, active)
    record_decoder_decision!(trace, "actual", actual)
    record_decoder_decision!(trace, "expected", expected)
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    stress_verdicts!(trace, subject.bug_class, failed)
    failed && (trace.metadata["earliest_divergence_stage"] =
        subject.bug_class == "recovery_application_error" ? "recovery" : "decoder")
    return trace
end

function run_subject(subject::MinimizationStressSubject, input::AbstractDict)
    vars = subject_fault_vars(subject)
    model = normalize_assignment(vars, input)
    trace = ConcolicTrace(
        subject.name;
        code_size=subject.qubits,
        distance=5,
        fault_vars=vars,
        fault_assignments=model,
        metadata=minimization_metadata(subject),
    )
    active = stress_active_index(subject, model)
    stress_record_syndrome!(trace, subject, active)
    trigger_symbols = [vars[idx] for idx in subject.trigger_vars]
    trigger = band((boolvar(var) for var in trigger_symbols)...)
    record_branch!(trace, "decoder:nonminimal_trigger", :decoder,
        trigger, evaluate(trigger, model))
    failed = evaluate(trigger, model) || model[vars[subject.minimal_var]]
    actual, expected, actual_recovery, expected_recovery = stress_outputs(subject, failed, active)
    record_decoder_decision!(trace, "actual", actual)
    record_decoder_decision!(trace, "expected", expected)
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    stress_verdicts!(trace, subject.bug_class, failed)
    failed && (trace.metadata["earliest_divergence_stage"] =
        subject.bug_class == "recovery_application_error" ? "recovery" : "decoder")
    return trace
end
