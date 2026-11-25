struct BranchPriorityWeights
    failure_adjacent::Int
    syndrome_diverse::Int
    small_fault::Int

    function BranchPriorityWeights(failure_adjacent::Integer,
        syndrome_diverse::Integer,
        small_fault::Integer)

        values = (failure_adjacent, syndrome_diverse, small_fault)
        all(value -> value >= 0, values) ||
            error("branch priority weights must be non-negative")
        any(value -> value > 0, values) ||
            error("at least one branch priority weight must be positive")
        if failure_adjacent > 0 && syndrome_diverse > 0
            failure_adjacent > syndrome_diverse ||
                error("active branch priority weights must satisfy failure_adjacent > syndrome_diverse")
        end
        if syndrome_diverse > 0 && small_fault > 0
            syndrome_diverse > small_fault ||
                error("active branch priority weights must satisfy syndrome_diverse > small_fault")
        end
        if failure_adjacent > 0 && small_fault > 0
            failure_adjacent > small_fault ||
                error("active branch priority weights must satisfy failure_adjacent > small_fault")
        end
        return new(Int(failure_adjacent), Int(syndrome_diverse), Int(small_fault))
    end
end

function BranchPriorityWeights(;
    failure_adjacent::Integer=100,
    syndrome_diverse::Integer=10,
    small_fault::Integer=1)

    return BranchPriorityWeights(failure_adjacent, syndrome_diverse, small_fault)
end

const DEFAULT_BRANCH_PRIORITY_WEIGHTS = BranchPriorityWeights()

mutable struct ConcolicExplorer
    fault_vars::Vector{Symbol}
    solver::AbstractConcolicSolver
    worklist::Vector{Dict{Symbol,Bool}}
    input_query_metadata::Dict{String,Dict{String,Any}}
    seen_inputs::Set{String}
    max_tests::Int
    branch_strategy::Symbol
    priority_profile::Symbol
    priority_weights::BranchPriorityWeights
    branch_query_results::Vector{Dict{String,Any}}
    branch_batching::Bool
    max_branch_batch_size::Int
    batch_mode::Symbol
    parallel_branches::Bool
    parallel_branch_jobs::Int
    min_parallel_branch_batch_size::Int
    lazy_branch_priority::Bool
    first_new_successor::Bool
end

struct ExplorationResult
    traces::Vector{ConcolicTrace}
    generated_tests::Int
    unique_syndromes::Set{String}
    bug_found::Bool
    witness::Union{Nothing,Dict{String,Any}}
    witness_path::Union{Nothing,String}
    witnesses::Vector{Dict{String,Any}}
    witness_paths::Vector{String}
    branch_query_results::Vector{Dict{String,Any}}
end

function normalize_seed_assignments(fault_vars::Vector{Symbol}, seed_source)
    seed_source === nothing && return [zero_assignment(fault_vars)]
    if seed_source isa AbstractDict
        return [normalize_assignment(fault_vars, seed_source)]
    end

    seeds = Dict{Symbol,Bool}[]
    for seed in seed_source
        seed isa AbstractDict ||
            error("seed assignments must be dictionaries, got $(typeof(seed))")
        push!(seeds, normalize_assignment(fault_vars, seed))
    end
    return seeds
end

function initial_seed_worklist(fault_vars::Vector{Symbol}; initial=nothing, seeds=nothing)
    initial !== nothing && seeds !== nothing &&
        error("Pass either initial or seeds, not both")

    seed_source = seeds === nothing ? initial : seeds
    normalized_seeds = normalize_seed_assignments(fault_vars, seed_source)
    worklist = Dict{Symbol,Bool}[]
    seen = Set{String}()
    for seed in normalized_seeds
        key = assignment_key(fault_vars, seed)
        key in seen && continue
        push!(seen, key)
        push!(worklist, seed)
    end
    return worklist, seen
end

function ConcolicExplorer(fault_vars::Vector{Symbol};
    initial=nothing,
    seeds=nothing,
    max_tests=32,
    max_fault_weight=1,
    branch_strategy=:qec_priority,
    priority_profile=:bugfinding,
    priority_weights=DEFAULT_BRANCH_PRIORITY_WEIGHTS,
    solver=BruteForceBoolSolver(fault_vars; max_weight=max_fault_weight),
    branch_batching=false,
    max_branch_batch_size=typemax(Int),
    batch_mode=priority_profile,
    parallel_branches=false,
    parallel_branch_jobs=1,
    min_parallel_branch_batch_size=2,
    lazy_branch_priority=false,
    first_new_successor=false)

    branch_strategy in (:qec_priority, :trace_order) ||
        error("unsupported branch strategy: $(branch_strategy)")
    priority_profile in (:bugfinding, :coverage) ||
        error("unsupported priority profile: $(priority_profile)")
    batch_mode in (:bugfinding, :coverage) ||
        error("unsupported batch mode: $(batch_mode)")
    max_branch_batch_size >= 1 ||
        error("max_branch_batch_size must be at least 1")
    parallel_branch_jobs >= 1 ||
        error("parallel_branch_jobs must be at least 1")
    min_parallel_branch_batch_size >= 2 ||
        error("min_parallel_branch_batch_size must be at least 2")
    worklist, seen = initial_seed_worklist(fault_vars; initial=initial, seeds=seeds)
    return ConcolicExplorer(
        copy(fault_vars),
        solver,
        worklist,
        Dict{String,Dict{String,Any}}(),
        seen,
        max_tests,
        branch_strategy,
        priority_profile,
        priority_weights,
        Dict{String,Any}[],
        Bool(branch_batching),
        Int(max_branch_batch_size),
        Symbol(batch_mode),
        Bool(parallel_branches),
        Int(parallel_branch_jobs),
        Int(min_parallel_branch_batch_size),
        Bool(lazy_branch_priority),
        Bool(first_new_successor),
    )
