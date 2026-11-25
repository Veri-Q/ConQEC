struct RepetitionSubject
    name::String
    distance::Int
    mode::Symbol
end

function RepetitionSubject(distance::Int, mode::Symbol=:clean)
    distance >= 3 || error("Repetition-code distance must be at least 3")
    isodd(distance) || error("Repetition-code distance must be odd")
    mode in (:clean, :decoder_neighbor_bug, :wrong_recovery_target) ||
        error("Unsupported repetition-code subject mode: $(mode)")

    names = Dict(
        :clean => "repetition_d$(distance)_clean",
        :decoder_neighbor_bug => "repetition_d$(distance)_decoder_neighbor_bug",
        :wrong_recovery_target => "repetition_d$(distance)_wrong_recovery_target",
    )
    return RepetitionSubject(names[mode], distance, mode)
end

repetition_fault_vars(distance::Int) = [Symbol("x", idx) for idx in 1:distance]
repetition_fault_vars(subject::RepetitionSubject) = repetition_fault_vars(subject.distance)

function repetition_syndrome_names(distance::Int)
    return ["s$(idx)$(idx + 1)" for idx in 1:(distance - 1)]
end

function repetition_stabilizer_supports(distance::Int)
    return [[idx, idx + 1] for idx in 1:(distance - 1)]
end

function repetition_symbolic_stabilizer(distance::Int,
    fault_exprs::AbstractVector{<:BoolExpr})

    return symbolic_stabilizer_from_faults(
        "repetition_d$(distance)",
        distance,
        repetition_syndrome_names(distance),
        repetition_stabilizer_supports(distance),
        fault_exprs;
        pauli="X",
        generator_paulis=["Z" for _ in 1:(distance - 1)],
    )
end

function repetition_syndrome_string(bits::AbstractVector{Bool})
    return join(bit ? "1" : "0" for bit in bits)
end

function syndrome_from_single_fault(distance::Int, fault_index::Int)
    bits = falses(distance - 1)
    fault_index > 1 && (bits[fault_index - 1] = true)
    fault_index < distance && (bits[fault_index] = true)
    return repetition_syndrome_string(bits)
end

function repetition_single_fault_decoder_table(distance::Int)
    table = Dict{String,String}(repeat("0", distance - 1) => "none")
    for fault_index in 1:distance
        table[syndrome_from_single_fault(distance, fault_index)] = "q$(fault_index)"
    end
    return table
end

function reference_repetition_decoder(distance::Int, syndrome::AbstractString; max_fault_weight::Int=1)
    max_fault_weight == 1 ||
        error("reference_repetition_decoder currently supports max_fault_weight=1")
    table = repetition_single_fault_decoder_table(distance)
    return get(table, String(syndrome), "uncorrectable")
end

function subject_decoder(subject::RepetitionSubject, syndrome::AbstractString)
    table = repetition_single_fault_decoder_table(subject.distance)
    if subject.mode == :decoder_neighbor_bug
        table[syndrome_from_single_fault(subject.distance, 1)] = "q2"
    end
    return get(table, String(syndrome), "uncorrectable")
end

function repetition_recovery_from_decoder(subject::RepetitionSubject, decoder_output::AbstractString)
    output = String(decoder_output)
    if output == "none"
        return Dict{String,Any}(
            "pauli" => "I",
            "target" => "none",
            "source" => "decoder",
        )
    elseif output == "uncorrectable"
        return Dict{String,Any}(
            "pauli" => "missing",
            "target" => "uncorrectable",
            "source" => "decoder",
        )
    end

    target = output
    if subject.mode == :wrong_recovery_target && output == "q1"
        target = "q2"
    end
    return Dict{String,Any}(
        "pauli" => "X",
        "target" => target,
        "source" => "decoder",
    )
end

function apply_repetition_recovery(faults::Vector{Bool}, recovery::Dict{String,Any})
    residual = copy(faults)
    target = String(recovery["target"])
    if startswith(target, "q")
        idx = parse(Int, target[2:end])
        residual[idx] = !residual[idx]
    end
    return residual
end

function syndrome_equals_expr(syndrome_exprs::AbstractVector{<:BoolExpr}, syndrome::AbstractString)
    terms = BoolExpr[]
    for (expr, bit) in zip(syndrome_exprs, syndrome)
        push!(terms, bit == '1' ? expr : bnot(expr))
    end
    return band(terms...)
end

function repetition_decoder_arm_order(distance::Int)
    arms = [repeat("0", distance - 1)]
    append!(arms, [syndrome_from_single_fault(distance, fault_index) for fault_index in 1:distance])
    return arms
end

function repetition_decoder_recovery_semantics(subject::RepetitionSubject)
    rows = Dict{String,Any}[]
    names = repetition_syndrome_names(subject.distance)
    for syndrome in repetition_decoder_arm_order(subject.distance)
        decoder_output = subject_decoder(subject, syndrome)
        push!(
            rows,
            decoder_recovery_semantics_row(
                "decoder:syndrome_$(syndrome)",
                smt_syndrome_pattern(names, syndrome),
                decoder_output,
                repetition_recovery_from_decoder(subject, decoder_output),
            ),
        )
    end
    return rows
end

