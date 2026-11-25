struct SurfaceSubject
    name::String
    mode::Symbol
end

function SurfaceSubject(mode::Symbol=:clean)
    mode in (:clean, :buggy_decoder, :z_decoder_bug) ||
        error("Unsupported surface-code subject mode: $(mode)")
    names = Dict(
        :clean => "surface_d3_x_memory_clean",
        :buggy_decoder => "surface_d3_x_memory_buggy_decoder_table",
        :z_decoder_bug => "surface_d3_z_memory_buggy_decoder_table",
    )
    return SurfaceSubject(names[mode], mode)
end

surface_x_fault_vars() = [Symbol("x", idx) for idx in 1:9]
surface_z_fault_vars() = [Symbol("z", idx) for idx in 1:9]
surface_y_fault_vars() = [Symbol("y", idx) for idx in 1:9]
surface_fault_vars() =
    vcat(surface_x_fault_vars(), surface_z_fault_vars(), surface_y_fault_vars())

const SURFACE_PLAQUETTES = (
    (1, 2, 4, 5),
    (2, 3, 5, 6),
    (4, 5, 7, 8),
    (5, 6, 8, 9),
)

surface_z_syndrome_names() = ["z_p11", "z_p12", "z_p21", "z_p22"]
surface_x_syndrome_names() = ["x_p11", "x_p12", "x_p21", "x_p22"]
surface_syndrome_names() = vcat(surface_z_syndrome_names(), surface_x_syndrome_names())

surface_stabilizer_supports() = [collect(plaquette) for plaquette in SURFACE_PLAQUETTES]

function surface_layout_metadata()
    return Dict{String,Any}(
        "q1" => "(1,1)",
        "q2" => "(1,2)",
        "q3" => "(1,3)",
        "q4" => "(2,1)",
        "q5" => "(2,2)",
        "q6" => "(2,3)",
        "q7" => "(3,1)",
        "q8" => "(3,2)",
        "q9" => "(3,3)",
    )
end

function surface_code_spec()
    supports = surface_stabilizer_supports()
    return Dict{String,Any}(
        "code" => "distance-3 surface-code CSS patch kernel",
        "n" => 9,
        "distance" => 3,
        "boundary_model" => "3x3 data-qubit patch with plaquette parity checks",
        "data_qubit_layout" => surface_layout_metadata(),
        "z_checks" => [
            Dict("name" => surface_z_syndrome_names()[idx], "support" => supports[idx])
            for idx in eachindex(supports)
        ],
        "x_checks" => [
            Dict("name" => surface_x_syndrome_names()[idx], "support" => supports[idx])
            for idx in eachindex(supports)
        ],
        "logical_x_support" => [1, 2, 3],
        "logical_z_support" => [1, 4, 7],
    )
end

function surface_symbolic_stabilizer(fault_exprs::AbstractVector{<:BoolExpr};
    pauli="X")

    length(fault_exprs) == 9 ||
        error("surface-code kernel expects nine $(pauli)-frame expressions")
    generator_pauli = String(pauli) == "X" ? "Z" : "X"
    return symbolic_stabilizer_from_faults(
        "surface_d3_css_patch",
        9,
        String(pauli) == "X" ? surface_z_syndrome_names() : surface_x_syndrome_names(),
        surface_stabilizer_supports(),
        fault_exprs;
        pauli=pauli,
        generator_paulis=[generator_pauli for _ in SURFACE_PLAQUETTES],
    )
end

function surface_pauli_frame_exprs(fault_exprs::AbstractVector{<:BoolExpr})
    length(fault_exprs) == 27 ||
        error("surface-code Pauli fault model expects x1..x9,z1..z9,y1..y9")
    x_frame = BoolExpr[
        bxor(fault_exprs[idx], fault_exprs[18 + idx])
        for idx in 1:9
    ]
    z_frame = BoolExpr[
        bxor(fault_exprs[9 + idx], fault_exprs[18 + idx])
        for idx in 1:9
    ]
    return x_frame, z_frame
end

function surface_syndrome_string(bits::AbstractVector{Bool})
    length(bits) == 4 || error("surface-code kernel syndrome must have four bits")
    return join(bit ? "1" : "0" for bit in bits)
end

surface_combined_syndrome_string(x_bits::AbstractVector{Bool},
    z_bits::AbstractVector{Bool}) =
    "X=" * surface_syndrome_string(x_bits) *
    ";Z=" * surface_syndrome_string(z_bits)

