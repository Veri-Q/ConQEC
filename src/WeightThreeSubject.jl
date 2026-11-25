struct WeightThreeSubject
    name::String
    qubits::Int
    mode::Symbol
    target_triple::Tuple{Int,Int,Int}
    budget::Int
end

const WEIGHT_THREE_MODES = (
    :clean,
    :decoder_triple_bug,
    :recovery_triple_bug,
    :unhandled_triple_bug,
)

function WeightThreeSubject(qubits::Int, mode::Symbol=:clean;
    target_triple::Tuple{Int,Int,Int}=weight_three_default_target_triple(qubits, mode),
    budget::Integer=32)

    qubits >= 7 || error("Weight-three subject must have at least 7 qubits")
    mode in WEIGHT_THREE_MODES ||
        error("Unsupported weight-three subject mode: $(mode)")
    a, b, c = target_triple
    1 <= a < b < c <= qubits ||
        error("target_triple must satisfy 1 <= i < j < k <= qubits")
    budget > 0 || error("budget must be positive")
    suffix = mode == :clean ? "clean" :
        string(mode, "_q", a, "_q", b, "_q", c)
    return WeightThreeSubject(
        "weight3_repetition_n$(qubits)_$(suffix)",
        qubits,
        mode,
        target_triple,
        Int(budget),
    )
end

function weight_three_default_target_triple(qubits::Int, mode::Symbol=:clean)
    mode == :decoder_triple_bug &&
        return (max(2, cld(qubits, 5)), max(3, cld(3 * qubits, 5)),
            max(4, fld(4 * qubits, 5)))
    mode == :recovery_triple_bug &&
        return (max(2, cld(qubits, 6)), max(3, cld(2 * qubits, 3)),
            max(4, fld(5 * qubits, 6)))
    mode == :unhandled_triple_bug &&
        return (max(2, cld(qubits, 7)), max(3, cld(5 * qubits, 7)),
            max(4, fld(6 * qubits, 7)))
    return (max(1, cld(qubits, 4)), max(2, cld(qubits, 2)),
        max(3, fld(3 * qubits, 4)))
end

weight_three_fault_vars(qubits::Int) = [Symbol("x", idx) for idx in 1:qubits]
weight_three_fault_vars(subject::WeightThreeSubject) =
    weight_three_fault_vars(subject.qubits)

weight_three_admissible_assignments(qubits::Int) =
    1 + qubits + fld(qubits * (qubits - 1), 2) +
    fld(qubits * (qubits - 1) * (qubits - 2), 6)

weight_three_label(triple::Tuple{Int,Int,Int}) =
    "q$(triple[1])_q$(triple[2])_q$(triple[3])"

weight_three_decoder_output(triple::Tuple{Int,Int,Int}) =
    "triple:" * weight_three_label(triple)

function weight_three_recovery_action(decoder_output::AbstractString)
    output = String(decoder_output)
    output == "none" &&
        return Dict{String,Any}("pauli" => "I", "target" => "none",
            "source" => "weight3_decoder")
    output in ("missing", "uncorrectable") &&
        return Dict{String,Any}("pauli" => "missing", "target" => output,
            "source" => "weight3_decoder")
    if startswith(output, "q")
        return Dict{String,Any}("pauli" => "X", "target" => output,
            "source" => "weight3_decoder")
    end
    startswith(output, "pair:") || startswith(output, "triple:") ||
        error("Unsupported weight-three decoder output: $(decoder_output)")
    offset = startswith(output, "pair:") ? 6 : 8
    targets = [String(part) for part in split(output[offset:end], "_")]
    return Dict{String,Any}(
        "pauli" => "X",
        "target" => join(targets, "+"),
        "targets" => targets,
        "source" => "weight3_decoder",
    )
end

function weight_three_reference_decoder(active::AbstractVector{Int})
    isempty(active) && return "none"
    length(active) == 1 && return "q$(only(active))"
    length(active) == 2 &&
        return weight_two_decoder_output((active[1], active[2]))
    length(active) == 3 &&
        return weight_three_decoder_output((active[1], active[2], active[3]))
    return "uncorrectable"