end

function enqueue!(explorer::ConcolicExplorer, model::Dict{Symbol,Bool};
    query_metadata=nothing)
    key = assignment_key(explorer.fault_vars, model)
    key in explorer.seen_inputs && return false
    push!(explorer.seen_inputs, key)
    push!(explorer.worklist, model)
    query_metadata === nothing ||
        (explorer.input_query_metadata[key] = Dict{String,Any}(query_metadata))
    return true
end

trace_has_bug(trace::ConcolicTrace) =
    get(trace.logical_verdicts, "oracle_verdict", true) == false

function oracle_file_suffix(oracle)
    id = primary_oracle_id(oracle)
    id === nothing && return ""
    return "_" * replace(id, r"[^A-Za-z0-9_.-]" => "_")
end

function witness_solver_backend_name(solver::AbstractConcolicSolver)
    solver isa BruteForceBoolSolver && return WITNESS_SOLVER_BACKEND
    return solver_name(solver)
end

function witness_file_name(trace::ConcolicTrace, test_index::Integer;
    primary_oracle=nothing,
    oracle_index::Integer=1)

    safe_subject = replace(trace.subject_name, r"[^A-Za-z0-9_.-]" => "_")
    suffix = oracle_index == 1 ? "" : oracle_file_suffix(primary_oracle)
    return safe_subject * "_witness_" * string(test_index) * suffix * ".json"
end

function stage_priority(stage::Symbol)
    stage == :logical_check && return 1
    stage == :recovery && return 2
    stage == :repeated_round_control && return 2
    stage == :decoder && return 3
    stage == :measurement_result && return 4
    stage == :syndrome && return 5
    stage == :fault && return 6
    return 7
end

function model_fault_weight(fault_vars::AbstractVector{Symbol}, model::AbstractDict)
    return count(var -> model_bool(model, var), fault_vars)
end

function model_hamming_distance(fault_vars::AbstractVector{Symbol},
    left::AbstractDict,
    right::AbstractDict)

    return count(var -> model_bool(left, var) != model_bool(right, var), fault_vars)
end

function witness_distance(fault_vars::AbstractVector{Symbol},
    model::AbstractDict,
    witness_models::AbstractVector)

    isempty(witness_models) && return typemax(Int)
    return minimum(
        witness_model -> model_hamming_distance(fault_vars, model, witness_model),
        witness_models,
    )
end

function branch_signature(trace::ConcolicTrace; branch_index=nothing)
    target = branch_index === nothing ? nothing : require_path_constraint_branch(trace, branch_index)
    signature = Dict{String,Bool}()
    for idx in eachindex(trace.branch_guards)
        guard = trace.branch_guards[idx]
        guard.path_constraint || continue
        if target !== nothing && idx > branch_index && branch_control_dependent_suffix(target, guard)
            continue
        end
        signature[guard.id] = idx == branch_index ? !guard.taken : guard.taken
    end
    return signature
end

function branch_signature_key(signature::AbstractDict)
    return join(
        [
            string(id) * "=" * (Bool(signature[id]) ? "1" : "0")
            for id in sort!(collect(keys(signature)), by=string)
        ],
        ";",
    )
end

function witness_execution_key(fault_vars::AbstractVector{Symbol},
    trace::ConcolicTrace,
    model::AbstractDict)

    return assignment_key(collect(Symbol, fault_vars), model) *
        "|branches=" * branch_signature_key(branch_signature(trace))
end

function branch_trace_hamming_distance(left::AbstractDict, right::AbstractDict)
    ids = union(Set(string.(keys(left))), Set(string.(keys(right))))
    distance = 0
    for id in ids
        if !haskey(left, id) || !haskey(right, id)
            distance += 1
        elseif Bool(left[id]) != Bool(right[id])
            distance += 1
        end
    end
    return distance
end

function witness_branch_distance(trace::ConcolicTrace,
    branch_index::Integer,
    witness_signatures::AbstractVector)

    isempty(witness_signatures) && return typemax(Int)
    candidate = branch_signature(trace; branch_index=branch_index)
    return minimum(
        witness_signature -> branch_trace_hamming_distance(candidate, witness_signature),
        witness_signatures,
    )
