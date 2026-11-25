struct HistoryChallengeSubject
    name::String
    qubits::Int
    rounds::Int
    mode::Symbol
    target_round::Int
    target_qubit::Int
    budget::Int
end

const HISTORY_CHALLENGE_MODES = (
    :clean,
    :history_drop_bug,
    :stale_history_reuse_bug,
    :off_by_one_round_bug,
    :inconsistent_control_bug,
    :equivalent_current_control_bug,
    :missing_reset_bug,
)

function HistoryChallengeSubject(qubits::Int, rounds::Int, mode::Symbol=:clean;
    target_round::Int=history_default_target_round(rounds, mode),
    target_qubit::Int=history_default_target_qubit(qubits, mode),
    budget::Integer=history_challenge_recommended_budget(qubits))

    qubits >= 5 || error("History challenge subject must have at least 5 qubits")
    rounds >= 2 || error("History challenge subject must have at least 2 rounds")
    mode in HISTORY_CHALLENGE_MODES ||
        error("Unsupported history challenge subject mode: $(mode)")
    1 <= target_round <= rounds ||
        error("target_round must lie in 1:$(rounds)")
    1 <= target_qubit <= qubits ||
        error("target_qubit must lie in 1:$(qubits)")
    budget > 0 || error("budget must be positive")

    suffix = mode == :clean ? "clean" :
        string(mode, "_r", target_round, "_q", target_qubit)
    return HistoryChallengeSubject(
        "history_challenge_n$(qubits)_r$(rounds)_$(suffix)",
        qubits,
        rounds,
        mode,
        target_round,
        target_qubit,
        Int(budget),
    )
end

function history_default_target_round(rounds::Int, mode::Symbol=:clean)
    mode == :history_drop_bug && return 1
    mode == :stale_history_reuse_bug && return min(rounds, 2)
    mode == :off_by_one_round_bug && return rounds == 2 ? 1 : 2
    mode in (:inconsistent_control_bug, :equivalent_current_control_bug) &&
        return min(rounds, max(2, cld(rounds, 2)))
    mode == :missing_reset_bug && return min(rounds, 2)
    return rounds == 2 ? 1 : 2
end

function history_default_target_qubit(qubits::Int, mode::Symbol=:clean)
    mode == :history_drop_bug && return max(2, cld(qubits, 5))
    mode == :stale_history_reuse_bug && return max(3, cld(2 * qubits, 5))
    mode == :off_by_one_round_bug && return max(4, cld(3 * qubits, 5))
    mode == :inconsistent_control_bug && return max(5, cld(4 * qubits, 5))
    mode == :equivalent_current_control_bug && return max(2, fld(qubits, 2))
    mode == :missing_reset_bug && return max(2, fld(3 * qubits, 4))
    return max(2, cld(qubits, 3))
end

history_fault_var(round::Int, qubit::Int) = Symbol("x_r$(round)_q$(qubit)")

function history_challenge_fault_vars(qubits::Int, rounds::Int)
    return [
        history_fault_var(round, qubit)
        for round in 1:rounds
        for qubit in 1:qubits
    ]
end

history_challenge_fault_vars(subject::HistoryChallengeSubject) =
    history_challenge_fault_vars(subject.qubits, subject.rounds)

function history_challenge_fault_metadata(qubits::Int, rounds::Int)
    return [
        Dict{String,Any}(
            "variable" => string(history_fault_var(round, qubit)),
            "round" => round,
            "qubit" => qubit,
            "site" => "data",
            "pauli" => "X",
            "label" => "X@r$(round):q$(qubit)",
        )
        for round in 1:rounds
        for qubit in 1:qubits
    ]
end

function history_state_count(qubits::Int, rounds::Int)
    return 1 + qubits * rounds
end

history_challenge_recommended_budget(qubits::Int) =
    qubits <= 50 ? 32 : 64

function history_challenge_metadata(subject::HistoryChallengeSubject)
    assignments = subject.qubits * subject.rounds
    budget = subject.budget
    return Dict{String,Any}(
        "subject_family" => "repeated_round_history_challenge",
        "benchmark_family" => "RepeatedRoundHistory",
        "mode" => string(subject.mode),
        "qubits" => subject.qubits,
        "fault_variables" => assignments,
        "max_fault_weight" => 1,
        "fault_model" => "single Pauli-X data fault over round/qubit locations",
        "admissible_fault_assignments" => assignments,
        "syndrome_bits" => subject.qubits * subject.rounds,
        "reachable_syndrome_values" => history_state_count(subject.qubits, subject.rounds),
        "decoder_arms" => history_state_count(subject.qubits, subject.rounds),
        "recovery_actions" => history_state_count(subject.qubits, subject.rounds),
        "rounds" => subject.rounds,
        "history_states" => history_state_count(subject.qubits, subject.rounds),
        "target_round" => subject.target_round,
        "target_qubit" => subject.target_qubit,
        "failing_assignments" => subject.mode == :clean ? 0 : 1,
        "estimated_bug_probability" => subject.mode == :clean ? 0.0 : 1.0 / assignments,
        "recommended_budget" => budget,
        "exhaustibility_ratio" => budget / assignments,
        "path_sensitive" => subject.mode != :clean,
        "history_dependent" => true,
        "trigger_faults" => [
            string(history_fault_var(subject.target_round, subject.target_qubit)),
        ],
        "interesting_faults" => [
            string(history_fault_var(subject.target_round, subject.target_qubit)),
        ],
        "boring_faults" => [
            string(history_fault_var(round, qubit))
            for round in 1:subject.rounds for qubit in 1:min(subject.qubits, 16)
            if !(round == subject.target_round && qubit == subject.target_qubit)
        ],
        "fault_locations" =>
            history_challenge_fault_metadata(subject.qubits, subject.rounds),
    )
