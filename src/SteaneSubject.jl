struct SteaneSubject
    name::String
    mode::Symbol
end

function SteaneSubject(mode::Symbol=:clean)
    mode in (:clean, :buggy_decoder, :z_decoder_bug) ||
        error("Unsupported Steane subject mode: $(mode)")
    names = Dict(
        :clean => "steane_css_clean",
        :buggy_decoder => "steane_css_buggy_decoder_table",
        :z_decoder_bug => "steane_css_z_decoder_bug_table",
    )
    return SteaneSubject(names[mode], mode)
end

steane_x_fault_vars() = [Symbol("x", idx) for idx in 1:7]
steane_z_fault_vars() = [Symbol("z", idx) for idx in 1:7]
steane_y_fault_vars() = [Symbol("y", idx) for idx in 1:7]
steane_fault_vars() =
    vcat(steane_x_fault_vars(), steane_z_fault_vars(), steane_y_fault_vars())

const STEANE_H_COLUMNS = (
    (true, false, false),
    (false, true, false),
    (false, false, true),
    (true, true, false),
    (false, true, true),
    (true, false, true),
    (true, true, true),
)

steane_z_check_names() = ["z_h1", "z_h2", "z_h3"]
steane_x_check_names() = ["x_h1", "x_h2", "x_h3"]
steane_syndrome_names() = vcat(steane_z_check_names(), steane_x_check_names())

function steane_stabilizer_supports()
    return [
        [col for col in 1:7 if STEANE_H_COLUMNS[col][row]]
        for row in 1:3
    ]
end

function steane_code_spec()
    supports = steane_stabilizer_supports()
    return Dict{String,Any}(
        "code" => "[[7,1,3]] Steane CSS code",
        "n" => 7,
        "k" => 1,
        "distance" => 3,
        "z_checks" => [
            Dict("name" => steane_z_check_names()[idx], "support" => supports[idx])
            for idx in eachindex(supports)
        ],
        "x_checks" => [
            Dict("name" => steane_x_check_names()[idx], "support" => supports[idx])
            for idx in eachindex(supports)
        ],
        "logical_x_support" => collect(1:7),
        "logical_z_support" => collect(1:7),
    )
end

function steane_symbolic_stabilizer(fault_exprs::AbstractVector{<:BoolExpr};
    pauli="X")

    length(fault_exprs) == 7 ||
        error("Steane subject expects seven $(pauli)-frame fault expressions")
    generator_pauli = String(pauli) == "X" ? "Z" : "X"
    return symbolic_stabilizer_from_faults(
        "steane_css_code",
        7,
        String(pauli) == "X" ? steane_z_check_names() : steane_x_check_names(),
        steane_stabilizer_supports(),
        fault_exprs;
        pauli=pauli,
        generator_paulis=[generator_pauli, generator_pauli, generator_pauli],
    )
end

function xor_terms(terms::AbstractVector{<:BoolExpr})
    isempty(terms) && return bconst(false)
    expr = terms[1]
    for idx in 2:length(terms)
        expr = bxor(expr, terms[idx])
    end
    return expr
end

function steane_pauli_frame_exprs(fault_exprs::AbstractVector{<:BoolExpr})
    length(fault_exprs) == 21 ||
        error("Steane Pauli fault model expects x1..x7,z1..z7,y1..y7")
    x_frame = BoolExpr[
        bxor(fault_exprs[idx], fault_exprs[14 + idx])
        for idx in 1:7
    ]
    z_frame = BoolExpr[
        bxor(fault_exprs[7 + idx], fault_exprs[14 + idx])
        for idx in 1:7
    ]
    return x_frame, z_frame
end

function steane_syndrome_string(bits::AbstractVector{Bool})
    length(bits) == 3 || error("Steane syndrome must have three bits")
    return join(bit ? "1" : "0" for bit in bits)
end

steane_combined_syndrome_string(x_bits::AbstractVector{Bool},
    z_bits::AbstractVector{Bool}) =
    "X=" * steane_syndrome_string(x_bits) *
    ";Z=" * steane_syndrome_string(z_bits)