end

function witness_branch_priority_distance(trace::ConcolicTrace,
    branch_index::Integer,
    witness_signatures::AbstractVector)

    distance = witness_branch_distance(trace, branch_index, witness_signatures)
    distance == 0 && return typemax(Int)
    return distance == 1 ? 0 : 1
end

function branch_priority_score(failure_adjacent::Integer,
    syndrome_diverse::Integer,
    small_fault::Integer;
    weights::BranchPriorityWeights=DEFAULT_BRANCH_PRIORITY_WEIGHTS)

    return weights.failure_adjacent * failure_adjacent +
        weights.syndrome_diverse * syndrome_diverse +
        weights.small_fault * small_fault
end

branch_priority_syndrome_rank(weights::BranchPriorityWeights, syndrome_rank::Integer) =
    weights.syndrome_diverse == 0 ? 0 : Int(syndrome_rank)

branch_priority_fault_weight_rank(weights::BranchPriorityWeights, model_weight::Integer) =
    weights.small_fault == 0 ? 0 : Int(model_weight)

function fault_model_small_fault_feature(solver::AbstractConcolicSolver, fault_weight::Integer)
    max_weight = solver_max_weight(solver)
    max_weight === nothing && return -Int(fault_weight)
    return max(0, Int(max_weight) - Int(fault_weight))
end

function model_failure_adjacency_feature(distance::Integer)
    distance == typemax(Int) && return 0
    return max(0, 2 - Int(distance))
end

function branch_failure_adjacency_feature(distance::Integer)
    distance == 1 && return 1
    return 0
end

function syndrome_key_for_model(trace::ConcolicTrace, model::AbstractDict)
    names = sort!(collect(keys(trace.syndrome_exprs)))
    isempty(names) && return ""
    parts = String[]
    for name in names
        value = evaluate(trace.syndrome_exprs[name], model)
        push!(parts, name * "=" * (value ? "1" : "0"))
    end
    return join(parts, ",")
end

function priority_canonical_value(value)
    value === nothing && return "none"
    value isa AbstractDict && return join(
        [
            string(key, "=", priority_canonical_value(value[key]))
            for key in sort!(collect(keys(value)), by=string)
        ],
        ";",
    )
    value isa AbstractVector && return join(priority_canonical_value.(value), "|")
    value isa Bool && return value ? "true" : "false"
    return string(value)
end

priority_decoder_key(trace::ConcolicTrace) =
    isempty(trace.decoder_decisions) ? "none" :
    priority_canonical_value(get(trace.decoder_decisions, "actual", trace.decoder_decisions))

priority_recovery_key(trace::ConcolicTrace) =
    isempty(trace.recovery_actions) ? "none" :
    priority_canonical_value(trace.recovery_actions)

function priority_fault_key(trace::ConcolicTrace)
    active = String[]
    for var in trace.fault_vars
        model_bool(trace.fault_assignments, var) && push!(active, string(var))
    end
    sort!(active)
    return isempty(active) ? "<none>" : join(active, "+")
end

priority_fsdr_key(trace::ConcolicTrace) =
    string(syndrome_key(trace), "|", priority_decoder_key(trace), "|",
        priority_recovery_key(trace))

function priority_history_key(trace::ConcolicTrace)
    for key in ("syndrome_history_key", "control_state_key", "decoder_state_key")
        haskey(trace.metadata, key) && return string(trace.metadata[key])
    end
    haskey(trace.decoder_decisions, "observed_history") &&
        return string(trace.decoder_decisions["observed_history"])
    return "none"
end

struct CoveragePriorityState
    fsdr::Set{String}
    syndromes::Set{String}
    decoders::Set{String}
    recoveries::Set{String}
    branch_ids::Set{String}
    histories::Set{String}
end

function coverage_priority_state(traces::AbstractVector{ConcolicTrace})
    state = CoveragePriorityState(
        Set{String}(),
        Set{String}(),
        Set{String}(),
        Set{String}(),
        Set{String}(),
        Set{String}(),
    )
    for trace in traces
        push!(state.fsdr, priority_fsdr_key(trace))
        push!(state.syndromes, syndrome_key(trace))
        push!(state.decoders, priority_decoder_key(trace))
        push!(state.recoveries, priority_recovery_key(trace))
        history = priority_history_key(trace)
        history == "none" || push!(state.histories, history)
        for guard in trace.branch_guards
            push!(state.branch_ids, guard.id)
        end
    end
    return state
end

function coverage_priority_features(preview::Union{Nothing,ConcolicTrace},
    guard::BranchGuard, state::CoveragePriorityState)

    flags = Dict{String,Bool}(
        "unseen_fsdr_tuple" => false,
        "unseen_syndrome" => false,
        "unseen_decoder_output" => false,
        "unseen_recovery_action" => false,
        "unseen_branch_id" => !(guard.id in state.branch_ids),
        "unseen_round_history_state" => false,
    )
    preview === nothing && return flags
    flags["unseen_fsdr_tuple"] = !(priority_fsdr_key(preview) in state.fsdr)
    flags["unseen_syndrome"] = !(syndrome_key(preview) in state.syndromes)
    flags["unseen_decoder_output"] = !(priority_decoder_key(preview) in state.decoders)
    flags["unseen_recovery_action"] = !(priority_recovery_key(preview) in state.recoveries)
    history = priority_history_key(preview)
    flags["unseen_round_history_state"] =
        history != "none" && !(history in state.histories)
    return flags
