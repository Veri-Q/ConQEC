struct LargeRepetitionSubject
    name::String
    qubits::Int
    mode::Symbol
end

function LargeRepetitionSubject(qubits::Int, mode::Symbol=:clean)
    qubits >= 3 || error("Large repetition subject must have at least 3 qubits")
    mode in (
        :clean,
        :decoder_boundary_bug,
        :wrong_recovery_target,
        :recovery_boundary_bug,
        :unhandled_syndrome_bug,
    ) ||
        error("Unsupported large repetition subject mode: $(mode)")

    names = Dict(
        :clean => "large_repetition_n$(qubits)_clean",
        :decoder_boundary_bug => "large_repetition_n$(qubits)_decoder_boundary_bug",
        :wrong_recovery_target => "large_repetition_n$(qubits)_wrong_recovery_target",
        :recovery_boundary_bug => "large_repetition_n$(qubits)_recovery_boundary_bug",
        :unhandled_syndrome_bug => "large_repetition_n$(qubits)_unhandled_syndrome_bug",
    )
    return LargeRepetitionSubject(names[mode], qubits, mode)
end

large_repetition_fault_vars(qubits::Int) = [Symbol("x", idx) for idx in 1:qubits]
large_repetition_fault_vars(subject::LargeRepetitionSubject) =
    large_repetition_fault_vars(subject.qubits)

large_repetition_syndrome_names(qubits::Int) =
    ["s$(idx)_$(idx + 1)" for idx in 1:(qubits - 1)]

function large_repetition_syndrome_bits(faults::AbstractVector{Bool})
    length(faults) >= 3 || error("large repetition faults must have at least 3 entries")
    return [faults[idx] != faults[idx + 1] for idx in 1:(length(faults) - 1)]
end

function large_repetition_syndrome_string(bits::AbstractVector{Bool})
    return join(bit ? "1" : "0" for bit in bits)
end

function large_repetition_reference_decoder(syndrome_bits::AbstractVector{Bool})
    active = findall(identity, syndrome_bits)
    isempty(active) && return "none"
    if length(active) == 1
        first(active) == 1 && return "q1"
        first(active) == length(syndrome_bits) && return "q$(length(syndrome_bits) + 1)"
        return "uncorrectable"
    end
    if length(active) == 2 && active[2] == active[1] + 1
        return "q$(active[2])"
    end
    return "uncorrectable"
end

function large_repetition_subject_decoder(subject::LargeRepetitionSubject,
    syndrome_bits::AbstractVector{Bool})

    expected = large_repetition_reference_decoder(syndrome_bits)
    if subject.mode == :decoder_boundary_bug && expected == "q1"
        return "q2"
    elseif subject.mode == :unhandled_syndrome_bug && expected == "q1"
        return "uncorrectable"
    end
    return expected
end

function large_repetition_recovery(subject::LargeRepetitionSubject,
    decoder_output::AbstractString)

    output = String(decoder_output)
    if output == "none"
        return Dict{String,Any}("pauli" => "I", "target" => "none", "source" => "decoder")
    elseif output == "uncorrectable"
        return Dict{String,Any}(
            "pauli" => "missing",
            "target" => "uncorrectable",
            "source" => "decoder",
        )
    end

    target = output
    if subject.mode in (:wrong_recovery_target, :recovery_boundary_bug) && output == "q1"
        target = "q2"
    end
    return Dict{String,Any}("pauli" => "X", "target" => target, "source" => "decoder")
end

function apply_large_repetition_recovery(faults::Vector{Bool}, recovery::AbstractDict)
    residual = copy(faults)
    target = String(recovery["target"])
    if startswith(target, "q")
        idx = parse(Int, target[2:end])
        residual[idx] = !residual[idx]
    end
    return residual
end

function large_repetition_syndrome_condition(
    syndrome_exprs::AbstractVector{<:BoolExpr},
    syndrome_bits::AbstractVector{Bool})

    length(syndrome_exprs) == length(syndrome_bits) ||
        error("large repetition syndrome expression/value lengths must match")
    return band(BoolExpr[
        syndrome_bits[idx] ? syndrome_exprs[idx] : bnot(syndrome_exprs[idx])
        for idx in eachindex(syndrome_exprs)
    ]...)
end

function large_repetition_decoder_branch_id(decoder_output::AbstractString)
    output = String(decoder_output)
    output == "none" && return "decoder:no_error"
    output == "uncorrectable" && return "decoder:uncorrectable"
    return "decoder:single_fault_" * output
end

function record_large_repetition_decoder_branch!(
    trace::ConcolicTrace,
    subject::LargeRepetitionSubject,
    expected_decoder::AbstractString,
    syndrome_exprs::AbstractVector{<:BoolExpr},
    syndrome_bits::AbstractVector{Bool})

    record_branch!(
        trace,
        large_repetition_decoder_branch_id(expected_decoder),
        :decoder,
        large_repetition_syndrome_condition(syndrome_exprs, syndrome_bits),
        true;
        description="compact large-repetition decoder branch for $(expected_decoder)",
    )
    return trace
end

