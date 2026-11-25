function fault_weight(trace::ConcolicTrace)
    return count(var -> model_bool(trace.fault_assignments, var), trace.fault_vars)
end

function active_fault_vars(trace::ConcolicTrace)
    return [var for var in trace.fault_vars if model_bool(trace.fault_assignments, var)]
end

function clear_fault(model::AbstractDict, var::Symbol)
    out = Dict{Symbol,Bool}(to_symbol(key) => Bool(value) for (key, value) in model)
    out[var] = false
    return out
end

function minimum_fault_weight_constraint(fault_vars::Vector{Symbol}, min_weight::Integer)
    target = Int(min_weight)
    target <= 0 && return bconst(true)
    target > length(fault_vars) && return bconst(false)

    subset_size = length(fault_vars) - target + 1
    combinations = Vector{Symbol}[]
    append_capacity_combinations!(
        combinations,
        fault_vars,
        Symbol[],
        1,
        subset_size,
    )
    return band([bor((boolvar(var) for var in combo)...) for combo in combinations]...)
end

function exact_fault_weight_constraint(fault_vars::Vector{Symbol}, weight::Integer)
    target = Int(weight)
    target < 0 && return bconst(false)
    target > length(fault_vars) && return bconst(false)
    return band(
        fault_capacity_constraint(fault_vars, target),
        minimum_fault_weight_constraint(fault_vars, target),
    )
end

function same_failure_kind(original::ConcolicTrace, candidate::ConcolicTrace;
    preserve_divergence=true,
    primary_oracle=nothing)

    trace_has_bug(candidate) || return false
    oracle_id = primary_oracle_id(primary_oracle)
    if oracle_id !== nothing &&
            !(oracle_id in triggered_failure_oracle_ids(candidate))
        return false
    end
    preserve_divergence || return true
    return earliest_divergence(original) == earliest_divergence(candidate)
end

function removed_fault_vars(original::ConcolicTrace, minimized::ConcolicTrace)
    return [
        var for var in original.fault_vars
        if model_bool(original.fault_assignments, var) &&
            !model_bool(minimized.fault_assignments, var)
    ]
end

function added_fault_vars(original::ConcolicTrace, minimized::ConcolicTrace)
    return [
        var for var in minimized.fault_vars
        if !model_bool(original.fault_assignments, var) &&
            model_bool(minimized.fault_assignments, var)
    ]
end

function changed_fault_vars(original::ConcolicTrace, minimized::ConcolicTrace)
    vars = sort!(collect(union(Set(original.fault_vars), Set(minimized.fault_vars))), by=string)
    return [
        var for var in vars
        if model_bool(original.fault_assignments, var) !=
            model_bool(minimized.fault_assignments, var)
    ]
end

function first_failing_assignment_at_weight(
    trace::ConcolicTrace,
    subject_runner,
    target_weight::Integer;
    preserve_divergence=true,
    primary_oracle=nothing,
    solver=nothing,
    stats=nothing)

    fault_vars = copy(trace.fault_vars)
    local_solver = solver === nothing ?
        BruteForceBoolSolver(fault_vars; max_weight=Int(target_weight)) :
        solver_fault_vars(solver) == fault_vars ? solver : solver_for_fault_vars(solver, fault_vars)
    constraints = BoolExpr[exact_fault_weight_constraint(fault_vars, target_weight)]
    avoided = Set{String}()

    while true
        if stats !== nothing
            stats["minimizer_backend"] = solver_name(local_solver)
            stats["minimizer_query_count"] = Int(get(stats, "minimizer_query_count", 0)) + 1
        end
        result = solve_model(local_solver, constraints; avoid=avoided)
        record_minimizer_result!(stats, result, local_solver)
        result.status == :sat || return nothing
        candidate_model = normalize_assignment(fault_vars, result.model)
        push!(avoided, assignment_key(fault_vars, candidate_model))

        candidate_trace = subject_runner(candidate_model)
        if same_failure_kind(
                trace,
                candidate_trace;
                preserve_divergence=preserve_divergence,
                primary_oracle=primary_oracle,
            )
            return candidate_trace
        end
    end
end