end

const COVERAGE_PRIORITY_REASON_ORDER = [
    "unseen_fsdr_tuple",
    "unseen_syndrome",
    "unseen_decoder_output",
    "unseen_recovery_action",
    "unseen_branch_id",
    "unseen_round_history_state",
]

function coverage_priority_reason(flags::AbstractDict)
    for reason in COVERAGE_PRIORITY_REASON_ORDER
        Bool(get(flags, reason, false)) && return reason
    end
    return "low_fault_weight_tie_breaker"
end

coverage_priority_count(flags::AbstractDict) =
    count(reason -> Bool(get(flags, reason, false)), COVERAGE_PRIORITY_REASON_ORDER)

function annotate_coverage_priority!(metadata::AbstractDict, trace::ConcolicTrace,
    branch_index::Integer, result::SolverResult, preview,
    flags::AbstractDict, model_weight::Integer)

    guard = trace.branch_guards[branch_index]
    metadata["selected_branch_index"] = branch_index
    metadata["selected_branch_id"] = guard.id
    metadata["priority_profile"] = "coverage"
    metadata["priority_reason"] = coverage_priority_reason(flags)
    metadata["predicted_new_coverage"] = Dict{String,Any}(
        key => Bool(get(flags, key, false))
        for key in COVERAGE_PRIORITY_REASON_ORDER
    )
    metadata["predicted_new_coverage_count"] = coverage_priority_count(flags)
    metadata["predicted_fault_weight"] = model_weight
    metadata["predicted_stage"] = string(guard.stage)
    if preview !== nothing
        metadata["predicted_syndrome"] = syndrome_key(preview)
        metadata["predicted_decoder"] = priority_decoder_key(preview)
        metadata["predicted_recovery"] = priority_recovery_key(preview)
        metadata["predicted_fsdr_tuple"] = priority_fsdr_key(preview)
        metadata["predicted_round_history_state"] = priority_history_key(preview)
    end
    metadata["solver_status"] = solver_status_text(result.status)
    return metadata
end

function coverage_branch_priority_key(trace::ConcolicTrace, branch_index::Integer;
    solver,
    seen_inputs=Set{String}(),
    subject_runner=nothing,
    coverage_state=nothing,
    query_cache=nothing,
    preview_cache=nothing)

    guard = trace.branch_guards[branch_index]
    state = coverage_state === nothing ?
        coverage_priority_state(ConcolicTrace[trace]) : coverage_state
    result = if query_cache !== nothing && haskey(query_cache, branch_index)
        query_cache[branch_index]
    else
        solved = solve_branch_query(
            solver,
            trace,
            branch_index;
            avoid=seen_inputs,
            ordered_model=false,
        )
        query_cache === nothing || (query_cache[branch_index] = solved)
        solved
    end
    model = result.status == :sat ? result.model : nothing
    model === nothing && return (
        1, 1, 1, 1, 1, 1,
        stage_priority(guard.stage),
        typemax(Int),
        branch_index,
    )
    fault_vars = solver_fault_vars(solver)
    model_weight = model_fault_weight(fault_vars, model)
    preview = nothing
    if subject_runner !== nothing
        preview = if preview_cache !== nothing && haskey(preview_cache, branch_index)
            preview_cache[branch_index]
        else
            generated = subject_runner(model)
            preview_cache === nothing || (preview_cache[branch_index] = generated)
            generated
        end
    end
    flags = coverage_priority_features(preview, guard, state)
    annotate_coverage_priority!(
        result.metadata,
        trace,
        branch_index,
        result,
        preview,
        flags,
        model_weight,
    )
    return (
        Bool(flags["unseen_fsdr_tuple"]) ? 0 : 1,
        Bool(flags["unseen_syndrome"]) ? 0 : 1,
        Bool(flags["unseen_decoder_output"]) ? 0 : 1,
        Bool(flags["unseen_recovery_action"]) ? 0 : 1,
        Bool(flags["unseen_branch_id"]) ? 0 : 1,
        Bool(flags["unseen_round_history_state"]) ? 0 : 1,
        stage_priority(guard.stage),
        model_weight,
        branch_index,
    )
end