function surface_syndrome_from_single_fault(fault_index::Integer)
    1 <= fault_index <= 9 || error("surface-code fault index must be in 1:9")
    bits = [
        fault_index in plaquette
        for plaquette in SURFACE_PLAQUETTES
    ]
    return surface_syndrome_string(bits)
end

function surface_all_syndromes()
    syndromes = String[]
    for mask in 0:15
        push!(
            syndromes,
            join(((mask >> (idx - 1)) & 1) == 1 ? "1" : "0" for idx in 1:4),
        )
    end
    return syndromes
end

function surface_decoder_table()
    table = Dict{String,String}(
        syndrome => "uncorrectable"
        for syndrome in surface_all_syndromes()
    )
    table["0000"] = "none"
    for fault_index in 1:9
        table[surface_syndrome_from_single_fault(fault_index)] = "q$(fault_index)"
    end
    return table
end

function reference_surface_decoder(syndrome::AbstractString)
    table = surface_decoder_table()
    return get(table, String(syndrome), "uncorrectable")
end

function subject_x_decoder(subject::SurfaceSubject, syndrome::AbstractString)
    table = surface_decoder_table()
    if subject.mode == :buggy_decoder
        table[surface_syndrome_from_single_fault(1)] = "q2"
    end
    return get(table, String(syndrome), "uncorrectable")
end

function subject_z_decoder(subject::SurfaceSubject, syndrome::AbstractString)
    table = surface_decoder_table()
    if subject.mode == :z_decoder_bug
        table[surface_syndrome_from_single_fault(1)] = "q2"
    end
    return get(table, String(syndrome), "uncorrectable")
end

subject_decoder(subject::SurfaceSubject, syndrome::AbstractString) =
    subject_x_decoder(subject, syndrome)

function surface_syndrome_exprs(frame_exprs::AbstractVector{<:BoolExpr})
    length(frame_exprs) == 9 || error("surface-code kernel expects nine frame expressions")
    return [
        xor_terms(BoolExpr[frame_exprs[idx] for idx in plaquette])
        for plaquette in SURFACE_PLAQUETTES
    ]
end

function surface_syndrome_bits_dict(names::AbstractVector{String},
    bits::AbstractVector{Bool})

    return Dict{String,Any}(
        name => bit
        for (name, bit) in zip(names, bits)
    )
end

function surface_recovery_from_decoder(decoder_output::AbstractString; pauli="X")
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

function surface_syndrome_equals_expr(syndrome_exprs::AbstractVector{<:BoolExpr},
    syndrome::AbstractString)

    terms = BoolExpr[]
    for (expr, bit) in zip(syndrome_exprs, syndrome)
        push!(terms, bit == '1' ? expr : bnot(expr))
    end
    return band(terms...)
end

function surface_decoder_arm_order()
    first_arms = ["0000"]
    append!(first_arms, [surface_syndrome_from_single_fault(fault_index) for fault_index in 1:9])
    seen = Set(first_arms)
    for syndrome in surface_all_syndromes()
        syndrome in seen && continue
        push!(first_arms, syndrome)
    end
    return first_arms
end

function surface_axis_decoder(subject::SurfaceSubject, axis::Symbol,
    syndrome::AbstractString)

    axis == :x && return subject_x_decoder(subject, syndrome)
    axis == :z && return subject_z_decoder(subject, syndrome)
    error("unknown surface decoder axis: $(axis)")
end

function surface_axis_output_condition(subject::SurfaceSubject,
    axis::Symbol,
    syndrome_exprs::AbstractVector{<:BoolExpr},
    output::AbstractString)

    terms = BoolExpr[
        surface_syndrome_equals_expr(syndrome_exprs, syndrome)
        for syndrome in surface_decoder_arm_order()
        if surface_axis_decoder(subject, axis, syndrome) == String(output)
    ]
    isempty(terms) && return bconst(false)
    return length(terms) == 1 ? terms[1] : bor(terms...)
end

function surface_decoder_recovery_semantics(subject::SurfaceSubject)
    rows = Dict{String,Any}[]
    for axis in (:x, :z)
        names = axis == :x ? surface_z_syndrome_names() : surface_x_syndrome_names()
        pauli = axis == :x ? "X" : "Z"
        for syndrome in surface_decoder_arm_order()
            decoder_output = surface_axis_decoder(subject, axis, syndrome)
            push!(
                rows,
                decoder_recovery_semantics_row(
                    "decoder:surface_$(axis)_syndrome_$(syndrome)",
                    smt_syndrome_pattern(names, syndrome),
                    decoder_output,
                    surface_recovery_from_decoder(decoder_output; pauli=pauli),
                ),
            )
        end
    end
    return rows