function steane_column_syndrome(fault_index::Integer)
    1 <= fault_index <= 7 || error("Steane fault index must be in 1:7")
    return steane_syndrome_string(collect(STEANE_H_COLUMNS[fault_index]))
end

function steane_decoder_table()
    table = Dict{String,String}("000" => "none")
    for fault_index in 1:7
        table[steane_column_syndrome(fault_index)] = "q$(fault_index)"
    end
    return table
end

function reference_steane_decoder(syndrome::AbstractString)
    table = steane_decoder_table()
    return get(table, String(syndrome), "uncorrectable")
end

function subject_x_decoder(subject::SteaneSubject, syndrome::AbstractString)
    table = steane_decoder_table()
    if subject.mode == :buggy_decoder
        table[steane_column_syndrome(1)] = "q2"
    end
    return get(table, String(syndrome), "uncorrectable")
end

function subject_z_decoder(subject::SteaneSubject, syndrome::AbstractString)
    table = steane_decoder_table()
    if subject.mode == :z_decoder_bug
        table[steane_column_syndrome(1)] = "q2"
    end
    return get(table, String(syndrome), "uncorrectable")
end

subject_decoder(subject::SteaneSubject, syndrome::AbstractString) =
    subject_x_decoder(subject, syndrome)

function steane_syndrome_exprs(frame_exprs::AbstractVector{<:BoolExpr})
    length(frame_exprs) == 7 || error("Steane syndrome frame expects seven expressions")
    exprs = BoolExpr[]
    for row in 1:3
        terms = BoolExpr[
            frame_exprs[col]
            for col in 1:7
            if STEANE_H_COLUMNS[col][row]
        ]
        push!(exprs, xor_terms(terms))
    end
    return exprs
end

function steane_syndrome_bits_dict(names::AbstractVector{String},
    bits::AbstractVector{Bool})

    return Dict{String,Any}(
        name => bit
        for (name, bit) in zip(names, bits)
    )
end

function steane_recovery_from_decoder(decoder_output::AbstractString; pauli="X")
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
    return Dict{String,Any}(
        "pauli" => String(pauli),
        "target" => output,
        "source" => "decoder",
    )
end

function steane_syndrome_equals_expr(syndrome_exprs::AbstractVector{<:BoolExpr},
    syndrome::AbstractString)

    terms = BoolExpr[]
    for (expr, bit) in zip(syndrome_exprs, syndrome)
        push!(terms, bit == '1' ? expr : bnot(expr))
    end
    return band(terms...)
end

function steane_decoder_arm_order()
    arms = ["000"]
    append!(arms, [steane_column_syndrome(fault_index) for fault_index in 1:7])
    return arms
end

function steane_axis_decoder(subject::SteaneSubject, axis::Symbol,
    syndrome::AbstractString)

    axis == :x && return subject_x_decoder(subject, syndrome)
    axis == :z && return subject_z_decoder(subject, syndrome)
    error("unknown Steane decoder axis: $(axis)")
end

function steane_axis_output_condition(subject::SteaneSubject,
    axis::Symbol,
    syndrome_exprs::AbstractVector{<:BoolExpr},
    output::AbstractString)

    terms = BoolExpr[
        steane_syndrome_equals_expr(syndrome_exprs, syndrome)
        for syndrome in steane_decoder_arm_order()
        if steane_axis_decoder(subject, axis, syndrome) == String(output)
    ]
    isempty(terms) && return bconst(false)
    return length(terms) == 1 ? terms[1] : bor(terms...)
end

function steane_decoder_recovery_semantics(subject::SteaneSubject)
    rows = Dict{String,Any}[]
    for axis in (:x, :z)
        names = axis == :x ? steane_z_check_names() : steane_x_check_names()
        pauli = axis == :x ? "X" : "Z"
        for syndrome in steane_decoder_arm_order()
            decoder_output = steane_axis_decoder(subject, axis, syndrome)
            push!(
                rows,
                decoder_recovery_semantics_row(
                    "decoder:steane_$(axis)_syndrome_$(syndrome)",
                    smt_syndrome_pattern(names, syndrome),
                    decoder_output,
                    steane_recovery_from_decoder(decoder_output; pauli=pauli),
                ),
            )
        end
    end
    return rows