function branch_priority_key(trace::ConcolicTrace, branch_index::Integer,
    strategy::Symbol;
    solver=nothing,
    seen_syndromes=Set{String}(),
    seen_inputs=Set{String}(),
    witness_models=Dict{Symbol,Bool}[],
    witness_signatures=Dict{String,Bool}[],
    priority_weights=DEFAULT_BRANCH_PRIORITY_WEIGHTS,
    query_cache=nothing,
    priority_profile=:bugfinding,
    subject_runner=nothing,
    coverage_state=nothing,
    preview_cache=nothing)

    strategy == :trace_order && return (branch_index,)
    if priority_profile == :coverage && solver !== nothing
        return coverage_branch_priority_key(
            trace,
            branch_index;
            solver=solver,
            seen_inputs=seen_inputs,
            subject_runner=subject_runner,
            coverage_state=coverage_state,
            query_cache=query_cache,
            preview_cache=preview_cache,
        )
    end
    guard = trace.branch_guards[branch_index]
    failure_adjacent_stage_feature =
        guard.stage in (:logical_check, :recovery, :repeated_round_control, :decoder) ? 1 : 0
    if solver !== nothing
        result = if query_cache !== nothing && haskey(query_cache, branch_index)
            query_cache[branch_index]
        else
            solved = solve_branch_query(
                solver,
                trace,
                branch_index;
                avoid=seen_inputs,
                ordered_model=false,
            )
            query_cache === nothing || (query_cache[branch_index] = solved)
            solved
        end
        model = result.status == :sat ? result.model : nothing
        fault_vars = solver_fault_vars(solver)
        if model !== nothing
            predicted_syndrome = syndrome_key_for_model(trace, model)
            syndrome_rank = predicted_syndrome in seen_syndromes ? 1 : 0
            syndrome_feature = syndrome_rank == 0 ? 1 : 0
            model_weight = model_fault_weight(fault_vars, model)
            small_fault_feature = fault_model_small_fault_feature(solver, model_weight)
            ranked_syndrome = branch_priority_syndrome_rank(priority_weights, syndrome_rank)
            ranked_weight = branch_priority_fault_weight_rank(priority_weights, model_weight)
            if !isempty(witness_signatures)
                branch_distance = witness_branch_distance(trace, branch_index, witness_signatures)
                duplicate_rank = branch_distance == 0 ? 1 : 0
                score = branch_priority_score(
                    branch_failure_adjacency_feature(branch_distance),
                    syndrome_feature,
                    small_fault_feature;
                    weights=priority_weights,
                )
                return (
                    duplicate_rank,
                    -score,
                    ranked_syndrome,
                    ranked_weight,
                    branch_index,
                )
            elseif !isempty(witness_models)
                score = branch_priority_score(
                    model_failure_adjacency_feature(witness_distance(fault_vars, model, witness_models)),
                    syndrome_feature,
                    small_fault_feature;
                    weights=priority_weights,
                )
                return (
                    -score,
                    ranked_syndrome,
                    ranked_weight,
                    branch_index,
                )
            else
                score = branch_priority_score(
                    failure_adjacent_stage_feature,
                    syndrome_feature,
                    small_fault_feature;
                    weights=priority_weights,
                )
                return (
                    -score,
                    stage_priority(guard.stage),
                    ranked_syndrome,
                    ranked_weight,
                    branch_index,
                )
            end
        end
        if !isempty(witness_signatures)
            return (
                1,
                0,
                2,
                typemax(Int),
                branch_index,
            )
        elseif !isempty(witness_models)
            return (
                typemax(Int),
                2,
                typemax(Int),
                branch_index,
            )
        else
            return (
                stage_priority(guard.stage),
                2,
                typemax(Int),
                branch_index,
            )
        end
    end
    return (
        stage_priority(guard.stage),
        1,
        fault_weight(trace),
        branch_index,
    )
end

function path_branch_indices(trace::ConcolicTrace)
    return [idx for idx in eachindex(trace.branch_guards) if trace.branch_guards[idx].path_constraint]
end

function prioritized_branch_indices(trace::ConcolicTrace, strategy::Symbol;
    solver=nothing,
    seen_syndromes=Set{String}(),
    seen_inputs=Set{String}(),
    witness_models=Dict{Symbol,Bool}[],
    witness_signatures=Dict{String,Bool}[],
    priority_weights=DEFAULT_BRANCH_PRIORITY_WEIGHTS,
    query_cache=nothing,
    priority_profile=:bugfinding,
    subject_runner=nothing,
    coverage_state=nothing,
    preview_cache=nothing)

    indices = path_branch_indices(trace)
    sort!(
        indices,
        by=index -> branch_priority_key(
            trace,
            index,
            strategy;
            solver=solver,
            seen_syndromes=seen_syndromes,
            seen_inputs=seen_inputs,
            witness_models=witness_models,
            witness_signatures=witness_signatures,
            priority_weights=priority_weights,
            query_cache=query_cache,
            priority_profile=priority_profile,
            subject_runner=subject_runner,
            coverage_state=coverage_state,
            preview_cache=preview_cache,
        ),
    )
    return indices
end

function solve_branch_query_for_explore(solver::AbstractConcolicSolver,
    trace::ConcolicTrace,
    branch_index::Integer;
    avoid=Set{String}(),
    ordered_model=true)

    if solver isa Union{Z3Backend,BitwuzlaBackend,SolverChainBackend}
        return solve_branch_query(
            solver,
            trace,
            branch_index;
            avoid=avoid,
            ordered_model=ordered_model,
        )
    end
    return solve_branch_query(solver, trace, branch_index; avoid=avoid)
