struct PhaseFlipSubject
    name::String
    mode::Symbol
end

function PhaseFlipSubject(mode::Symbol=:clean)
    mode in (:clean, :buggy_decoder, :wrong_recovery_target) ||
        error("Unsupported phase-flip subject mode: $(mode)")
    names = Dict(
        :clean => "phaseflip_clean",
        :buggy_decoder => "phaseflip_buggy_decoder_table",
        :wrong_recovery_target => "phaseflip_wrong_recovery_target",
    )
    return PhaseFlipSubject(names[mode], mode)
end

phaseflip_fault_vars() = [:z1, :z2, :z3]

function reference_phaseflip_decoder(syndrome::AbstractString)
    table = Dict(
        "00" => "none",
        "10" => "q1",
        "11" => "q2",
        "01" => "q3",
    )
    return table[String(syndrome)]
end

function subject_decoder(subject::PhaseFlipSubject, syndrome::AbstractString)
    table = Dict(
        "00" => "none",
        "10" => "q1",
        "11" => "q2",
        "01" => "q3",
    )
    if subject.mode == :buggy_decoder
        table["10"] = "q2"
    end
    return get(table, String(syndrome), "missing")
end

function phaseflip_syndrome_string(s12::Bool, s23::Bool)
    return (s12 ? "1" : "0") * (s23 ? "1" : "0")
end

function phaseflip_syndrome_condition(s12_expr::BoolExpr, s23_expr::BoolExpr,
    syndrome::AbstractString)

    syndrome = String(syndrome)
    length(syndrome) == 2 || error("phase-flip syndrome must have two bits")
    return band(
        syndrome[1] == '1' ? s12_expr : bnot(s12_expr),
        syndrome[2] == '1' ? s23_expr : bnot(s23_expr),
    )
end

function phaseflip_syndrome_bits_dict(s12::Bool, s23::Bool)
    return Dict{String,Any}(
        "s12" => s12,
        "s23" => s23,
    )
end

phaseflip_syndrome_names() = ["s12", "s23"]

phaseflip_stabilizer_supports() = [[1, 2], [2, 3]]

function phaseflip_symbolic_stabilizer(fault_exprs::AbstractVector{<:BoolExpr})
    return symbolic_stabilizer_from_faults(
        "three_qubit_phaseflip",
        3,
        phaseflip_syndrome_names(),
        phaseflip_stabilizer_supports(),
        fault_exprs;
        pauli="Z",
        generator_paulis=["X", "X"],
    )
end

function phaseflip_decoder_recovery_semantics(subject::PhaseFlipSubject)
    arms = [
        ("decoder:syndrome_00", "00"),
        ("decoder:syndrome_10", "10"),
        ("decoder:syndrome_11", "11"),
        ("decoder:syndrome_01", "01"),
    ]
    rows = Dict{String,Any}[]
    for (branch_id, syndrome) in arms
        decoder_output = subject_decoder(subject, syndrome)
        push!(
            rows,
            decoder_recovery_semantics_row(
                branch_id,
                smt_syndrome_pattern(phaseflip_syndrome_names(), syndrome),
                decoder_output,
                phaseflip_recovery_from_decoder(subject, decoder_output),
            ),
        )
    end
    return rows
end

function phaseflip_decoder_output_conditions(subject::PhaseFlipSubject,
    s12_expr::BoolExpr,
    s23_expr::BoolExpr)

    outputs = ["none", "q1", "q2", "q3", "missing"]
    conditions = Tuple{String,BoolExpr}[]
    for output in outputs
        terms = BoolExpr[
            phaseflip_syndrome_condition(s12_expr, s23_expr, syndrome)
            for syndrome in ("00", "10", "11", "01")
            if subject_decoder(subject, syndrome) == output
        ]
        isempty(terms) && continue
        push!(conditions, (output, length(terms) == 1 ? terms[1] : bor(terms...)))
    end
    return conditions
end

function phaseflip_syndrome_exprs(z1_expr::BoolExpr, z2_expr::BoolExpr, z3_expr::BoolExpr)
    s12_expr = bxor(z1_expr, z2_expr)
    s23_expr = bxor(z2_expr, z3_expr)
    return (
        observed_s12_expr=s12_expr,
        observed_s23_expr=s23_expr,
        expected_s12_expr=s12_expr,
        expected_s23_expr=s23_expr,
    )
