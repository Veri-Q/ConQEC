struct WeightTwoSubject
    name::String
    qubits::Int
    mode::Symbol
    target_pair::Tuple{Int,Int}
    budget::Int
end

const WEIGHT_TWO_MODES = (
    :clean,
    :decoder_pair_bug,
    :recovery_pair_bug,
    :unhandled_pair_bug,
)

function WeightTwoSubject(qubits::Int, mode::Symbol=:clean;
    target_pair::Tuple{Int,Int}=weight_two_default_target_pair(qubits, mode),
    budget::Integer=weight_two_recommended_budget(qubits))

    qubits >= 5 || error("Weight-two subject must have at least 5 qubits")
    mode in WEIGHT_TWO_MODES ||
        error("Unsupported weight-two subject mode: $(mode)")
    first_q, second_q = target_pair
    1 <= first_q < second_q <= qubits ||
        error("target_pair must satisfy 1 <= i < j <= qubits")
    budget > 0 || error("budget must be positive")

    suffix = mode == :clean ? "clean" :
        string(mode, "_q", first_q, "_q", second_q)
    return WeightTwoSubject(
        "weight2_repetition_n$(qubits)_$(suffix)",
        qubits,
        mode,
        target_pair,
        Int(budget),
    )
end

function weight_two_default_target_pair(qubits::Int, mode::Symbol=:clean)
    if mode == :clean
        return (max(1, cld(qubits, 3)), max(2, fld(2 * qubits, 3)))
    elseif mode == :decoder_pair_bug
        return (max(2, cld(qubits, 4)), max(3, fld(3 * qubits, 4)))
    elseif mode == :recovery_pair_bug
        return (max(2, cld(qubits, 5)), max(3, fld(4 * qubits, 5)))
    elseif mode == :unhandled_pair_bug
        return (max(2, cld(qubits, 6)), max(3, fld(5 * qubits, 6)))
    end
    return (1, qubits)
end

weight_two_fault_vars(qubits::Int) = [Symbol("x", idx) for idx in 1:qubits]
weight_two_fault_vars(subject::WeightTwoSubject) =
    weight_two_fault_vars(subject.qubits)

weight_two_admissible_assignments(qubits::Int) =
    qubits + fld(qubits * (qubits - 1), 2)

weight_two_recommended_budget(qubits::Int) =
    qubits <= 50 ? 32 : 64

weight_two_pair_label(pair::Tuple{Int,Int}) =
    "q$(pair[1])_q$(pair[2])"

weight_two_decoder_output(pair::Tuple{Int,Int}) =
    "pair:" * weight_two_pair_label(pair)

function weight_two_recovery_action(decoder_output::AbstractString)
    output = String(decoder_output)
    output == "none" &&
        return Dict{String,Any}("pauli" => "I", "target" => "none", "source" => "decoder")
    output in ("missing", "uncorrectable") &&
        return Dict{String,Any}(
            "pauli" => "missing",
            "target" => output,
            "source" => "decoder",
        )
    if startswith(output, "q")
        return Dict{String,Any}(
            "pauli" => "X",
            "target" => output,
            "source" => "decoder",
        )
    end
    startswith(output, "pair:") ||
        error("Unsupported weight-two decoder output: $(decoder_output)")
    pair_text = split(output[6:end], "_")
    targets = [String(part) for part in pair_text]
    return Dict{String,Any}(
        "pauli" => "X",
        "target" => join(targets, "+"),
        "targets" => targets,
        "source" => "decoder",
    )
end

function weight_two_reference_decoder(active::AbstractVector{Int})
    isempty(active) && return "none"
    length(active) == 1 && return "q$(only(active))"
    length(active) == 2 && return weight_two_decoder_output((active[1], active[2]))
    return "uncorrectable"
end

function weight_two_buggy_decoder(subject::WeightTwoSubject, expected::AbstractString)
    subject.mode == :unhandled_pair_bug && expected == weight_two_decoder_output(subject.target_pair) &&
        return "missing"
    if subject.mode == :decoder_pair_bug && expected == weight_two_decoder_output(subject.target_pair)
        first_q, second_q = subject.target_pair
        wrong_second = second_q == subject.qubits ? second_q - 1 : second_q + 1
        wrong_pair = sort!([first_q, wrong_second])
        return weight_two_decoder_output((wrong_pair[1], wrong_pair[2]))
    end
    return String(expected)
end

function weight_two_actual_recovery(subject::WeightTwoSubject, decoder_output::AbstractString)
    expected_trigger = weight_two_decoder_output(subject.target_pair)
    if subject.mode == :recovery_pair_bug && decoder_output == expected_trigger
        first_q, second_q = subject.target_pair
        wrong_second = second_q == subject.qubits ? second_q - 1 : second_q + 1
        wrong_pair = sort!([first_q, wrong_second])
        return weight_two_recovery_action(weight_two_decoder_output((wrong_pair[1], wrong_pair[2])))
    end
    return weight_two_recovery_action(decoder_output)
end

function apply_weight_two_recovery(faults::AbstractVector{Bool}, recovery::AbstractDict)
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

function weight_two_pair_condition(pair::Tuple{Int,Int})
    return band(boolvar(Symbol("x", pair[1])), boolvar(Symbol("x", pair[2])))
end

function weight_two_decoy_pairs(subject::WeightTwoSubject; limit::Int=24)
    pairs = Tuple{Int,Int}[]
    for idx in 1:(subject.qubits - 1)
        pair = (idx, idx + 1)
        pair == subject.target_pair && continue
        push!(pairs, pair)
        length(pairs) >= limit && break
    end
    return pairs