function minimize_fault_assignment(trace::ConcolicTrace, subject_runner;
    preserve_divergence=true,
    primary_oracle=nothing,
    solver=nothing)

    original_weight = fault_weight(trace)
    stats = Dict{String,Any}(
        "already_minimal" => original_weight <= 1,
        "minimizer_backend" => solver === nothing ? solver_name(BruteForceBoolSolver(trace.fault_vars; max_weight=0)) : solver_name(solver),
        "minimizer_query_count" => 0,
        "minimizer_cache_hit_count" => 0,
        "minimizer_presolver_hit_count" => 0,
        "minimizer_timeout_count" => 0,
        "minimizer_query_bytes" => 0,
        "minimizer_z3_process_starts" => 0,
        "minimization_elapsed_ms" => 0.0,
    )
    start_ns = time_ns()
    if original_weight <= 1
        stats["minimization_elapsed_ms"] = elapsed_ms_since(start_ns)
        return trace, Symbol[], stats
    end

    for target_weight in 0:(original_weight - 1)
        candidate_trace = first_failing_assignment_at_weight(
            trace,
            subject_runner,
            target_weight;
            preserve_divergence=preserve_divergence,
            primary_oracle=primary_oracle,
            solver=solver,
            stats=stats,
        )
        candidate_trace === nothing && continue
        stats["minimization_elapsed_ms"] = elapsed_ms_since(start_ns)
        return candidate_trace, removed_fault_vars(trace, candidate_trace), stats
    end

    stats["minimization_elapsed_ms"] = elapsed_ms_since(start_ns)
    return trace, Symbol[], stats
end

elapsed_ms_since(start_ns::UInt64) =
    round((time_ns() - start_ns) / 1_000_000; digits=3)

function truthy_metadata(value)
    value isa Bool && return value
    lowercase(string(value)) in ("true", "1", "yes", "on")
end

function record_minimizer_result!(stats, result::SolverResult, solver)
    stats === nothing && return stats
    metadata = result.metadata
    if truthy_metadata(get(metadata, "cache_hit", false))
        stats["minimizer_cache_hit_count"] =
            Int(get(stats, "minimizer_cache_hit_count", 0)) + 1
    end
    presolver_status = uppercase(string(get(metadata, "presolver_status", "none")))
    if presolver_status in ("SAT", "UNSAT") && Int(get(metadata, "query_bytes", 0)) == 0
        stats["minimizer_presolver_hit_count"] =
            Int(get(stats, "minimizer_presolver_hit_count", 0)) + 1
    end
    if truthy_metadata(get(metadata, "timed_out", false)) ||
            uppercase(string(get(metadata, "solver_status", ""))) == "TIMEOUT"
        stats["minimizer_timeout_count"] =
            Int(get(stats, "minimizer_timeout_count", 0)) + 1
    end
    stats["minimizer_query_bytes"] =
        Int(get(stats, "minimizer_query_bytes", 0)) +
        something(tryparse(Int, string(get(metadata, "query_bytes", "0"))), 0)
    if solver isa SolverChainBackend && solver.base isa PersistentZ3Backend
        stats["minimizer_z3_process_starts"] =
            Int(get(stats, "minimizer_query_count", 0)) > 0 ? 1 : 0
    elseif solver isa PersistentZ3Backend
        stats["minimizer_z3_process_starts"] =
            Int(get(stats, "minimizer_query_count", 0)) > 0 ? 1 : 0
    elseif solver isa Union{Z3Backend,BitwuzlaBackend}
        stats["minimizer_z3_process_starts"] =
            Int(get(stats, "minimizer_query_count", 0))
    end
    return stats
end

function minimization_metadata(original::ConcolicTrace, minimized::ConcolicTrace,
    removed_faults::Vector{Symbol},
    primary_oracle=nothing;
    strategy=nothing)

    metadata = Dict{String,Any}(
        "strategy" => strategy === nothing ? (primary_oracle === nothing ?
            "bounded_fault_weight_search" :
            "bounded_oracle_preserving_fault_weight_search") : String(strategy),
        "preserved_primary_oracle" => primary_oracle_id(primary_oracle),
        "original_fault_weight" => fault_weight(original),
        "minimized_fault_weight" => fault_weight(minimized),
        "removed_fault_variables" => string.(removed_faults),
        "added_fault_variables" => string.(added_fault_vars(original, minimized)),
        "changed_fault_variables" => string.(changed_fault_vars(original, minimized)),
        "original_path_length" => length(original.branch_guards),
        "minimized_path_length" => length(minimized.branch_guards),
        "preserved_earliest_divergence" =>
            earliest_divergence(original) == earliest_divergence(minimized),
    )
    round_metadata = repeated_round_minimization_metadata(original, minimized, primary_oracle)
    round_metadata === nothing || (metadata["round_minimization"] = round_metadata)
    return metadata