end

function branch_query_worker_solver(solver::AbstractConcolicSolver)
    fault_vars = solver_fault_vars(solver)
    applicable(solver_for_fault_vars, solver, fault_vars) || return nothing
    return solver_for_fault_vars(solver, fault_vars)
end

function branch_query_result_for_explore(solver::AbstractConcolicSolver,
    explorer::ConcolicExplorer,
    trace::ConcolicTrace,
    branch_index::Integer,
    query_cache::AbstractDict,
    seen_inputs::Set{String})

    ordered_model = explorer.branch_strategy == :qec_priority &&
        explorer.priority_profile != :coverage
    if haskey(query_cache, branch_index)
        cached = query_cache[branch_index]
        if explorer.priority_profile == :coverage || cached.status != :sat
            return cached
        end
    end
    return solve_branch_query_for_explore(
        solver,
        trace,
        branch_index;
        avoid=seen_inputs,
        ordered_model=ordered_model,
    )
end

function spawn_branch_query_task(f)
    if Threads.nthreads() > 1
        return Threads.@spawn f()
    end
    return @async f()
end

function solve_parallel_branch_queries_for_explore(explorer::ConcolicExplorer,
    trace::ConcolicTrace,
    ranked_branch_indices::Vector{Int},
    query_cache::AbstractDict)

    explorer.parallel_branches || return nothing
    explorer.parallel_branch_jobs > 1 || return nothing
    length(ranked_branch_indices) >= explorer.min_parallel_branch_batch_size ||
        return nothing
    branch_query_worker_solver(explorer.solver) === nothing && return nothing

    jobs = min(explorer.parallel_branch_jobs, length(ranked_branch_indices))
    seen_snapshot = Set{String}(explorer.seen_inputs)
    results = Vector{Union{Nothing,SolverResult}}(nothing, length(ranked_branch_indices))
    sem = Base.Semaphore(jobs)
    tasks = Task[]
    for (rank, branch_index) in enumerate(ranked_branch_indices)
        push!(
            tasks,
            spawn_branch_query_task() do
                Base.acquire(sem)
                try
                    solver = branch_query_worker_solver(explorer.solver)
                    solver === nothing && return nothing
                    result = branch_query_result_for_explore(
                        solver,
                        explorer,
                        trace,
                        branch_index,
                        query_cache,
                        seen_snapshot,
                    )
                    result.metadata["parallel_branch_query"] = "on"
                    result.metadata["parallel_branch_batch_size"] = length(ranked_branch_indices)
                    result.metadata["parallel_branch_jobs"] = jobs
                    result.metadata["parallel_branch_rank"] = rank
                    result.metadata["parallel_branch_avoid_snapshot_size"] =
                        length(seen_snapshot)
                    results[rank] = result
                    return nothing
                finally
                    Base.release(sem)
                end
            end,
        )
    end
    fetch.(tasks)
    any(result -> result === nothing, results) && return nothing
    return SolverResult[result for result in results if result !== nothing]
end

function branch_batch_indices(explorer::ConcolicExplorer, indices::Vector{Int})
    explorer.branch_batching || return indices
    limit = min(length(indices), explorer.max_branch_batch_size)
    return indices[1:limit]
end

function lazy_branch_priority_enabled(explorer::ConcolicExplorer,
    witness_models::AbstractVector,
    witness_signatures::AbstractVector)

    explorer.lazy_branch_priority || return false
    explorer.branch_strategy == :qec_priority || return false
    explorer.priority_profile == :bugfinding || return false
    isempty(witness_models) || return false
    isempty(witness_signatures) || return false
    return true
end