end

function phaseflip_recovery_from_decoder(subject::PhaseFlipSubject, decoder_output::AbstractString)
    output = String(decoder_output)
    if output == "none"
        return Dict{String,Any}(
            "pauli" => "I",
            "target" => "none",
            "source" => "decoder",
        )
    elseif output == "missing"
        return Dict{String,Any}(
            "pauli" => "missing",
            "target" => "missing",
            "source" => "decoder",
        )
    end

    target = output
    if subject.mode == :wrong_recovery_target && output == "q1"
        target = "q2"
    end
    return Dict{String,Any}(
        "pauli" => "Z",
        "target" => target,
        "source" => "decoder",
    )
end

function apply_phaseflip_recovery(faults::Vector{Bool}, recovery::Dict{String,Any})
    residual = copy(faults)
    target = String(recovery["target"])
    if startswith(target, "q")
        idx = parse(Int, target[2:end])
        residual[idx] = !residual[idx]
    end
    return residual
end

function select_decoder_output!(trace::ConcolicTrace, subject::PhaseFlipSubject,
    s12_expr::BoolExpr, s23_expr::BoolExpr, s12::Bool, s23::Bool)

    cond00 = band(bnot(s12_expr), bnot(s23_expr))
    take00 = !s12 && !s23
    record_branch!(
        trace,
        "decoder:syndrome_00",
        :decoder,
        cond00,
        take00;
        description="decoder table arm for syndrome 00",
    )
    take00 && return subject_decoder(subject, "00")

    cond10 = band(s12_expr, bnot(s23_expr))
    take10 = s12 && !s23
    record_branch!(
        trace,
        "decoder:syndrome_10",
        :decoder,
        cond10,
        take10;
        description="decoder table arm for syndrome 10",
    )
    take10 && return subject_decoder(subject, "10")

    cond11 = band(s12_expr, s23_expr)
    take11 = s12 && s23
    record_branch!(
        trace,
        "decoder:syndrome_11",
        :decoder,
        cond11,
        take11;
        description="decoder table arm for syndrome 11",
    )
    take11 && return subject_decoder(subject, "11")

    cond01 = band(bnot(s12_expr), s23_expr)
    take01 = !s12 && s23
    record_branch!(
        trace,
        "decoder:syndrome_01",
        :decoder,
        cond01,
        take01;
        description="decoder table arm for syndrome 01",
    )
    take01 && return subject_decoder(subject, "01")

    return "missing"
end