end

function history_active_location(subject::HistoryChallengeSubject, model::AbstractDict)
    active = Tuple{Int,Int}[]
    for round in 1:subject.rounds
        for qubit in 1:subject.qubits
            model_bool(model, history_fault_var(round, qubit)) &&
                push!(active, (round, qubit))
        end
    end
    isempty(active) && return nothing
    length(active) == 1 && return only(active)
    return :multiple
end

function history_challenge_syndrome_bits(subject::HistoryChallengeSubject,
    model::AbstractDict)

    state = falses(subject.qubits)
    history = Vector{Vector{Bool}}()
    for round in 1:subject.rounds
        for qubit in 1:subject.qubits
            var = history_fault_var(round, qubit)
            state[qubit] = state[qubit] != model_bool(model, var)
        end
        push!(history, copy(state))
    end
    return history
end

function history_challenge_syndrome_exprs(subject::HistoryChallengeSubject)
    state = BoolExpr[bconst(false) for _ in 1:subject.qubits]
    history = Vector{Vector{BoolExpr}}()
    for round in 1:subject.rounds
        for qubit in 1:subject.qubits
            state[qubit] = bxor(state[qubit], boolvar(history_fault_var(round, qubit)))
        end
        push!(history, copy(state))
    end
    return history
end

history_round_string(bits::AbstractVector{Bool}) =
    join(bit ? "1" : "0" for bit in bits)

history_key(history_bits::AbstractVector{<:AbstractVector}) =
    join([history_round_string(bits) for bits in history_bits], "|")

function history_reference_decoder(location)
    location === nothing && return "none"
    location == :multiple && return "uncorrectable"
    round, qubit = location
    return "r$(round)_q$(qubit)"
end

function history_shifted_decoder(subject::HistoryChallengeSubject, expected::AbstractString)
    expected in ("none", "uncorrectable") && return String(expected)
    matched = match(r"^r([0-9]+)_q([0-9]+)$", String(expected))
    matched === nothing && return String(expected)
    round = parse(Int, matched.captures[1])
    qubit = parse(Int, matched.captures[2])
    shifted = clamp(round + 1, 1, subject.rounds)
    shifted == round && (shifted = max(1, round - 1))
    return "r$(shifted)_q$(qubit)"
end

function history_actual_decoder(subject::HistoryChallengeSubject, expected::AbstractString,
    location)

    location == (subject.target_round, subject.target_qubit) || return String(expected)
    subject.mode == :history_drop_bug && return "r$(min(subject.rounds, subject.target_round + 1))_q$(subject.target_qubit)"
    subject.mode == :stale_history_reuse_bug && return "r$(max(1, subject.target_round - 1))_q$(subject.target_qubit)"
    subject.mode == :off_by_one_round_bug && return history_shifted_decoder(subject, expected)
    subject.mode == :missing_reset_bug && return "uncorrectable"
    return String(expected)
end

function history_recovery_from_decoder(decoder_output::AbstractString)
    output = String(decoder_output)
    if output == "none"
        return Dict{String,Any}(
            "pauli" => "I",
            "target" => "none",
            "source" => "history_decoder",
            "inferred_round" => nothing,
        )
    elseif output == "uncorrectable"
        return Dict{String,Any}(
            "pauli" => "missing",
            "target" => "uncorrectable",
            "source" => "history_decoder",
            "inferred_round" => nothing,
        )
    end
    matched = match(r"^r([0-9]+)_q([0-9]+)$", output)
    matched === nothing &&
        error("Unsupported history decoder output: $(decoder_output)")
    round = parse(Int, matched.captures[1])
    qubit = parse(Int, matched.captures[2])
    return Dict{String,Any}(
        "pauli" => "X",
        "target" => "q$(qubit)",
        "source" => "history_decoder",
        "inferred_round" => round,
    )
end

function apply_history_recovery(subject::HistoryChallengeSubject,
    model::AbstractDict,
    recovery::AbstractDict)

    final = falses(subject.qubits)
    for round in 1:subject.rounds
        for qubit in 1:subject.qubits
            final[qubit] = final[qubit] != model_bool(model, history_fault_var(round, qubit))
        end
    end
    target = String(get(recovery, "target", "none"))
    if startswith(target, "q")
        idx = parse(Int, target[2:end])
        final[idx] = !final[idx]
    end
    return final
end