end

function weight_three_wrong_triple_for(subject::WeightThreeSubject)
    a, b, c = subject.target_triple
    wrong_c = c == subject.qubits ? c - 1 : c + 1
    values = sort!([a, b, wrong_c])
    return (values[1], values[2], values[3])
end

function weight_three_buggy_decoder(subject::WeightThreeSubject, expected::AbstractString)
    expected_trigger = weight_three_decoder_output(subject.target_triple)
    subject.mode == :unhandled_triple_bug && expected == expected_trigger &&
        return "missing"
    subject.mode == :decoder_triple_bug && expected == expected_trigger &&
        return weight_three_decoder_output(weight_three_wrong_triple_for(subject))
    return String(expected)
end

function weight_three_actual_recovery(subject::WeightThreeSubject,
    decoder_output::AbstractString)

    expected_trigger = weight_three_decoder_output(subject.target_triple)
    if subject.mode == :recovery_triple_bug && decoder_output == expected_trigger
        return weight_three_recovery_action(
            weight_three_decoder_output(weight_three_wrong_triple_for(subject)),
        )
    end
    return weight_three_recovery_action(decoder_output)
end

function apply_weight_three_recovery(faults::AbstractVector{Bool},
    recovery::AbstractDict)

    residual = copy(faults)
    targets = get(recovery, "targets", nothing)
    if targets isa AbstractVector
        for target in targets
            text = String(target)
            startswith(text, "q") || continue
            idx = parse(Int, text[2:end])
            residual[idx] = !residual[idx]
        end
        return residual
    end
    target = String(get(recovery, "target", "none"))
    if startswith(target, "q")
        idx = parse(Int, target[2:end])
        residual[idx] = !residual[idx]
    end
    return residual
end

function weight_three_condition(triple::Tuple{Int,Int,Int})
    return band(
        boolvar(Symbol("x", triple[1])),
        boolvar(Symbol("x", triple[2])),
        boolvar(Symbol("x", triple[3])),
    )
end

function weight_three_decoy_triples(subject::WeightThreeSubject; limit::Int=24)
    triples = Tuple{Int,Int,Int}[]
    for idx in 1:(subject.qubits - 2)
        triple = (idx, idx + 1, idx + 2)
        triple == subject.target_triple && continue
        push!(triples, triple)
        length(triples) >= limit && break
    end
    return triples
end

function record_weight_three_path_branches!(trace::ConcolicTrace,
    subject::WeightThreeSubject)

    for triple in weight_three_decoy_triples(subject)
        taken = all(idx -> trace.fault_assignments[Symbol("x", idx)], triple)
        record_branch!(
            trace,
            "fault:triple_decoy_" * weight_three_label(triple),
            :fault,
            weight_three_condition(triple),
            taken;
            description="weight-three decoy candidate $(weight_three_label(triple))",
        )
    end
    target_taken = all(idx -> trace.fault_assignments[Symbol("x", idx)],
        subject.target_triple)
    record_branch!(
        trace,
        "decoder:target_triple_" * weight_three_label(subject.target_triple),
        :decoder,
        weight_three_condition(subject.target_triple),
        target_taken;
        description="sparse weight-three decoder arm for $(weight_three_label(subject.target_triple))",
    )
    return trace
end

function weight_three_subject_metadata(subject::WeightThreeSubject)
    admissible = weight_three_admissible_assignments(subject.qubits)
    return Dict{String,Any}(
        "subject_family" => "weight_three_correctable_repetition",
        "benchmark_family" => "WeightThreeFaults",
        "benchmark_family_alias" => "WeightThreeCorrectableFaults",
        "mode" => string(subject.mode),
        "qubits" => subject.qubits,
        "fault_variables" => subject.qubits,
        "max_fault_weight" => 3,
        "distance" => 7,
        "fault_model" => "bounded Pauli-X data faults up to weight 3",
        "admissible_fault_assignments" => admissible,
        "syndrome_bits" => subject.qubits,
        "reachable_syndrome_values" => admissible,
        "decoder_arms" => admissible,
        "recovery_actions" => admissible,
        "rounds" => 1,
        "history_states" => 0,
        "target_triple" => collect(subject.target_triple),
        "failing_assignments" => subject.mode == :clean ? 0 : 1,
        "estimated_bug_probability" => subject.mode == :clean ? 0.0 :
            1.0 / admissible,
        "recommended_budget" => subject.budget,
        "exhaustibility_ratio" => subject.budget / admissible,
        "path_sensitive" => subject.mode != :clean,
        "single_fault_baseline" => "misses triple-only trigger",
        "trigger_faults" => [string(Symbol("x", idx)) for idx in subject.target_triple],
        "interesting_faults" => [string(Symbol("x", first(subject.target_triple)))],
        "boring_faults" => [string(Symbol("x", idx)) for idx in 1:min(subject.qubits, 16)],
    )