function record_large_repetition_recovery_branch!(
    trace::ConcolicTrace,
    actual_decoder::AbstractString)

    record_branch!(
        trace,
        "recovery:decoder_output_" * branch_id_token(actual_decoder),
        :recovery,
        bconst(true),
        true;
        description="compact recovery branch selected by decoder output $(actual_decoder)",
    )
    return trace
end

function run_large_repetition_subject(subject::LargeRepetitionSubject, input::AbstractDict)
    fault_vars = large_repetition_fault_vars(subject)
    model = normalize_assignment(fault_vars, input)
    faults = [model[var] for var in fault_vars]
    syndrome_bits = large_repetition_syndrome_bits(faults)
    syndrome_names = large_repetition_syndrome_names(subject.qubits)
    fault_exprs = [boolvar(var) for var in fault_vars]
    syndrome_exprs = BoolExpr[
        bxor(fault_exprs[idx], fault_exprs[idx + 1])
        for idx in 1:(subject.qubits - 1)
    ]

    trace = ConcolicTrace(
        subject.name;
        code_size=subject.qubits,
        distance=subject.qubits,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=Dict{String,Any}(
            "subject_family" => "large_repetition_code",
            "mode" => string(subject.mode),
            "fault_model" => "single Pauli-X data fault over n data qubits",
            "max_fault_weight" => 1,
            "qubits" => subject.qubits,
            "syndrome_bits" => subject.qubits - 1,
            "scalability_profile" => "large_100_to_1000_qubits",
            "decoder" => "linear single-fault repetition decoder",
            "trace_encoding" => "compact large-scale syndrome and decoder path",
        ),
    )

    for (name, value, expr) in zip(syndrome_names, syndrome_bits, syndrome_exprs)
        record_syndrome!(trace, name, value, expr)
    end
    record_syndrome_bit_branches!(
        trace,
        syndrome_names,
        syndrome_bits,
        syndrome_exprs,
    )

    syndrome = large_repetition_syndrome_string(syndrome_bits)
    expected_decoder = large_repetition_reference_decoder(syndrome_bits)
    actual_decoder = large_repetition_subject_decoder(subject, syndrome_bits)
    record_large_repetition_decoder_branch!(
        trace,
        subject,
        expected_decoder,
        syndrome_exprs,
        syndrome_bits,
    )
    record_decoder_decision!(trace, "syndrome", syndrome)
    record_decoder_decision!(trace, "actual", actual_decoder)
    record_decoder_decision!(trace, "expected", expected_decoder)

    actual_recovery = large_repetition_recovery(subject, actual_decoder)
    expected_recovery = large_repetition_recovery(
        LargeRepetitionSubject(subject.qubits, :clean),
        expected_decoder,
    )
    record_large_repetition_recovery_branch!(trace, actual_decoder)
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery

    residual = apply_large_repetition_recovery(faults, actual_recovery)
    residual_error = Dict{String,Any}(
        "q$(idx)" => residual[idx]
        for idx in eachindex(residual)
    )
    decoder_ok = actual_decoder == expected_decoder
    recovery_ok = actual_recovery["pauli"] == expected_recovery["pauli"] &&
        actual_recovery["target"] == expected_recovery["target"]
    missing_recovery = actual_recovery["pauli"] == "missing"
    logical_ok = count(identity, residual) == 0
    oracle_ok = decoder_ok && recovery_ok && logical_ok && !missing_recovery

    record_logical_verdict!(trace, "decoder_mismatch", !decoder_ok)
    record_logical_verdict!(trace, "recovery_mismatch", !recovery_ok || missing_recovery)
    record_logical_verdict!(trace, "logical_mismatch", !logical_ok)
    record_logical_verdict!(trace, "missing_recovery_branch", missing_recovery)
    record_logical_verdict!(trace, "oracle_verdict", oracle_ok)
    record_logical_verdict!(trace, "residual_error", residual_error)
    record_logical_verdict!(trace, "residual_weight", count(identity, residual))

    trace.metadata["large_scale_summary"] = Dict{String,Any}(
        "qubits" => subject.qubits,
        "syndrome_bits" => subject.qubits - 1,
        "active_faults" => active_fault_vars(trace),
        "observed_syndrome_weight" => count(identity, syndrome_bits),
        "expected_decoder" => expected_decoder,
        "actual_decoder" => actual_decoder,
    )
    trace.metadata["symbolic_stabilizer"] = Dict{String,Any}(
        "code" => "large_repetition_code",
        "tracked_pauli" => "X",
        "representation" => "compact repetition-code Pauli-frame summary",
        "generator_count" => subject.qubits - 1,
        "pre_recovery_residual_weight" => count(identity, faults),
        "post_recovery_residual_weight" => count(identity, residual),
        "logical_ok" => logical_ok,
        "compact_large_repetition" => true,
    )
    if !decoder_ok
        trace.metadata["earliest_divergence_stage"] = "decoder"
    elseif !recovery_ok || missing_recovery
        trace.metadata["earliest_divergence_stage"] = "recovery"
    elseif !logical_ok
        trace.metadata["earliest_divergence_stage"] = "logical_check"
    end

    return trace
end
