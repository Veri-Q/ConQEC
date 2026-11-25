struct BitFlipSubject
    name::String
    mode::Symbol
end

function BitFlipSubject(mode::Symbol)
    mode in (
        :clean,
        :buggy_decoder,
        :wrong_recovery_target,
        :missing_recovery_branch,
        :syndrome_wiring_bug,
        :measurement_misuse,
        :priority_decoder_bug,
    ) ||
        error("Unsupported bit-flip subject mode: $(mode)")
    names = Dict(
        :clean => "bitflip_clean",
        :buggy_decoder => "bitflip_buggy_decoder_table",
        :wrong_recovery_target => "bitflip_wrong_recovery_target",
        :missing_recovery_branch => "bitflip_missing_recovery_branch",
        :syndrome_wiring_bug => "bitflip_syndrome_wiring_bug",
        :measurement_misuse => "bitflip_measurement_misuse",
        :priority_decoder_bug => "bitflip_priority_decoder_bug",
    )
    return BitFlipSubject(names[mode], mode)
end

bitflip_fault_vars() = [:x1, :x2, :x3]

bitflip_priority_fault_vars() = [:x4, :x5, :x1, :x2, :x3]

bitflip_fault_vars(subject::BitFlipSubject) =
    subject.mode == :priority_decoder_bug ? bitflip_priority_fault_vars() :
        bitflip_fault_vars()

function reference_bitflip_decoder(syndrome::AbstractString)
    table = Dict(
        "00" => "none",
        "10" => "q1",
        "11" => "q2",
        "01" => "q3",
    )
    return table[String(syndrome)]
end

function subject_decoder(subject::BitFlipSubject, syndrome::AbstractString)
    table = Dict(
        "00" => "none",
        "10" => "q1",
        "11" => "q2",
        "01" => "q3",
    )
    if subject.mode == :buggy_decoder || subject.mode == :priority_decoder_bug
        table["10"] = "q2"
    end
    return get(table, String(syndrome), "missing")
end

function syndrome_string(s12::Bool, s23::Bool)
    return (s12 ? "1" : "0") * (s23 ? "1" : "0")
end

function bitflip_syndrome_condition(s12_expr::BoolExpr, s23_expr::BoolExpr,
    syndrome::AbstractString)

    syndrome = String(syndrome)
    length(syndrome) == 2 || error("bit-flip syndrome must have two bits")
    return band(
        syndrome[1] == '1' ? s12_expr : bnot(s12_expr),
        syndrome[2] == '1' ? s23_expr : bnot(s23_expr),
    )
end

function syndrome_bits_dict(s12::Bool, s23::Bool)
    return Dict{String,Any}(
        "s12" => s12,
        "s23" => s23,
    )
end

bitflip_syndrome_names() = ["s12", "s23"]

bitflip_stabilizer_supports() = [[1, 2], [2, 3]]

function bitflip_symbolic_stabilizer(fault_exprs::AbstractVector{<:BoolExpr})
    return symbolic_stabilizer_from_faults(
        "three_qubit_bitflip",
        3,
        bitflip_syndrome_names(),
        bitflip_stabilizer_supports(),
        fault_exprs;
        pauli="X",
        generator_paulis=["Z", "Z"],
    )
end

function bitflip_decoder_recovery_semantics(subject::BitFlipSubject)
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
                smt_syndrome_pattern(bitflip_syndrome_names(), syndrome),
                decoder_output,
                recovery_from_decoder(subject, decoder_output),
            ),
        )
    end
    return rows
end

function bitflip_decoder_output_conditions(subject::BitFlipSubject,
    s12_expr::BoolExpr,
    s23_expr::BoolExpr)

    outputs = ["none", "q1", "q2", "q3", "missing"]
    conditions = Tuple{String,BoolExpr}[]
    for output in outputs
        terms = BoolExpr[
            bitflip_syndrome_condition(s12_expr, s23_expr, syndrome)
            for syndrome in ("00", "10", "11", "01")
            if subject_decoder(subject, syndrome) == output
        ]
        isempty(terms) && continue
        push!(conditions, (output, length(terms) == 1 ? terms[1] : bor(terms...)))
    end
    return conditions
end