end

function run_weight_three_subject(subject::WeightThreeSubject, input::AbstractDict)
    fault_vars = weight_three_fault_vars(subject)
    model = normalize_assignment(fault_vars, input)
    faults = [model[var] for var in fault_vars]
    active = findall(identity, faults)
    fault_exprs = [boolvar(var) for var in fault_vars]

    trace = ConcolicTrace(
        subject.name;
        code_size=subject.qubits,
        distance=7,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=weight_three_subject_metadata(subject),
    )

    for idx in 1:subject.qubits
        name = "s_q$(idx)"
        record_syndrome!(trace, name, faults[idx], fault_exprs[idx])
    end
    record_syndrome_bit_branches!(
        trace,
        ["s_q$(idx)" for idx in 1:subject.qubits],
        faults,
        fault_exprs;
        path_constraint=false,
    )
    record_weight_three_path_branches!(trace, subject)

    expected_decoder = weight_three_reference_decoder(active)
    actual_decoder = weight_three_buggy_decoder(subject, expected_decoder)
    record_decoder_decision!(trace, "syndrome", join(["q$(idx)" for idx in active], "+"))
    record_decoder_decision!(trace, "actual", actual_decoder)
    record_decoder_decision!(trace, "expected", expected_decoder)

    expected_recovery = weight_three_recovery_action(expected_decoder)
    actual_recovery = weight_three_actual_recovery(subject, actual_decoder)
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery

    residual = apply_weight_three_recovery(faults, actual_recovery)
    residual_error = Dict{String,Any}("q$(idx)" => residual[idx]
        for idx in eachindex(residual))
    decoder_ok = actual_decoder == expected_decoder
    recovery_ok = actual_recovery["pauli"] == expected_recovery["pauli"] &&
        get(actual_recovery, "target", nothing) == get(expected_recovery, "target", nothing)
    missing_recovery = actual_recovery["pauli"] == "missing"
    within_capacity = length(active) <= 3
    logical_ok = within_capacity ? count(identity, residual) == 0 : true
    oracle_ok = decoder_ok && recovery_ok && logical_ok && !missing_recovery

    record_logical_verdict!(trace, "decoder_mismatch", !decoder_ok)
    record_logical_verdict!(trace, "recovery_mismatch", !recovery_ok || missing_recovery)
    record_logical_verdict!(trace, "logical_mismatch", !logical_ok)
    record_logical_verdict!(trace, "missing_recovery_branch", missing_recovery)
    record_logical_verdict!(trace, "oracle_verdict", oracle_ok)
    record_logical_verdict!(trace, "residual_error", residual_error)
    record_logical_verdict!(trace, "residual_weight", count(identity, residual))

    trace.metadata["weight_three_diagnostics"] = Dict{String,Any}(
        "active_faults" => ["q$(idx)" for idx in active],
        "target_triple" => ["q$(idx)" for idx in subject.target_triple],
        "triple_triggered" => active == collect(subject.target_triple),
        "single_fault_baseline_misses" => length(active) == 1,
    )
    if !decoder_ok || missing_recovery
        trace.metadata["earliest_divergence_stage"] = "decoder"
    elseif !recovery_ok
        trace.metadata["earliest_divergence_stage"] = "recovery"
    elseif !logical_ok
        trace.metadata["earliest_divergence_stage"] = "logical_check"
    end

    return trace
end