end

function record_weight_two_path_branches!(trace::ConcolicTrace, subject::WeightTwoSubject)
    for pair in weight_two_decoy_pairs(subject)
        taken = trace.fault_assignments[Symbol("x", pair[1])] &&
            trace.fault_assignments[Symbol("x", pair[2])]
        record_branch!(
            trace,
            "fault:pair_decoy_" * weight_two_pair_label(pair),
            :fault,
            weight_two_pair_condition(pair),
            taken;
            description="weight-two decoy candidate $(weight_two_pair_label(pair))",
        )
    end
    target_taken = trace.fault_assignments[Symbol("x", subject.target_pair[1])] &&
        trace.fault_assignments[Symbol("x", subject.target_pair[2])]
    record_branch!(
        trace,
        "decoder:target_pair_" * weight_two_pair_label(subject.target_pair),
        :decoder,
        weight_two_pair_condition(subject.target_pair),
        target_taken;
        description="sparse weight-two decoder arm for $(weight_two_pair_label(subject.target_pair))",
    )
    return trace
end

function weight_two_subject_metadata(subject::WeightTwoSubject)
    admissible = weight_two_admissible_assignments(subject.qubits)
    return Dict{String,Any}(
        "subject_family" => "weight_two_correctable_repetition",
        "benchmark_family" => "WeightTwoFaults",
        "benchmark_family_alias" => "WeightTwoCorrectableFaults",
        "mode" => string(subject.mode),
        "qubits" => subject.qubits,
        "fault_variables" => subject.qubits,
        "max_fault_weight" => 2,
        "distance" => 5,
        "fault_model" => "bounded Pauli-X data faults up to weight 2",
        "admissible_fault_assignments" => admissible,
        "syndrome_bits" => subject.qubits,
        "reachable_syndrome_values" => admissible + 1,
        "decoder_arms" => admissible + 1,
        "recovery_actions" => admissible + 1,
        "rounds" => 1,
        "history_states" => 0,
        "target_pair" => collect(subject.target_pair),
        "failing_assignments" => subject.mode == :clean ? 0 : 1,
        "estimated_bug_probability" => subject.mode == :clean ? 0.0 : 1.0 / admissible,
        "recommended_budget" => subject.budget,
        "exhaustibility_ratio" =>
            subject.budget / admissible,
        "path_sensitive" => subject.mode != :clean,
        "single_fault_baseline" => "misses pair-only trigger",
        "trigger_faults" => [
            string(Symbol("x", subject.target_pair[1])),
            string(Symbol("x", subject.target_pair[2])),
        ],
        "interesting_faults" => [string(Symbol("x", subject.target_pair[1]))],
        "boring_faults" => [string(Symbol("x", idx)) for idx in 1:min(subject.qubits, 16)],
    )
end

function run_weight_two_subject(subject::WeightTwoSubject, input::AbstractDict)
    fault_vars = weight_two_fault_vars(subject)
    model = normalize_assignment(fault_vars, input)
    faults = [model[var] for var in fault_vars]
    active = findall(identity, faults)
    fault_exprs = [boolvar(var) for var in fault_vars]

    trace = ConcolicTrace(
        subject.name;
        code_size=subject.qubits,
        distance=5,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=weight_two_subject_metadata(subject),
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
    record_weight_two_path_branches!(trace, subject)

    expected_decoder = weight_two_reference_decoder(active)
    actual_decoder = weight_two_buggy_decoder(subject, expected_decoder)
    record_decoder_decision!(trace, "syndrome", join(["q$(idx)" for idx in active], "+"))
    record_decoder_decision!(trace, "actual", actual_decoder)
    record_decoder_decision!(trace, "expected", expected_decoder)

    expected_recovery = weight_two_recovery_action(expected_decoder)
    actual_recovery = weight_two_actual_recovery(subject, actual_decoder)
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery

    residual = apply_weight_two_recovery(faults, actual_recovery)
    residual_error = Dict{String,Any}("q$(idx)" => residual[idx] for idx in eachindex(residual))
    decoder_ok = actual_decoder == expected_decoder
    recovery_ok = actual_recovery["pauli"] == expected_recovery["pauli"] &&
        get(actual_recovery, "target", nothing) == get(expected_recovery, "target", nothing)
    missing_recovery = actual_recovery["pauli"] == "missing"
    within_capacity = length(active) <= 2
    logical_ok = within_capacity ? count(identity, residual) == 0 : true
    oracle_ok = decoder_ok && recovery_ok && logical_ok && !missing_recovery

    record_logical_verdict!(trace, "decoder_mismatch", !decoder_ok)
    record_logical_verdict!(trace, "recovery_mismatch", !recovery_ok || missing_recovery)
    record_logical_verdict!(trace, "logical_mismatch", !logical_ok)
    record_logical_verdict!(trace, "missing_recovery_branch", missing_recovery)
    record_logical_verdict!(trace, "oracle_verdict", oracle_ok)
    record_logical_verdict!(trace, "residual_error", residual_error)
    record_logical_verdict!(trace, "residual_weight", count(identity, residual))

    trace.metadata["weight_two_diagnostics"] = Dict{String,Any}(
        "active_faults" => ["q$(idx)" for idx in active],
        "target_pair" => ["q$(subject.target_pair[1])", "q$(subject.target_pair[2])"],
        "pair_triggered" => active == collect(subject.target_pair),
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