end

function steane_decoder_output_conditions(subject::SteaneSubject,
    x_syndrome_exprs::AbstractVector{<:BoolExpr},
    z_syndrome_exprs::AbstractVector{<:BoolExpr})

    conditions = Tuple{String,BoolExpr}[]
    push!(
        conditions,
        (
            "none",
            band(
                steane_axis_output_condition(subject, :x, x_syndrome_exprs, "none"),
                steane_axis_output_condition(subject, :z, z_syndrome_exprs, "none"),
            ),
        ),
    )
    for idx in 1:7
        q = "q$(idx)"
        push!(
            conditions,
            (
                q,
                band(
                    steane_axis_output_condition(subject, :x, x_syndrome_exprs, q),
                    steane_axis_output_condition(subject, :z, z_syndrome_exprs, "none"),
                ),
            ),
        )
        push!(
            conditions,
            (
                "Z:" * q,
                band(
                    steane_axis_output_condition(subject, :x, x_syndrome_exprs, "none"),
                    steane_axis_output_condition(subject, :z, z_syndrome_exprs, q),
                ),
            ),
        )
        push!(
            conditions,
            (
                "Y:" * q,
                band(
                    steane_axis_output_condition(subject, :x, x_syndrome_exprs, q),
                    steane_axis_output_condition(subject, :z, z_syndrome_exprs, q),
                ),
            ),
        )
    end
    return conditions
end

function select_axis_decoder_output!(trace::ConcolicTrace,
    subject::SteaneSubject,
    axis::Symbol,
    syndrome_exprs::AbstractVector{<:BoolExpr},
    syndrome_bits::AbstractVector{Bool})

    syndrome = steane_syndrome_string(syndrome_bits)
    axis_text = axis == :x ? "x" : "z"
    for arm in steane_decoder_arm_order()
        condition = steane_syndrome_equals_expr(syndrome_exprs, arm)
        taken = syndrome == arm
        record_branch!(
            trace,
            "decoder:steane_$(axis_text)_syndrome_$(arm)",
            :decoder,
            condition,
            taken;
            description="decoder table arm for Steane $(uppercase(axis_text))-error syndrome $(arm)",
        )
        taken && return steane_axis_decoder(subject, axis, arm)
    end
    return "uncorrectable"
end

function steane_residual_class(residual::AbstractVector{Bool}, axis::Symbol)
    axis == :x && return residual_logical_class(
        residual,
        steane_stabilizer_supports(),
        collect(1:7);
        logical_name="logical_x",
    )
    axis == :z && return residual_logical_class(
        residual,
        steane_stabilizer_supports(),
        collect(1:7);
        logical_name="logical_z",
    )
    error("unknown Steane residual axis: $(axis)")
end