function explore!(explorer::ConcolicExplorer, subject_runner;
    witness_dir=joinpath(@__DIR__, "..", "artifacts", "witnesses"),
    stop_on_bug=true,
    minimize_witnesses=true,
    minimization_solver=nothing,
    max_witnesses=stop_on_bug ? 1 : typemax(Int),
    witness_uniqueness=:oracle)

    max_witnesses >= 1 || error("max_witnesses must be at least 1")
    witness_uniqueness in (:oracle, :execution) ||
        error("unsupported witness_uniqueness: $(witness_uniqueness)")
    traces = ConcolicTrace[]
    syndromes = Set{String}()
    witnesses = Dict{String,Any}[]
    witness_paths = String[]
    witness_models = Dict{Symbol,Bool}[]
    witness_model_keys = Set{String}()
    witness_signatures = Dict{String,Bool}[]
    witness_signature_keys = Set{String}()
    witness_execution_keys = Set{String}()
    relational_oracle_state = RelationalOracleState()

    while !isempty(explorer.worklist) && length(traces) < explorer.max_tests
        input = popfirst!(explorer.worklist)
        trace = subject_runner(input)
        input_key = assignment_key(explorer.fault_vars, input)
        if haskey(explorer.input_query_metadata, input_key)
            trace.metadata["input_solver_query"] = explorer.input_query_metadata[input_key]
        end
        apply_relational_oracles!(relational_oracle_state, trace, length(traces) + 1)
        push!(traces, trace)
        push!(syndromes, syndrome_key(trace))

        if trace_has_bug(trace)
            oracles = triggered_failure_oracles(trace)
            for (oracle_index, oracle) in enumerate(oracles)
                length(witnesses) >= max_witnesses && break
                exploration_settings = Dict{String,Any}(
                    "max_tests" => explorer.max_tests,
                    "max_fault_weight" => solver_max_weight(explorer.solver),
                    "stop_on_bug" => stop_on_bug,
                    "minimize_witnesses" => minimize_witnesses,
                    "max_witnesses" => max_witnesses,
                    "witness_uniqueness" => string(witness_uniqueness),
                    "witness_index" => length(witnesses) + 1,
                    "primary_oracle" => oracle["id"],
                    "solver_backend" => witness_solver_backend_name(explorer.solver),
                    "branch_strategy" => string(explorer.branch_strategy),
                    "priority_profile" => string(explorer.priority_profile),
                    "branch_batching" => explorer.branch_batching ? "on" : "off",
                    "batch_mode" => string(explorer.batch_mode),
                    "parallel_branches" => explorer.parallel_branches ? "on" : "off",
                    "lazy_branch_priority" =>
                        explorer.lazy_branch_priority ? "on" : "off",
                    "first_new_successor" =>
                        explorer.first_new_successor ? "on" : "off",
                    "min_parallel_branch_batch_size" =>
                        explorer.min_parallel_branch_batch_size,
                    "branch_priority_weights" => Dict{String,Any}(
                        "failure_adjacent" => explorer.priority_weights.failure_adjacent,
                        "syndrome_diverse" => explorer.priority_weights.syndrome_diverse,
                        "small_fault" => explorer.priority_weights.small_fault,
                    ),
                )
                if minimize_witnesses
                    witness, witness_trace = minimize_witness(
                        trace,
                        subject_runner;
                        exploration_settings=exploration_settings,
                        primary_oracle=oracle,
                        minimization_solver=minimization_solver,
                    )
                else
                    witness_trace = trace
                    witness = build_witness(
                        trace;
                        exploration_settings=exploration_settings,
                        primary_oracle=oracle,
                    )
                end
                model = normalize_assignment(explorer.fault_vars, witness_trace.fault_assignments)
                execution_key = witness_execution_key(
                    explorer.fault_vars,
                    witness_trace,
                    model,
                )
                if witness_uniqueness == :execution &&
                        execution_key in witness_execution_keys
                    continue
                end
                witness_path = joinpath(
                    witness_dir,
                    witness_file_name(
                        trace,
                        length(traces);
                        primary_oracle=oracle,
                        oracle_index=oracle_index,
                    ),
                )
                write_witness(witness_path, witness)
                push!(witnesses, witness)
                push!(witness_paths, witness_path)
                push!(witness_execution_keys, execution_key)
                key = assignment_key(explorer.fault_vars, model)
                if !(key in witness_model_keys)
                    push!(witness_model_keys, key)
                    push!(witness_models, model)
                end
                signature = branch_signature(witness_trace)
                signature_key = branch_signature_key(signature)
                if !(signature_key in witness_signature_keys)
                    push!(witness_signature_keys, signature_key)
                    push!(witness_signatures, signature)
                end
            end
            (stop_on_bug || length(witnesses) >= max_witnesses) && break
        end

        if explorer.first_new_successor &&
                length(traces) + length(explorer.worklist) >= explorer.max_tests
            continue
        end

        query_cache = Dict{Int,SolverResult}()
        preview_cache = Dict{Int,ConcolicTrace}()
        coverage_state = explorer.priority_profile == :coverage ?
            coverage_priority_state(traces) : nothing
        lazy_priority = lazy_branch_priority_enabled(
            explorer,
            witness_models,
            witness_signatures,
        )
        ranked_branch_indices = prioritized_branch_indices(
            trace,
            explorer.branch_strategy;
            solver=lazy_priority ? nothing : explorer.solver,
            seen_syndromes=syndromes,
            seen_inputs=explorer.seen_inputs,
            witness_models=witness_models,
            witness_signatures=witness_signatures,
            priority_weights=explorer.priority_weights,
            query_cache=query_cache,
            priority_profile=explorer.priority_profile,
            subject_runner=subject_runner,
            coverage_state=coverage_state,
            preview_cache=preview_cache,
        )
        ranked_branch_indices = branch_batch_indices(explorer, ranked_branch_indices)
        parallel_results = solve_parallel_branch_queries_for_explore(
            explorer,
            trace,
            ranked_branch_indices,
            query_cache,
        )
        for (branch_rank, branch_index) in enumerate(ranked_branch_indices)
            result = if parallel_results === nothing
                branch_query_result_for_explore(
                    explorer.solver,
                    explorer,
                    trace,
                    branch_index,
                    query_cache,
                    explorer.seen_inputs,
                )
            else
                parallel_results[branch_rank]
            end
            model = result.status == :sat ? result.model : nothing
            if parallel_results !== nothing && model !== nothing &&
                    assignment_key(explorer.fault_vars, model) in explorer.seen_inputs
                result = branch_query_result_for_explore(
                    explorer.solver,
                    explorer,
                    trace,
                    branch_index,
                    Dict{Int,SolverResult}(),
                    explorer.seen_inputs,
                )
                result.metadata["parallel_branch_query"] = "sequential-retry"
                result.metadata["parallel_branch_retry_reason"] = "duplicate-model"
                result.metadata["parallel_branch_batch_size"] = length(ranked_branch_indices)
                result.metadata["parallel_branch_jobs"] = explorer.parallel_branch_jobs
                model = result.status == :sat ? result.model : nothing
            end
            query_record = Dict{String,Any}(result.metadata)
            query_record["branch_index"] = branch_index
            query_record["branch_rank"] = branch_rank
            query_record["candidate_branch_count"] = length(path_branch_indices(trace))
            guard = trace.branch_guards[branch_index]
            query_record["selected_branch_id"] = guard.id
            query_record["selected_branch_stage"] = string(guard.stage)
            query_record["selected_branch_source"] = branch_control_group(guard)
            query_record["selected_branch_provenance"] = string(guard.source)
            query_record["branch_batching"] = explorer.branch_batching ? "on" : "off"
            query_record["batch_mode"] = string(explorer.batch_mode)
            query_record["parallel_branches"] = explorer.parallel_branches ? "on" : "off"
            query_record["lazy_branch_priority"] = lazy_priority ? "on" : "off"
            query_record["first_new_successor"] =
                explorer.first_new_successor ? "on" : "off"
            query_record["parallel_branch_jobs"] = explorer.parallel_branch_jobs
            query_record["min_parallel_branch_batch_size"] =
                explorer.min_parallel_branch_batch_size
            query_record["status"] = solver_status_text(result.status)
            push!(explorer.branch_query_results, query_record)
            model === nothing && continue
            enqueued = enqueue!(explorer, model; query_metadata=query_record)
            if lazy_priority && enqueued
                break
            elseif explorer.first_new_successor && enqueued &&
                    length(traces) + length(explorer.worklist) >= explorer.max_tests
                break
            end
        end
    end

    return ExplorationResult(
        traces,
        length(traces),
        syndromes,
        !isempty(witnesses),
        isempty(witnesses) ? nothing : first(witnesses),
        isempty(witness_paths) ? nothing : first(witness_paths),
        witnesses,
        witness_paths,
        copy(explorer.branch_query_results),
    )