function bitflip_syndrome_exprs(subject::BitFlipSubject,
    x1_expr::BoolExpr, x2_expr::BoolExpr, x3_expr::BoolExpr)

    expected_s12_expr = bxor(x1_expr, x2_expr)
    expected_s23_expr = bxor(x2_expr, x3_expr)
    observed_s12_expr = subject.mode == :syndrome_wiring_bug ?
        bxor(x1_expr, x3_expr) :
        expected_s12_expr
    observed_s23_expr = subject.mode == :measurement_misuse ?
        expected_s12_expr :
        expected_s23_expr

    return (
        observed_s12_expr=observed_s12_expr,
        observed_s23_expr=observed_s23_expr,
        expected_s12_expr=expected_s12_expr,
        expected_s23_expr=expected_s23_expr,
    )
end

function recovery_from_decoder(subject::BitFlipSubject, decoder_output::AbstractString)
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
    if subject.mode == :missing_recovery_branch && output == "q1"
        return Dict{String,Any}(
            "pauli" => "missing",
            "target" => "missing",
            "source" => "decoder",
        )
    end
    return Dict{String,Any}(
        "pauli" => "X",
        "target" => target,
        "source" => "decoder",
    )
end

function apply_recovery(faults::Vector{Bool}, recovery::Dict{String,Any})
    residual = copy(faults)
    target = String(recovery["target"])
    if startswith(target, "q")
        idx = parse(Int, target[2:end])
        residual[idx] = !residual[idx]
    end
    return residual
end

