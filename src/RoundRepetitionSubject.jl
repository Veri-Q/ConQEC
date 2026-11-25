struct RoundRepetitionSubject
    name::String
    distance::Int
    rounds::Int
    mode::Symbol
end

function RoundRepetitionSubject(distance::Int, rounds::Int, mode::Symbol=:clean)
    distance >= 3 || error("Round repetition-code distance must be at least 3")
    isodd(distance) || error("Round repetition-code distance must be odd")
    rounds >= 1 || error("Round repetition-code rounds must be at least 1")
    mode in (:clean, :history_drop_bug, :inconsistent_control_bug) ||
        error("Unsupported round repetition-code subject mode: $(mode)")

    names = Dict(
        :clean => "round_repetition_d$(distance)_r$(rounds)_clean",
        :history_drop_bug => "round_repetition_d$(distance)_r$(rounds)_history_drop_bug",
        :inconsistent_control_bug =>
            "round_repetition_d$(distance)_r$(rounds)_inconsistent_control_bug",
    )
    return RoundRepetitionSubject(names[mode], distance, rounds, mode)
end

round_repetition_fault_var(round::Int, qubit::Int) = Symbol("x_r$(round)_q$(qubit)")

function round_repetition_fault_vars(distance::Int, rounds::Int)
    return [
        round_repetition_fault_var(round, qubit)
        for round in 1:rounds
        for qubit in 1:distance
    ]
end

round_repetition_fault_vars(subject::RoundRepetitionSubject) =
    round_repetition_fault_vars(subject.distance, subject.rounds)

function round_repetition_fault_metadata(distance::Int, rounds::Int)
    return [
        Dict{String,Any}(
            "variable" => string(round_repetition_fault_var(round, qubit)),
            "round" => round,
            "qubit" => qubit,
            "site" => "data",
            "pauli" => "X",
            "label" => "X@r$(round):q$(qubit)",
        )
        for round in 1:rounds
        for qubit in 1:distance
    ]
end

function round_repetition_syndrome_names(distance::Int, rounds::Int)
    return [
        "r$(round)_s$(idx)$(idx + 1)"
        for round in 1:rounds
        for idx in 1:(distance - 1)
    ]
end

round_history_key(round_strings::AbstractVector{<:AbstractString}) =
    join(round_strings, "|")

function round_zero_history(distance::Int, rounds::Int)
    return [repeat("0", distance - 1) for _ in 1:rounds]
end

function round_single_fault_history(distance::Int, rounds::Int,
    fault_round::Int, fault_qubit::Int)

    local_syndrome = syndrome_from_single_fault(distance, fault_qubit)
    zero_syndrome = repeat("0", distance - 1)
    return [
        round < fault_round ? zero_syndrome : local_syndrome
        for round in 1:rounds
    ]
end

function round_repetition_single_fault_decoder_table(distance::Int, rounds::Int)
    table = Dict{String,String}(
        round_history_key(round_zero_history(distance, rounds)) => "none",
    )
    for round in 1:rounds
        for qubit in 1:distance
            history = round_single_fault_history(distance, rounds, round, qubit)
            table[round_history_key(history)] = "r$(round)_q$(qubit)"
        end
    end
    return table
end

function reference_round_repetition_decoder(distance::Int, rounds::Int,
    history::AbstractString; max_fault_weight::Int=1)

    max_fault_weight == 1 ||
        error("reference_round_repetition_decoder currently supports max_fault_weight=1")
    table = round_repetition_single_fault_decoder_table(distance, rounds)
    return get(table, String(history), "uncorrectable")
end

function reference_round_repetition_decoder(distance::Int, rounds::Int,
    round_strings::AbstractVector{<:AbstractString}; max_fault_weight::Int=1)

    return reference_round_repetition_decoder(
        distance,
        rounds,
        round_history_key(round_strings);
        max_fault_weight=max_fault_weight,
    )
end