end

function run_concolic(subject_runner, fault_vars::Vector{Symbol};
    initial=nothing,
    seeds=nothing,
    max_tests=32,
    max_fault_weight=1,
    branch_strategy=:qec_priority,
    priority_profile=:bugfinding,
    priority_weights=DEFAULT_BRANCH_PRIORITY_WEIGHTS,
    solver=BruteForceBoolSolver(fault_vars; max_weight=max_fault_weight),
    branch_batching=false,
    max_branch_batch_size=typemax(Int),
    batch_mode=priority_profile,
    parallel_branches=false,
    parallel_branch_jobs=1,
    min_parallel_branch_batch_size=2,
    lazy_branch_priority=false,
    first_new_successor=false,
    witness_dir=joinpath(@__DIR__, "..", "artifacts", "witnesses"),
    stop_on_bug=true,
    minimize_witnesses=true,
    minimization_solver=nothing,
    max_witnesses=stop_on_bug ? 1 : typemax(Int),
    witness_uniqueness=:oracle)

    max_witnesses >= 1 || error("max_witnesses must be at least 1")
    witness_uniqueness in (:oracle, :execution) ||
        error("unsupported witness_uniqueness: $(witness_uniqueness)")

    explorer = ConcolicExplorer(
        fault_vars;
        initial=initial,
        seeds=seeds,
        max_tests=max_tests,
        max_fault_weight=max_fault_weight,
        branch_strategy=branch_strategy,
        priority_profile=priority_profile,
        priority_weights=priority_weights,
        solver=solver,
        branch_batching=branch_batching,
        max_branch_batch_size=max_branch_batch_size,
        batch_mode=batch_mode,
        parallel_branches=parallel_branches,
        parallel_branch_jobs=parallel_branch_jobs,
        min_parallel_branch_batch_size=min_parallel_branch_batch_size,
        lazy_branch_priority=lazy_branch_priority,
        first_new_successor=first_new_successor,
    )
    return explore!(
        explorer,
        subject_runner;
        witness_dir=witness_dir,
        stop_on_bug=stop_on_bug,
        minimize_witnesses=minimize_witnesses,
        minimization_solver=minimization_solver,
        max_witnesses=max_witnesses,
        witness_uniqueness=witness_uniqueness,
    )
end