function run_phaseflip_subject(subject::PhaseFlipSubject, input::AbstractDict)
    fault_vars = phaseflip_fault_vars()
    model = normalize_assignment(fault_vars, input)

    trace = ConcolicTrace(
        subject.name;
        code_size=3,
        distance=3,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=Dict{String,Any}(
            "subject_family" => "three_qubit_phaseflip",
            "mode" => string(subject.mode),
            "fault_model" => "single Pauli-Z data fault",
            "max_fault_weight" => 1,
            "css_orientation" => "X-check repetition syndrome for Z data faults",
        ),
    )

    z1_expr = boolvar(:z1)
    z2_expr = boolvar(:z2)
    z3_expr = boolvar(:z3)
    pre_recovery_state = phaseflip_symbolic_stabilizer(BoolExpr[z1_expr, z2_expr, z3_expr])
    expected_syndrome_exprs = stabilizer_generator_phase_exprs(pre_recovery_state)
    syndrome_exprs = (
        observed_s12_expr=expected_syndrome_exprs[1],
        observed_s23_expr=expected_syndrome_exprs[2],
        expected_s12_expr=expected_syndrome_exprs[1],
        expected_s23_expr=expected_syndrome_exprs[2],
    )

    s12 = evaluate(syndrome_exprs.observed_s12_expr, model)
    s23 = evaluate(syndrome_exprs.observed_s23_expr, model)
    expected_s12 = evaluate(syndrome_exprs.expected_s12_expr, model)
    expected_s23 = evaluate(syndrome_exprs.expected_s23_expr, model)
    syndrome = phaseflip_syndrome_string(s12, s23)
    expected_syndrome = phaseflip_syndrome_string(expected_s12, expected_s23)

    record_syndrome!(trace, "s12", s12, syndrome_exprs.observed_s12_expr)
    record_syndrome!(trace, "s23", s23, syndrome_exprs.observed_s23_expr)

    actual_decoder = select_decoder_output!(
        trace,
        subject,
        syndrome_exprs.observed_s12_expr,
        syndrome_exprs.observed_s23_expr,
        s12,
        s23,
    )
    record_syndrome_bit_branches!(
        trace,
        ["s12", "s23"],
        [s12, s23],
        BoolExpr[
            syndrome_exprs.observed_s12_expr,
            syndrome_exprs.observed_s23_expr,
        ],
    )
    expected_decoder = reference_phaseflip_decoder(expected_syndrome)

    record_decoder_decision!(trace, "syndrome", syndrome)
    record_decoder_decision!(trace, "observed_syndrome", syndrome)
    record_decoder_decision!(trace, "expected_syndrome", expected_syndrome)
    record_decoder_decision!(trace, "actual", actual_decoder)
    record_decoder_decision!(trace, "expected", expected_decoder)

    actual_recovery = phaseflip_recovery_from_decoder(subject, actual_decoder)
    expected_recovery = phaseflip_recovery_from_decoder(PhaseFlipSubject(:clean), expected_decoder)
    record_recovery_output_branches!(
        trace,
        actual_decoder,
        phaseflip_decoder_output_conditions(
            subject,
            syndrome_exprs.observed_s12_expr,
            syndrome_exprs.observed_s23_expr,
        ),
    )
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    set_decoder_recovery_semantics!(
        trace,
        phaseflip_decoder_recovery_semantics(subject),
    )
    trace.metadata["syndrome_diagnostics"] = Dict{String,Any}(
        "observed" => syndrome,
        "expected" => expected_syndrome,
        "observed_bits" => phaseflip_syndrome_bits_dict(s12, s23),
        "expected_bits" => phaseflip_syndrome_bits_dict(expected_s12, expected_s23),
        "syndrome_mismatch" => syndrome != expected_syndrome,
    )

    post_recovery_state = copy_symbolic_stabilizer_state(pre_recovery_state)
    absorb_recovery!(post_recovery_state, actual_recovery)
    residual = symbolic_residual_vector(post_recovery_state, model)
    logical_ok = symbolic_logical_ok(post_recovery_state, model)
    record_symbolic_stabilizer_summary!(
        trace,
        pre_recovery_state,
        post_recovery_state,
        model,
    )
    syndrome_ok = syndrome == expected_syndrome
    decoder_ok = actual_decoder == expected_decoder
    recovery_ok = actual_recovery["pauli"] == expected_recovery["pauli"] &&
        actual_recovery["target"] == expected_recovery["target"]
    missing_recovery = actual_recovery["target"] == "missing"
    oracle_ok = syndrome_ok && decoder_ok && recovery_ok && logical_ok && !missing_recovery

    record_logical_verdict!(trace, "syndrome_mismatch", !syndrome_ok)
    record_logical_verdict!(trace, "decoder_mismatch", !decoder_ok)
    record_logical_verdict!(trace, "recovery_mismatch", !recovery_ok || missing_recovery)
    record_logical_verdict!(trace, "logical_mismatch", !logical_ok)
    record_logical_verdict!(trace, "missing_recovery_branch", missing_recovery)
    record_logical_verdict!(trace, "oracle_verdict", oracle_ok)
    record_logical_verdict!(trace, "residual_error", Dict(
        "q1" => residual[1],
        "q2" => residual[2],
        "q3" => residual[3],
    ))
    record_logical_verdict!(trace, "residual_weight", count(identity, residual))

    if !syndrome_ok
        trace.metadata["earliest_divergence_stage"] = "syndrome"
    elseif !decoder_ok
        trace.metadata["earliest_divergence_stage"] = "decoder"
    elseif !recovery_ok || missing_recovery
        trace.metadata["earliest_divergence_stage"] = "recovery"
    elseif !logical_ok
        trace.metadata["earliest_divergence_stage"] = "logical_check"
    end

    return trace
end