subject_decoder(subject::RoundRepetitionSubject, history::AbstractString) =
    reference_round_repetition_decoder(subject.distance, subject.rounds, history)

function round_fault_index(distance::Int, round::Int, qubit::Int)
    return (round - 1) * distance + qubit
end

function round_repetition_syndrome_expr_grid(subject::RoundRepetitionSubject,
    fault_exprs::AbstractVector{<:BoolExpr})

    state = SymbolicStabilizerState(
        "round_repetition_d$(subject.distance)_r$(subject.rounds)",
        subject.distance,
        repetition_syndrome_names(subject.distance),
        repetition_stabilizer_supports(subject.distance);
        pauli="X",
        generator_paulis=["Z" for _ in 1:(subject.distance - 1)],
    )
    syndrome_exprs = Vector{Vector{BoolExpr}}()
    for round in 1:subject.rounds
        for qubit in 1:subject.distance
            fault_idx = round_fault_index(subject.distance, round, qubit)
            absorb!(state, fault_exprs[fault_idx], qubit)
        end
        push!(syndrome_exprs, stabilizer_generator_phase_exprs(state))
    end
    return syndrome_exprs
end

function evaluate_round_history(syndrome_exprs::AbstractVector{<:AbstractVector},
    model::AbstractDict)

    return [
        [evaluate(expr, model) for expr in round_exprs]
        for round_exprs in syndrome_exprs
    ]
end

function round_history_strings(history_bits::AbstractVector{<:AbstractVector})
    return [
        repetition_syndrome_string(round_bits)
        for round_bits in history_bits
    ]
end

function round_history_named_bits(subject::RoundRepetitionSubject,
    history_bits::AbstractVector{<:AbstractVector})

    return [
        Dict{String,Any}(
            "round" => round,
            "syndrome" => repetition_syndrome_string(history_bits[round]),
            "bits" => Dict{String,Any}(
                "s$(idx)$(idx + 1)" => history_bits[round][idx]
                for idx in 1:(subject.distance - 1)
            ),
        )
        for round in 1:subject.rounds
    ]
end

function record_round_syndromes!(trace::ConcolicTrace,
    subject::RoundRepetitionSubject,
    history_bits::AbstractVector{<:AbstractVector},
    syndrome_exprs::AbstractVector{<:AbstractVector})

    for round in 1:subject.rounds
        for idx in 1:(subject.distance - 1)
            record_syndrome!(
                trace,
                "r$(round)_s$(idx)$(idx + 1)",
                history_bits[round][idx],
                syndrome_exprs[round][idx],
            )
        end
    end
    return trace
end

function record_round_syndrome_bit_branches!(trace::ConcolicTrace,
    subject::RoundRepetitionSubject,
    history_bits::AbstractVector{<:AbstractVector},
    syndrome_exprs::AbstractVector{<:AbstractVector})

    names = String[]
    values = Bool[]
    exprs = BoolExpr[]
    for round in 1:subject.rounds
        for idx in 1:(subject.distance - 1)
            push!(names, "r$(round)_s$(idx)$(idx + 1)")
            push!(values, history_bits[round][idx])
            push!(exprs, syndrome_exprs[round][idx])
        end
    end
    return record_syndrome_bit_branches!(trace, names, values, exprs)
end

function drop_first_round_history(subject::RoundRepetitionSubject,
    syndrome_exprs::AbstractVector{<:AbstractVector},
    history_bits::AbstractVector{<:AbstractVector})

    dropped_exprs = [BoolExpr[expr for expr in round_exprs] for round_exprs in syndrome_exprs]
    dropped_bits = [Bool[bit for bit in round_bits] for round_bits in history_bits]
    dropped_exprs[1] = [bconst(false) for _ in 1:(subject.distance - 1)]
    dropped_bits[1] = falses(subject.distance - 1)
    return dropped_exprs, dropped_bits
end