function history_decoy_locations(subject::HistoryChallengeSubject; limit::Int=24)
    locations = Tuple{Int,Int}[]
    for round in 1:subject.rounds
        for qubit in 1:subject.qubits
            location = (round, qubit)
            location == (subject.target_round, subject.target_qubit) && continue
            push!(locations, location)
            length(locations) >= limit && return locations
        end
    end
    return locations
end

function record_history_path_branches!(trace::ConcolicTrace,
    subject::HistoryChallengeSubject)

    for (round, qubit) in history_decoy_locations(subject)
        var = history_fault_var(round, qubit)
        record_branch!(
            trace,
            "fault:history_decoy_r$(round)_q$(qubit)",
            :fault,
            boolvar(var),
            trace.fault_assignments[var];
            description="history challenge decoy round/qubit location",
        )
    end
    target = history_fault_var(subject.target_round, subject.target_qubit)
    record_branch!(
        trace,
        "repeated_round_control:target_history_r$(subject.target_round)_q$(subject.target_qubit)",
        :repeated_round_control,
        boolvar(target),
        trace.fault_assignments[target];
        description="history-sensitive target control state",
    )
    return trace
end

function run_history_challenge_subject(subject::HistoryChallengeSubject,
    input::AbstractDict)

    fault_vars = history_challenge_fault_vars(subject)
    model = normalize_assignment(fault_vars, input)
    history_bits = history_challenge_syndrome_bits(subject, model)
    history_exprs = history_challenge_syndrome_exprs(subject)
    observed_history = history_key(history_bits)
    location = history_active_location(subject, model)

    trace = ConcolicTrace(
        subject.name;
        code_size=subject.qubits,
        distance=3,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=history_challenge_metadata(subject),
    )

    for round in 1:subject.rounds
        for qubit in 1:subject.qubits
            name = "r$(round)_s_q$(qubit)"
            record_syndrome!(trace, name, history_bits[round][qubit], history_exprs[round][qubit])
        end
    end
    trace.metadata["syndrome_history_key"] = observed_history
    trace.metadata["syndrome_history"] = [
        Dict{String,Any}(
            "round" => round,
            "syndrome" => history_round_string(history_bits[round]),
        )
        for round in 1:subject.rounds
    ]
    record_history_path_branches!(trace, subject)

    expected_decoder = history_reference_decoder(location)
    actual_decoder = history_actual_decoder(subject, expected_decoder, location)
    expected_recovery = history_recovery_from_decoder(expected_decoder)
    actual_recovery = history_recovery_from_decoder(actual_decoder)

    record_decoder_decision!(trace, "syndrome", observed_history)
    record_decoder_decision!(trace, "observed_history", observed_history)
    record_decoder_decision!(trace, "actual", actual_decoder)
    record_decoder_decision!(trace, "expected", expected_decoder)
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery

    residual = apply_history_recovery(subject, model, actual_recovery)
    residual_error = Dict{String,Any}("q$(idx)" => residual[idx] for idx in eachindex(residual))
    decoder_ok = actual_decoder == expected_decoder
    recovery_ok = actual_recovery["pauli"] == expected_recovery["pauli"] &&
        actual_recovery["target"] == expected_recovery["target"] &&
        get(actual_recovery, "inferred_round", nothing) ==
            get(expected_recovery, "inferred_round", nothing)
    missing_recovery = actual_recovery["pauli"] == "missing"
    relational_bug = location == (subject.target_round, subject.target_qubit) &&
        subject.mode in (:inconsistent_control_bug, :equivalent_current_control_bug)
    logical_ok = count(identity, residual) == 0
    oracle_ok = decoder_ok && recovery_ok && logical_ok && !missing_recovery && !relational_bug

    record_logical_verdict!(trace, "history_mismatch", !decoder_ok)
    record_logical_verdict!(trace, "decoder_mismatch", !decoder_ok)
    record_logical_verdict!(trace, "recovery_mismatch", !recovery_ok || missing_recovery)
    record_logical_verdict!(trace, "logical_mismatch", !logical_ok)
    record_logical_verdict!(trace, "missing_recovery_branch", missing_recovery)
    record_logical_verdict!(trace, "inconsistent_control", relational_bug)
    record_logical_verdict!(trace, "oracle_verdict", oracle_ok)
    record_logical_verdict!(trace, "residual_error", residual_error)
    record_logical_verdict!(trace, "residual_weight", count(identity, residual))

    trace.metadata["decoder_state_key"] =
        "current=" * history_round_string(history_bits[end]) * ";target=q$(subject.target_qubit)"
    trace.metadata["control_state_key"] = trace.metadata["decoder_state_key"]
    trace.metadata["history_challenge_diagnostics"] = Dict{String,Any}(
        "active_location" => location === nothing ? "none" : string(location),
        "target_location" => "r$(subject.target_round)_q$(subject.target_qubit)",
        "current_syndrome" => history_round_string(history_bits[end]),
        "requires_history" => true,
        "round_prefix_length" => subject.rounds,
    )
    if relational_bug || !decoder_ok || !recovery_ok || missing_recovery
        trace.metadata["earliest_divergence_stage"] = "repeated_round_control"
    elseif !logical_ok
        trace.metadata["earliest_divergence_stage"] = "logical_check"
    end

    return trace
end