function select_decoder_output!(trace::ConcolicTrace, subject::BitFlipSubject,
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

function record_priority_decoy_branches!(trace::ConcolicTrace,
    subject::BitFlipSubject,
    model::AbstractDict,
    x4_expr::BoolExpr,
    x5_expr::BoolExpr)

    subject.mode == :priority_decoder_bug || return trace
    record_branch!(
        trace,
        "fault:priority_decoy_x4",
        :fault,
        x4_expr,
        model_bool(model, :x4);
        description="priority-ablation decoy branch for neutral q4 guard fault",
    )
    record_branch!(
        trace,
        "fault:priority_decoy_x5",
        :fault,
        x5_expr,
        model_bool(model, :x5);
        description="priority-ablation decoy branch for neutral q5 guard fault",
    )
    return trace
end

function record_syndrome_wiring_check!(trace::ConcolicTrace, subject::BitFlipSubject,
    observed_s12_expr::BoolExpr, expected_s12_expr::BoolExpr,
    observed_s12::Bool, expected_s12::Bool)

    subject.mode == :syndrome_wiring_bug || return trace
    record_branch!(
        trace,
        "syndrome:s12_wiring_matches_reference",
        :syndrome,
        beq(observed_s12_expr, expected_s12_expr),
        observed_s12 == expected_s12;
        description="observed s12 wiring agrees with reference parity",
        path_constraint=false,
    )
    return trace
end

function record_measurement_misuse_check!(trace::ConcolicTrace, subject::BitFlipSubject,
    observed_s23_expr::BoolExpr, expected_s23_expr::BoolExpr,
    observed_s23::Bool, expected_s23::Bool)

    subject.mode == :measurement_misuse || return trace
    record_branch!(
        trace,
        "syndrome:s23_measurement_matches_reference",
        :measurement_result,
        beq(observed_s23_expr, expected_s23_expr),
        observed_s23 == expected_s23;
        description="observed s23 measurement agrees with reference parity",
        path_constraint=false,
    )
    return trace
end

function run_bitflip_subject(subject::BitFlipSubject, input::AbstractDict)
    fault_vars = bitflip_fault_vars(subject)
    model = normalize_assignment(fault_vars, input)

    trace = ConcolicTrace(
        subject.name;
        code_size=3,
        distance=3,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=Dict{String,Any}(
            "subject_family" => "three_qubit_bitflip",
            "mode" => string(subject.mode),
            "fault_model" => subject.mode == :priority_decoder_bug ?
                "single Pauli-X data fault plus neutral priority decoy guards" :
                "single Pauli-X data fault",
            "max_fault_weight" => 1,
        ),
    )

    x4_expr = boolvar(:x4)
    x5_expr = boolvar(:x5)
    x1_expr = boolvar(:x1)
    x2_expr = boolvar(:x2)
    x3_expr = boolvar(:x3)
    pre_recovery_state = bitflip_symbolic_stabilizer(BoolExpr[x1_expr, x2_expr, x3_expr])
    expected_syndrome_exprs = stabilizer_generator_phase_exprs(pre_recovery_state)
    syndrome_exprs = (
        observed_s12_expr=subject.mode == :syndrome_wiring_bug ?
            bxor(x1_expr, x3_expr) :
            expected_syndrome_exprs[1],
        observed_s23_expr=subject.mode == :measurement_misuse ?
            expected_syndrome_exprs[1] :
            expected_syndrome_exprs[2],
        expected_s12_expr=expected_syndrome_exprs[1],
        expected_s23_expr=expected_syndrome_exprs[2],
    )

    s12 = evaluate(syndrome_exprs.observed_s12_expr, model)
    s23 = evaluate(syndrome_exprs.observed_s23_expr, model)
    expected_s12 = evaluate(syndrome_exprs.expected_s12_expr, model)
    expected_s23 = evaluate(syndrome_exprs.expected_s23_expr, model)
    syndrome = syndrome_string(s12, s23)
    expected_syndrome = syndrome_string(expected_s12, expected_s23)

    record_syndrome!(trace, "s12", s12, syndrome_exprs.observed_s12_expr)
    record_syndrome!(trace, "s23", s23, syndrome_exprs.observed_s23_expr)
    record_priority_decoy_branches!(
        trace,
        subject,
        model,
        x4_expr,
        x5_expr,
    )

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
    record_syndrome_wiring_check!(
        trace,
        subject,
        syndrome_exprs.observed_s12_expr,
        syndrome_exprs.expected_s12_expr,
        s12,
        expected_s12,
    )
    record_measurement_misuse_check!(
        trace,
        subject,
        syndrome_exprs.observed_s23_expr,
        syndrome_exprs.expected_s23_expr,
        s23,
        expected_s23,
    )

    expected_decoder = reference_bitflip_decoder(expected_syndrome)

    record_decoder_decision!(trace, "syndrome", syndrome)
    record_decoder_decision!(trace, "observed_syndrome", syndrome)
    record_decoder_decision!(trace, "expected_syndrome", expected_syndrome)
    record_decoder_decision!(trace, "actual", actual_decoder)
    record_decoder_decision!(trace, "expected", expected_decoder)

    actual_recovery = recovery_from_decoder(subject, actual_decoder)
    expected_recovery = recovery_from_decoder(BitFlipSubject(:clean), expected_decoder)
    record_recovery_output_branches!(
        trace,
        actual_decoder,
        bitflip_decoder_output_conditions(
            subject,
            syndrome_exprs.observed_s12_expr,
            syndrome_exprs.observed_s23_expr,
        ),
    )
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    set_decoder_recovery_semantics!(
        trace,
        bitflip_decoder_recovery_semantics(subject),
    )
    trace.metadata["syndrome_diagnostics"] = Dict{String,Any}(
        "observed" => syndrome,
        "expected" => expected_syndrome,
        "observed_bits" => syndrome_bits_dict(s12, s23),
        "expected_bits" => syndrome_bits_dict(expected_s12, expected_s23),
        "syndrome_mismatch" => syndrome != expected_syndrome,
    )
    if subject.mode == :syndrome_wiring_bug
        trace.metadata["syndrome_wiring"] = Dict{String,Any}(
            "observed_s12_expr" => expr_to_string(syndrome_exprs.observed_s12_expr),
            "expected_s12_expr" => expr_to_string(syndrome_exprs.expected_s12_expr),
        )
    end
    if subject.mode == :measurement_misuse
        trace.metadata["measurement_misuse"] = Dict{String,Any}(
            "observed_s23_expr" => expr_to_string(syndrome_exprs.observed_s23_expr),
            "expected_s23_expr" => expr_to_string(syndrome_exprs.expected_s23_expr),
            "misused_observable" => "s23 reads s12 parity",
        )
    end

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
    record_logical_verdict!(
        trace,
        "measurement_misuse",
        subject.mode == :measurement_misuse && !syndrome_ok,
    )
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

    if subject.mode == :measurement_misuse && !syndrome_ok
        trace.metadata["earliest_divergence_stage"] = "measurement_result"
    elseif !syndrome_ok
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