function run_steane_subject(subject::SteaneSubject, input::AbstractDict)
    fault_vars = steane_fault_vars()
    model = normalize_assignment(fault_vars, input)

    trace = ConcolicTrace(
        subject.name;
        code_size=7,
        distance=3,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=Dict{String,Any}(
            "subject_family" => "steane_css_code",
            "mode" => string(subject.mode),
            "code" => "[[7,1,3]] Steane CSS code",
            "fault_model" => "single Pauli-X/Y/Z data fault",
            "max_fault_weight" => 1,
            "css_orientation" =>
                "six CSS checks: Z checks decode X faults; X checks decode Z faults",
            "parity_check_columns" => [steane_column_syndrome(idx) for idx in 1:7],
            "stabilizer_checks" => steane_code_spec(),
            "logical_operators" => Dict{String,Any}(
                "logical_x_support" => ["q$(idx)" for idx in 1:7],
                "logical_z_support" => ["q$(idx)" for idx in 1:7],
            ),
            "syndrome_space_size" => 64,
            "decoder_table_total" => true,
        ),
    )

    fault_exprs = [boolvar(var) for var in fault_vars]
    x_frame_exprs, z_frame_exprs = steane_pauli_frame_exprs(fault_exprs)
    x_pre_recovery_state = steane_symbolic_stabilizer(x_frame_exprs; pauli="X")
    z_pre_recovery_state = steane_symbolic_stabilizer(z_frame_exprs; pauli="Z")
    x_syndrome_exprs = stabilizer_generator_phase_exprs(x_pre_recovery_state)
    z_syndrome_exprs = stabilizer_generator_phase_exprs(z_pre_recovery_state)
    x_syndrome_bits = [evaluate(expr, model) for expr in x_syndrome_exprs]
    z_syndrome_bits = [evaluate(expr, model) for expr in z_syndrome_exprs]
    x_syndrome = steane_syndrome_string(x_syndrome_bits)
    z_syndrome = steane_syndrome_string(z_syndrome_bits)
    combined_syndrome = steane_combined_syndrome_string(
        x_syndrome_bits,
        z_syndrome_bits,
    )

    for (name, value, expr) in zip(
        steane_z_check_names(),
        x_syndrome_bits,
        x_syndrome_exprs,
    )
        record_syndrome!(trace, name, value, expr)
    end
    for (name, value, expr) in zip(
        steane_x_check_names(),
        z_syndrome_bits,
        z_syndrome_exprs,
    )
        record_syndrome!(trace, name, value, expr)
    end

    actual_x_decoder = select_axis_decoder_output!(
        trace,
        subject,
        :x,
        x_syndrome_exprs,
        x_syndrome_bits,
    )
    actual_z_decoder = select_axis_decoder_output!(
        trace,
        subject,
        :z,
        z_syndrome_exprs,
        z_syndrome_bits,
    )
    record_syndrome_bit_branches!(
        trace,
        steane_z_check_names(),
        x_syndrome_bits,
        x_syndrome_exprs;
        id_prefix="syndrome:steane_x_frame",
    )
    record_syndrome_bit_branches!(
        trace,
        steane_x_check_names(),
        z_syndrome_bits,
        z_syndrome_exprs;
        id_prefix="syndrome:steane_z_frame",
    )

    expected_x_decoder = reference_steane_decoder(x_syndrome)
    expected_z_decoder = reference_steane_decoder(z_syndrome)
    actual_decoder = css_decoder_label(actual_x_decoder, actual_z_decoder)
    expected_decoder = css_decoder_label(expected_x_decoder, expected_z_decoder)

    record_decoder_decision!(trace, "syndrome", combined_syndrome)
    record_decoder_decision!(trace, "observed_syndrome", combined_syndrome)
    record_decoder_decision!(trace, "expected_syndrome", combined_syndrome)
    record_decoder_decision!(trace, "x_syndrome", x_syndrome)
    record_decoder_decision!(trace, "z_syndrome", z_syndrome)
    record_decoder_decision!(trace, "x_actual", actual_x_decoder)
    record_decoder_decision!(trace, "z_actual", actual_z_decoder)
    record_decoder_decision!(trace, "x_expected", expected_x_decoder)
    record_decoder_decision!(trace, "z_expected", expected_z_decoder)
    record_decoder_decision!(trace, "actual", actual_decoder)
    record_decoder_decision!(trace, "expected", expected_decoder)

    actual_recovery = css_recovery_from_decoder_outputs(
        actual_x_decoder,
        actual_z_decoder;
        source="steane_css_decoder",
    )
    expected_recovery = css_recovery_from_decoder_outputs(
        expected_x_decoder,
        expected_z_decoder;
        source="reference_steane_css_decoder",
    )
    record_recovery_output_branches!(
        trace,
        actual_decoder,
        steane_decoder_output_conditions(subject, x_syndrome_exprs, z_syndrome_exprs),
    )
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    set_decoder_recovery_semantics!(
        trace,
        steane_decoder_recovery_semantics(subject),
    )
    trace.metadata["syndrome_diagnostics"] = Dict{String,Any}(
        "observed" => combined_syndrome,
        "expected" => combined_syndrome,
        "x_observed" => x_syndrome,
        "z_observed" => z_syndrome,
        "x_expected" => x_syndrome,
        "z_expected" => z_syndrome,
        "observed_bits" => merge(
            steane_syndrome_bits_dict(steane_z_check_names(), x_syndrome_bits),
            steane_syndrome_bits_dict(steane_x_check_names(), z_syndrome_bits),
        ),
        "expected_bits" => merge(
            steane_syndrome_bits_dict(steane_z_check_names(), x_syndrome_bits),
            steane_syndrome_bits_dict(steane_x_check_names(), z_syndrome_bits),
        ),
        "syndrome_mismatch" => false,
    )
    trace.metadata["decoder_diagnostics"] = Dict{String,Any}(
        "table_family" => "Steane CSS Hamming syndrome table over X/Z Pauli frames",
        "x_decoder_buggy_entry" =>
            subject.mode == :buggy_decoder ? "100 -> q2 instead of q1" : "none",
        "z_decoder_buggy_entry" =>
            subject.mode == :z_decoder_bug ? "100 -> q2 instead of q1" : "none",
        "actual_x_decoder" => actual_x_decoder,
        "expected_x_decoder" => expected_x_decoder,
        "actual_z_decoder" => actual_z_decoder,
        "expected_z_decoder" => expected_z_decoder,
    )

    x_post_recovery_state = copy_symbolic_stabilizer_state(x_pre_recovery_state)
    z_post_recovery_state = copy_symbolic_stabilizer_state(z_pre_recovery_state)
    apply_css_recovery!(x_post_recovery_state, z_post_recovery_state, actual_recovery)
    x_residual = symbolic_residual_vector(x_post_recovery_state, model)
    z_residual = symbolic_residual_vector(z_post_recovery_state, model)
    residual_error = css_residual_error_dict(
        x_post_recovery_state,
        z_post_recovery_state,
        model,
    )
    x_residual_class = steane_residual_class(x_residual, :x)
    z_residual_class = steane_residual_class(z_residual, :z)
    residual_weight = css_residual_weight(
        x_post_recovery_state,
        z_post_recovery_state,
        model,
    )
    record_css_symbolic_stabilizer_summary!(
        trace,
        x_pre_recovery_state,
        x_post_recovery_state,
        z_pre_recovery_state,
        z_post_recovery_state,
        model,
    )

    decoder_ok = actual_x_decoder == expected_x_decoder &&
        actual_z_decoder == expected_z_decoder
    recovery_ok = css_recovery_signature(actual_recovery) ==
        css_recovery_signature(expected_recovery)
    missing_recovery = actual_recovery["pauli"] == "missing"
    logical_ok = css_logical_ok(x_residual_class, z_residual_class)
    oracle_ok = decoder_ok && recovery_ok && logical_ok && !missing_recovery

    trace.metadata["residual_logical_class"] = Dict{String,Any}(
        "x_frame" => x_residual_class,
        "z_frame" => z_residual_class,
        "logical_ok" => logical_ok,
    )
    record_logical_verdict!(trace, "syndrome_mismatch", false)
    record_logical_verdict!(trace, "decoder_mismatch", !decoder_ok)
    record_logical_verdict!(trace, "recovery_mismatch", !recovery_ok || missing_recovery)
    record_logical_verdict!(trace, "logical_mismatch", !logical_ok)
    record_logical_verdict!(trace, "missing_recovery_branch", missing_recovery)
    record_logical_verdict!(trace, "oracle_verdict", oracle_ok)
    record_logical_verdict!(trace, "residual_error", residual_error)
    record_logical_verdict!(trace, "residual_weight", residual_weight)

    if !decoder_ok
        trace.metadata["earliest_divergence_stage"] = "decoder"
    elseif !recovery_ok || missing_recovery
        trace.metadata["earliest_divergence_stage"] = "recovery"
    elseif !logical_ok
        trace.metadata["earliest_divergence_stage"] = "logical_check"
    end

    return trace
end