end

function surface_decoder_output_conditions(subject::SurfaceSubject,
    x_syndrome_exprs::AbstractVector{<:BoolExpr},
    z_syndrome_exprs::AbstractVector{<:BoolExpr})

    conditions = Tuple{String,BoolExpr}[]
    push!(
        conditions,
        (
            "none",
            band(
                surface_axis_output_condition(subject, :x, x_syndrome_exprs, "none"),
                surface_axis_output_condition(subject, :z, z_syndrome_exprs, "none"),
            ),
        ),
    )
    for idx in 1:9
        q = "q$(idx)"
        push!(
            conditions,
            (
                q,
                band(
                    surface_axis_output_condition(subject, :x, x_syndrome_exprs, q),
                    surface_axis_output_condition(subject, :z, z_syndrome_exprs, "none"),
                ),
            ),
        )
        push!(
            conditions,
            (
                "Z:" * q,
                band(
                    surface_axis_output_condition(subject, :x, x_syndrome_exprs, "none"),
                    surface_axis_output_condition(subject, :z, z_syndrome_exprs, q),
                ),
            ),
        )
        push!(
            conditions,
            (
                "Y:" * q,
                band(
                    surface_axis_output_condition(subject, :x, x_syndrome_exprs, q),
                    surface_axis_output_condition(subject, :z, z_syndrome_exprs, q),
                ),
            ),
        )
    end
    return conditions
end

function select_axis_decoder_output!(trace::ConcolicTrace,
    subject::SurfaceSubject,
    axis::Symbol,
    syndrome_exprs::AbstractVector{<:BoolExpr},
    syndrome_bits::AbstractVector{Bool})

    syndrome = surface_syndrome_string(syndrome_bits)
    axis_text = axis == :x ? "x" : "z"
    for arm in surface_decoder_arm_order()
        condition = surface_syndrome_equals_expr(syndrome_exprs, arm)
        taken = syndrome == arm
        record_branch!(
            trace,
            "decoder:surface_$(axis_text)_syndrome_$(arm)",
            :decoder,
            condition,
            taken;
            description="decoder table arm for surface-code $(uppercase(axis_text))-error syndrome $(arm)",
        )
        taken && return surface_axis_decoder(subject, axis, arm)
    end
    return "uncorrectable"
end

function surface_residual_class(residual::AbstractVector{Bool}, axis::Symbol)
    axis == :x && return residual_logical_class(
        residual,
        surface_stabilizer_supports(),
        [1, 2, 3];
        logical_name="logical_x",
    )
    axis == :z && return residual_logical_class(
        residual,
        surface_stabilizer_supports(),
        [1, 4, 7];
        logical_name="logical_z",
    )
    error("unknown surface residual axis: $(axis)")
end