function decoder_history_for_subject(subject::RoundRepetitionSubject,
    syndrome_exprs::AbstractVector{<:AbstractVector},
    history_bits::AbstractVector{<:AbstractVector})

    subject.mode == :history_drop_bug &&
        return drop_first_round_history(subject, syndrome_exprs, history_bits)
    return syndrome_exprs, history_bits
end

function round_history_equals_expr(history_exprs::AbstractVector{<:AbstractVector},
    round_strings::AbstractVector{<:AbstractString})

    terms = BoolExpr[]
    for round in eachindex(round_strings)
        syndrome = round_strings[round]
        for idx in 1:length(syndrome)
            expr = history_exprs[round][idx]
            push!(terms, syndrome[idx] == '1' ? expr : bnot(expr))
        end
    end
    return band(terms...)
end

function round_repetition_decoder_arms(distance::Int, rounds::Int)
    arms = Vector{Tuple{String,String,Vector{String}}}()
    zero_history = round_zero_history(distance, rounds)
    push!(arms, (round_history_key(zero_history), "none", zero_history))
    for round in 1:rounds
        for qubit in 1:distance
            history = round_single_fault_history(distance, rounds, round, qubit)
            push!(arms, (round_history_key(history), "r$(round)_q$(qubit)", history))
        end
    end
    return arms
end

sanitize_history_id(history::AbstractString) = replace(String(history), "|" => "_")

function round_repetition_decoder_recovery_semantics(subject::RoundRepetitionSubject)
    rows = Dict{String,Any}[]
    for (history, output, round_strings) in
        round_repetition_decoder_arms(subject.distance, subject.rounds)

        pattern_names = round_repetition_syndrome_names(subject.distance, subject.rounds)
        pattern_rounds = round_strings
        if subject.mode == :history_drop_bug
            any(bit == '1' for bit in join(round_strings[1:1])) && continue
            all_names = round_repetition_syndrome_names(subject.distance, subject.rounds)
            first_kept = subject.distance
            pattern_names = first_kept <= length(all_names) ?
                all_names[first_kept:end] :
                String[]
            pattern_rounds = round_strings[2:end]
        end

        push!(
            rows,
            decoder_recovery_semantics_row(
                "decoder:history_$(sanitize_history_id(history))",
                smt_syndrome_pattern(pattern_names, join(pattern_rounds)),
                output,
                round_repetition_recovery_from_decoder(output),
            ),
        )
    end
    return rows
end

function round_repetition_decoder_output_conditions(subject::RoundRepetitionSubject,
    decoder_history_exprs::AbstractVector{<:AbstractVector})

    arms = round_repetition_decoder_arms(subject.distance, subject.rounds)
    outputs = unique!([output for (_history, output, _round_strings) in arms])
    conditions = Tuple{String,BoolExpr}[]
    for output in outputs
        terms = BoolExpr[
            round_history_equals_expr(decoder_history_exprs, round_strings)
            for (_history, arm_output, round_strings) in arms
            if arm_output == output
        ]
        isempty(terms) && continue
        push!(conditions, (output, length(terms) == 1 ? terms[1] : bor(terms...)))
    end
    return conditions
end

function select_round_repetition_decoder_output!(trace::ConcolicTrace,
    subject::RoundRepetitionSubject,
    decoder_history_exprs::AbstractVector{<:AbstractVector},
    decoder_history_bits::AbstractVector{<:AbstractVector})

    decoder_history = round_history_key(round_history_strings(decoder_history_bits))
    for (history, output, round_strings) in
        round_repetition_decoder_arms(subject.distance, subject.rounds)

        condition = round_history_equals_expr(decoder_history_exprs, round_strings)
        taken = decoder_history == history
        record_branch!(
            trace,
            "decoder:history_$(sanitize_history_id(history))",
            :decoder,
            condition,
            taken;
            description="decoder table arm for repeated-round syndrome history $(history)",
        )
        taken && return output
    end
    return "uncorrectable"
end

function parse_round_decoder_output(output::AbstractString)
    matched = match(r"^r([0-9]+)_q([0-9]+)$", String(output))
    matched === nothing && return nothing
    return (
        round=parse(Int, matched.captures[1]),
        qubit=parse(Int, matched.captures[2]),
    )