end

function round_repetition_mode_from_trace(trace::ConcolicTrace)
    mode = get(trace.metadata, "mode", nothing)
    mode === nothing && return nothing
    return Symbol(String(mode))
end

function round_repetition_projected_model(trace::ConcolicTrace, distance::Int, rounds::Int)
    vars = round_repetition_fault_vars(distance, rounds)
    return Dict{Symbol,Bool}(var => model_bool(trace.fault_assignments, var) for var in vars)
end

function repeated_round_minimization_metadata(
    original::ConcolicTrace,
    minimized::ConcolicTrace,
    primary_oracle=nothing)

    get(minimized.metadata, "subject_family", nothing) == "round_repetition_code" ||
        return nothing
    original_rounds = get(minimized.metadata, "rounds", nothing)
    distance = get(minimized.metadata, "distance", nothing)
    original_rounds isa Integer || return nothing
    distance isa Integer || return nothing
    mode = round_repetition_mode_from_trace(minimized)
    mode === nothing && return nothing

    if primary_oracle_id(primary_oracle) == "O5_INCONSISTENT_CONTROL"
        return Dict{String,Any}(
            "strategy" => "relational_oracle_noop",
            "original_rounds" => Int(original_rounds),
            "minimized_rounds" => Int(original_rounds),
            "shortened" => false,
            "reason" => "O5 requires a relational witness set",
        )
    end

    for candidate_rounds in 1:(Int(original_rounds) - 1)
        candidate_subject = RoundRepetitionSubject(Int(distance), candidate_rounds, mode)
        candidate_model =
            round_repetition_projected_model(minimized, Int(distance), candidate_rounds)
        candidate_trace = run_round_repetition_subject(candidate_subject, candidate_model)
        if same_failure_kind(
                original,
                candidate_trace;
                preserve_divergence=true,
                primary_oracle=primary_oracle,
            )
            return Dict{String,Any}(
                "strategy" => "bounded_prefix_round_search",
                "original_rounds" => Int(original_rounds),
                "minimized_rounds" => candidate_rounds,
                "shortened" => true,
                "preserved_primary_oracle" => primary_oracle_id(primary_oracle),
                "preserved_earliest_divergence" =>
                    earliest_divergence(original) == earliest_divergence(candidate_trace),
                "reproducer_subject" => candidate_trace.subject_name,
                "reproducer_fault_pattern" => fault_pattern(candidate_trace),
                "reproducer_earliest_divergence" => earliest_divergence(candidate_trace),
            )
        end
    end

    return Dict{String,Any}(
        "strategy" => "bounded_prefix_round_search",
        "original_rounds" => Int(original_rounds),
        "minimized_rounds" => Int(original_rounds),
        "shortened" => false,
        "preserved_primary_oracle" => primary_oracle_id(primary_oracle),
    )
end

function minimize_witness(trace::ConcolicTrace, subject_runner;
    preserve_divergence=true,
    exploration_settings=Dict{String,Any}(),
    primary_oracle=nothing,
    minimization_solver=nothing)

    if primary_oracle_id(primary_oracle) == "O5_INCONSISTENT_CONTROL"
        witness = build_witness(
            trace;
            exploration_settings=exploration_settings,
            primary_oracle=primary_oracle,
        )
        witness["minimization"] =
            minimization_metadata(
                trace,
                trace,
                Symbol[],
                primary_oracle;
                strategy="relational_oracle_noop",
            )
        return witness, trace
    end

    minimized_trace, removed, stats =
        minimize_fault_assignment(
            trace,
            subject_runner;
            preserve_divergence=preserve_divergence,
            primary_oracle=primary_oracle,
            solver=minimization_solver,
        )
    witness = build_witness(
        minimized_trace;
        exploration_settings=exploration_settings,
        primary_oracle=primary_oracle,
    )
    witness["minimization"] =
        minimization_metadata(trace, minimized_trace, removed, primary_oracle)
    for (key, value) in stats
        witness["minimization"][key] = value
    end
    return witness, minimized_trace
end