function run_surface_subject(subject::SurfaceSubject, input::AbstractDict)
    fault_vars = surface_fault_vars()
    model = normalize_assignment(fault_vars, input)

    trace = ConcolicTrace(
        subject.name;
        code_size=9,
        distance=3,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=Dict{String,Any}(
            "subject_family" => "surface_code_kernel",
            "mode" => string(subject.mode),
            "code" => "distance-3 surface-code CSS patch kernel",
            "fault_model" => "single Pauli-X/Y/Z data fault",
            "max_fault_weight" => 1,
            "plaquette_syndromes" => surface_syndrome_names(),
            "data_qubit_layout" => surface_layout_metadata(),
            "single_fault_syndromes" =>
                [surface_syndrome_from_single_fault(idx) for idx in 1:9],
            "surface_stabilizers" => surface_code_spec(),
            "logical_operators" => Dict{String,Any}(
                "logical_x_support" => ["q1", "q2", "q3"],
                "logical_z_support" => ["q1", "q4", "q7"],
            ),
            "syndrome_space_size" => 256,
            "axis_syndrome_space_size" => 16,
            "decoder_table_total" => true,
            "decoder_boundary" =>
                "single-fault table plus explicit uncorrectable arms for all other 4-bit axis syndromes",
        ),
    )

    fault_exprs = [boolvar(var) for var in fault_vars]
    x_frame_exprs, z_frame_exprs = surface_pauli_frame_exprs(fault_exprs)
    x_pre_recovery_state = surface_symbolic_stabilizer(x_frame_exprs; pauli="X")
    z_pre_recovery_state = surface_symbolic_stabilizer(z_frame_exprs; pauli="Z")
    x_syndrome_exprs = stabilizer_generator_phase_exprs(x_pre_recovery_state)
    z_syndrome_exprs = stabilizer_generator_phase_exprs(z_pre_recovery_state)
    x_syndrome_bits = [evaluate(expr, model) for expr in x_syndrome_exprs]
    z_syndrome_bits = [evaluate(expr, model) for expr in z_syndrome_exprs]
    x_syndrome = surface_syndrome_string(x_syndrome_bits)
    z_syndrome = surface_syndrome_string(z_syndrome_bits)
    combined_syndrome = surface_combined_syndrome_string(
        x_syndrome_bits,
        z_syndrome_bits,
    )

    for (name, value, expr) in zip(
        surface_z_syndrome_names(),
        x_syndrome_bits,
        x_syndrome_exprs,
    )
        record_syndrome!(trace, name, value, expr)
    end
    for (name, value, expr) in zip(
        surface_x_syndrome_names(),
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
        surface_z_syndrome_names(),
        x_syndrome_bits,
        x_syndrome_exprs;
        id_prefix="syndrome:surface_x_frame",
    )
    record_syndrome_bit_branches!(
        trace,
        surface_x_syndrome_names(),
        z_syndrome_bits,
        z_syndrome_exprs;
        id_prefix="syndrome:surface_z_frame",
    )

    expected_x_decoder = reference_surface_decoder(x_syndrome)
    expected_z_decoder = reference_surface_decoder(z_syndrome)
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
        source="surface_css_decoder",
    )
    expected_recovery = css_recovery_from_decoder_outputs(
        expected_x_decoder,
        expected_z_decoder;
        source="reference_surface_css_decoder",
    )
    record_recovery_output_branches!(
        trace,
        actual_decoder,
        surface_decoder_output_conditions(subject, x_syndrome_exprs, z_syndrome_exprs),
    )
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    set_decoder_recovery_semantics!(
        trace,
        surface_decoder_recovery_semantics(subject),
    )
    trace.metadata["syndrome_diagnostics"] = Dict{String,Any}(
        "observed" => combined_syndrome,
        "expected" => combined_syndrome,
        "x_observed" => x_syndrome,
        "z_observed" => z_syndrome,
        "x_expected" => x_syndrome,
        "z_expected" => z_syndrome,
        "observed_bits" => merge(
            surface_syndrome_bits_dict(surface_z_syndrome_names(), x_syndrome_bits),
            surface_syndrome_bits_dict(surface_x_syndrome_names(), z_syndrome_bits),
        ),
        "expected_bits" => merge(
            surface_syndrome_bits_dict(surface_z_syndrome_names(), x_syndrome_bits),
            surface_syndrome_bits_dict(surface_x_syndrome_names(), z_syndrome_bits),
        ),
        "syndrome_mismatch" => false,
    )
    trace.metadata["decoder_diagnostics"] = Dict{String,Any}(
        "table_family" =>
            "distance-3 surface-code CSS single-fault table with total 4-bit arms",
        "x_decoder_buggy_entry" =>
            subject.mode == :buggy_decoder ? "1000 -> q2 instead of q1" : "none",
        "z_decoder_buggy_entry" =>
            subject.mode == :z_decoder_bug ? "1000 -> q2 instead of q1" : "none",
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
    x_residual_class = surface_residual_class(x_residual, :x)
    z_residual_class = surface_residual_class(z_residual, :z)
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

    input_weight = fault_weight(model, fault_vars)
    within_capacity = input_weight <= 1
    decoder_ok = actual_x_decoder == expected_x_decoder &&
        actual_z_decoder == expected_z_decoder
    recovery_ok = css_recovery_signature(actual_recovery) ==
        css_recovery_signature(expected_recovery)
    missing_recovery = actual_recovery["pauli"] == "missing" && within_capacity
    logical_ok = within_capacity ? css_logical_ok(x_residual_class, z_residual_class) : true
    oracle_ok = decoder_ok && recovery_ok && logical_ok && !missing_recovery

    trace.metadata["residual_logical_class"] = Dict{String,Any}(
        "x_frame" => x_residual_class,
        "z_frame" => z_residual_class,
        "logical_ok" => logical_ok,
    )
    trace.metadata["capacity_diagnostics"] = Dict{String,Any}(
        "input_fault_weight" => input_weight,
        "within_correction_capacity" => within_capacity,
        "out_of_capacity_inputs_are_not_implementation_bugs" => true,
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