end

function round_repetition_recovery_from_decoder(decoder_output::AbstractString)
    output = String(decoder_output)
    if output == "none"
        return Dict{String,Any}(
            "pauli" => "I",
            "target" => "none",
            "source" => "decoder",
            "inferred_round" => nothing,
        )
    elseif output == "uncorrectable"
        return Dict{String,Any}(
            "pauli" => "missing",
            "target" => "uncorrectable",
            "source" => "decoder",
            "inferred_round" => nothing,
        )
    end

    location = parse_round_decoder_output(output)
    location === nothing &&
        error("Unsupported round repetition decoder output: $(decoder_output)")
    return Dict{String,Any}(
        "pauli" => "X",
        "target" => "q$(location.qubit)",
        "source" => "decoder",
        "inferred_round" => location.round,
    )
end

function round_repetition_latest_control_key(subject::RoundRepetitionSubject,
    history_strings::AbstractVector{<:AbstractString},
    decoder_output::AbstractString)

    location = parse_round_decoder_output(decoder_output)
    target = location === nothing ? String(decoder_output) : "q$(location.qubit)"
    latest = isempty(history_strings) ? "" : String(history_strings[end])
    return "latest_syndrome=$(latest);decoder_target=$(target)"
end

function final_round_repetition_faults(subject::RoundRepetitionSubject,
    model::AbstractDict)

    faults = falses(subject.distance)
    for round in 1:subject.rounds
        for qubit in 1:subject.distance
            var = round_repetition_fault_var(round, qubit)
            faults[qubit] = faults[qubit] != model_bool(model, var)
        end
    end
    return faults
end

function apply_round_repetition_recovery(faults::AbstractVector{Bool},
    recovery::Dict{String,Any})

    residual = copy(faults)
    target = String(recovery["target"])
    if startswith(target, "q")
        idx = parse(Int, target[2:end])
        residual[idx] = !residual[idx]
    end
    return residual
end

function round_recovery_matches(actual::Dict{String,Any}, expected::Dict{String,Any})
    return actual["pauli"] == expected["pauli"] &&
        actual["target"] == expected["target"] &&
        get(actual, "inferred_round", nothing) == get(expected, "inferred_round", nothing)
end