function repetition_decoder_output_conditions(subject::RepetitionSubject,
    syndrome_exprs::AbstractVector{<:BoolExpr})

    outputs = unique!(
        [subject_decoder(subject, syndrome) for syndrome in repetition_decoder_arm_order(subject.distance)]
    )
    conditions = Tuple{String,BoolExpr}[]
    for output in outputs
        terms = BoolExpr[
            syndrome_equals_expr(syndrome_exprs, syndrome)
            for syndrome in repetition_decoder_arm_order(subject.distance)
            if subject_decoder(subject, syndrome) == output
        ]
        isempty(terms) && continue
        push!(conditions, (output, length(terms) == 1 ? terms[1] : bor(terms...)))
    end
    return conditions
end

function select_decoder_output!(trace::ConcolicTrace, subject::RepetitionSubject,
    syndrome_exprs::AbstractVector{<:BoolExpr}, syndrome_bits::AbstractVector{Bool})

    syndrome = repetition_syndrome_string(syndrome_bits)
    for arm in repetition_decoder_arm_order(subject.distance)
        condition = syndrome_equals_expr(syndrome_exprs, arm)
        taken = syndrome == arm
        record_branch!(
            trace,
            "decoder:syndrome_$(arm)",
            :decoder,
            condition,
            taken;
            description="decoder table arm for repetition-code syndrome $(arm)",
        )
        taken && return subject_decoder(subject, arm)
    end
    return "uncorrectable"
end

function run_repetition_subject(subject::RepetitionSubject, input::AbstractDict)
    fault_vars = repetition_fault_vars(subject.distance)
    model = normalize_assignment(fault_vars, input)

    trace = ConcolicTrace(
        subject.name;
        code_size=subject.distance,
        distance=subject.distance,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=Dict{String,Any}(
            "subject_family" => "repetition_code",
            "fault_model" => "single Pauli-X data fault",
            "max_fault_weight" => 1,
            "decoder" => "deterministic nearest single-fault syndrome table",
        ),
    )

    fault_exprs = [boolvar(var) for var in fault_vars]
    pre_recovery_state = repetition_symbolic_stabilizer(subject.distance, fault_exprs)
    syndrome_exprs = stabilizer_generator_phase_exprs(pre_recovery_state)
    syndrome_bits = [evaluate(expr, model) for expr in syndrome_exprs]
    syndrome = repetition_syndrome_string(syndrome_bits)

    for (name, value, expr) in zip(
        repetition_syndrome_names(subject.distance),
        syndrome_bits,
        syndrome_exprs,
    )
        record_syndrome!(trace, name, value, expr)
    end

    actual_decoder = select_decoder_output!(trace, subject, syndrome_exprs, syndrome_bits)
    record_syndrome_bit_branches!(
        trace,
        repetition_syndrome_names(subject.distance),
        syndrome_bits,
        syndrome_exprs,
    )
    expected_decoder = reference_repetition_decoder(subject.distance, syndrome)

    record_decoder_decision!(trace, "syndrome", syndrome)
    record_decoder_decision!(trace, "actual", actual_decoder)
    record_decoder_decision!(trace, "expected", expected_decoder)

    actual_recovery = repetition_recovery_from_decoder(subject, actual_decoder)
    expected_recovery = repetition_recovery_from_decoder(
        RepetitionSubject(subject.distance, :clean),
        expected_decoder,
    )
    record_recovery_output_branches!(
        trace,
        actual_decoder,
        repetition_decoder_output_conditions(subject, syndrome_exprs),
    )
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    set_decoder_recovery_semantics!(
        trace,
        repetition_decoder_recovery_semantics(subject),
    )

    post_recovery_state = copy_symbolic_stabilizer_state(pre_recovery_state)
    absorb_recovery!(post_recovery_state, actual_recovery)
    residual = symbolic_residual_vector(post_recovery_state, model)
    residual_error = Dict{String,Any}(
        "q$(idx)" => residual[idx]
        for idx in eachindex(residual)
    )
    record_symbolic_stabilizer_summary!(
        trace,
        pre_recovery_state,
        post_recovery_state,
        model,
    )

    decoder_ok = actual_decoder == expected_decoder
    recovery_ok = actual_recovery["pauli"] == expected_recovery["pauli"] &&
        actual_recovery["target"] == expected_recovery["target"]
    missing_recovery = actual_recovery["pauli"] == "missing"
    logical_ok = symbolic_logical_ok(post_recovery_state, model)
    oracle_ok = decoder_ok && recovery_ok && logical_ok && !missing_recovery

    record_logical_verdict!(trace, "decoder_mismatch", !decoder_ok)
    record_logical_verdict!(trace, "recovery_mismatch", !recovery_ok || missing_recovery)
    record_logical_verdict!(trace, "logical_mismatch", !logical_ok)
    record_logical_verdict!(trace, "missing_recovery_branch", missing_recovery)
    record_logical_verdict!(trace, "oracle_verdict", oracle_ok)
    record_logical_verdict!(trace, "residual_error", residual_error)
    record_logical_verdict!(trace, "residual_weight", count(identity, residual))

    if !decoder_ok
        trace.metadata["earliest_divergence_stage"] = "decoder"
    elseif !recovery_ok || missing_recovery
        trace.metadata["earliest_divergence_stage"] = "recovery"
    elseif !logical_ok
        trace.metadata["earliest_divergence_stage"] = "logical_check"
    end

    return trace
end