function run_round_repetition_subject(subject::RoundRepetitionSubject,
    input::AbstractDict)

    fault_vars = round_repetition_fault_vars(subject)
    model = normalize_assignment(fault_vars, input)

    trace = ConcolicTrace(
        subject.name;
        code_size=subject.distance,
        distance=subject.distance,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=Dict{String,Any}(
            "subject_family" => "round_repetition_code",
            "mode" => string(subject.mode),
            "distance" => subject.distance,
            "rounds" => subject.rounds,
            "fault_model" => "single Pauli-X data fault over all round/qubit locations",
            "max_fault_weight" => 1,
            "decoder" => "deterministic single-fault repeated-round syndrome history table",
            "fault_locations" =>
                round_repetition_fault_metadata(subject.distance, subject.rounds),
        ),
    )

    fault_exprs = [boolvar(var) for var in fault_vars]
    syndrome_exprs = round_repetition_syndrome_expr_grid(subject, fault_exprs)
    history_bits = evaluate_round_history(syndrome_exprs, model)
    history_strings = round_history_strings(history_bits)
    observed_history = round_history_key(history_strings)

    record_round_syndromes!(trace, subject, history_bits, syndrome_exprs)
    trace.metadata["syndrome_history"] =
        round_history_named_bits(subject, history_bits)
    trace.metadata["syndrome_history_key"] = observed_history

    decoder_history_exprs, decoder_history_bits =
        decoder_history_for_subject(subject, syndrome_exprs, history_bits)
    decoder_history_strings = round_history_strings(decoder_history_bits)
    decoder_history = round_history_key(decoder_history_strings)

    actual_decoder = select_round_repetition_decoder_output!(
        trace,
        subject,
        decoder_history_exprs,
        decoder_history_bits,
    )
    record_round_syndrome_bit_branches!(
        trace,
        subject,
        history_bits,
        syndrome_exprs,
    )
    expected_decoder =
        reference_round_repetition_decoder(subject.distance, subject.rounds, observed_history)

    record_decoder_decision!(trace, "syndrome", observed_history)
    record_decoder_decision!(trace, "observed_history", observed_history)
    record_decoder_decision!(trace, "decoder_history_used", decoder_history)
    record_decoder_decision!(trace, "actual", actual_decoder)
    record_decoder_decision!(trace, "expected", expected_decoder)

    actual_recovery = round_repetition_recovery_from_decoder(actual_decoder)
    expected_recovery = round_repetition_recovery_from_decoder(expected_decoder)
    record_recovery_output_branches!(
        trace,
        actual_decoder,
        round_repetition_decoder_output_conditions(subject, decoder_history_exprs),
    )
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    set_decoder_recovery_semantics!(
        trace,
        round_repetition_decoder_recovery_semantics(subject),
    )
    if subject.mode == :inconsistent_control_bug
        trace.metadata["decoder_state_key"] =
            round_repetition_latest_control_key(subject, history_strings, actual_decoder)
        trace.metadata["control_state_key"] = trace.metadata["decoder_state_key"]
    end
    trace.metadata["decoder_diagnostics"] = Dict{String,Any}(
        "observed_history" => observed_history,
        "decoder_history_used" => decoder_history,
        "history_mismatch" => observed_history != decoder_history,
    )
    if subject.mode == :history_drop_bug
        trace.metadata["history_drop_bug"] = Dict{String,Any}(
            "dropped_round" => 1,
            "description" => "decoder ignores the first repeated-round syndrome snapshot",
        )
    end

    pre_recovery_state = SymbolicStabilizerState(
        "round_repetition_d$(subject.distance)_r$(subject.rounds)",
        subject.distance,
        repetition_syndrome_names(subject.distance),
        repetition_stabilizer_supports(subject.distance);
        pauli="X",
        generator_paulis=["Z" for _ in 1:(subject.distance - 1)],
    )
    for round in 1:subject.rounds
        for qubit in 1:subject.distance
            var = round_repetition_fault_var(round, qubit)
            absorb!(pre_recovery_state, boolvar(var), qubit)
        end
    end
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

    history_ok = observed_history == decoder_history
    decoder_ok = actual_decoder == expected_decoder
    recovery_ok = round_recovery_matches(actual_recovery, expected_recovery)
    missing_recovery = actual_recovery["pauli"] == "missing"
    logical_ok = symbolic_logical_ok(post_recovery_state, model)
    oracle_ok = history_ok && decoder_ok && recovery_ok && logical_ok && !missing_recovery

    record_logical_verdict!(trace, "history_mismatch", !history_ok)
    record_logical_verdict!(trace, "decoder_mismatch", !decoder_ok)
    record_logical_verdict!(trace, "recovery_mismatch", !recovery_ok || missing_recovery)
    record_logical_verdict!(trace, "logical_mismatch", !logical_ok)
    record_logical_verdict!(trace, "missing_recovery_branch", missing_recovery)
    record_logical_verdict!(trace, "oracle_verdict", oracle_ok)
    record_logical_verdict!(trace, "residual_error", residual_error)
    record_logical_verdict!(trace, "residual_weight", count(identity, residual))

    if !history_ok
        trace.metadata["earliest_divergence_stage"] = "repeated_round_control"
    elseif !decoder_ok
        trace.metadata["earliest_divergence_stage"] = "decoder"
    elseif !recovery_ok || missing_recovery
        trace.metadata["earliest_divergence_stage"] = "recovery"
    elseif !logical_ok
        trace.metadata["earliest_divergence_stage"] = "logical_check"
    end

    return trace
end
