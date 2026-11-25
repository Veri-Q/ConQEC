const SOLVER_CHAIN_SCHEMA_VERSION = "conqec-solver-chain-v1"

mutable struct ExprConstructCache
    nodes::Dict{String,BoolExpr}
    hits::Int
    misses::Int
end

ExprConstructCache() = ExprConstructCache(Dict{String,BoolExpr}(), 0, 0)

struct NormalizedQuery
    constraints::Vector{BoolExpr}
    fault_vars::Vector{Symbol}
    avoid::Set{String}
    target_branch_id::Union{Nothing,String}
    target_branch_index::Union{Nothing,Int}
    target_branch_stage::Union{Nothing,String}
    target_expr_vars::Vector{Symbol}
    max_fault_weight::Union{Nothing,Int}
    hashes::Dict{String,String}
    canonical_constraints::Vector{String}
    metadata::Dict{String,Any}
end

struct SlicedQuery
    original::NormalizedQuery
    constraints::Vector{BoolExpr}
    fault_vars::Vector{Symbol}
    retained_vars::Vector{Symbol}
    dropped_constraint_count::Int
    original_constraint_count::Int
    hashes::Dict{String,String}
    metadata::Dict{String,Any}
end

struct PresolveResult
    status::Symbol
    model::Union{Nothing,Dict{Symbol,Bool}}
    reason::String
    metadata::Dict{String,Any}
end

struct ReplayResult
    success::Bool
    trace::Union{Nothing,ConcolicTrace}
    metadata::Dict{String,Any}
end

mutable struct SolverResultCache
    exact::Dict{String,SolverResult}
    branch::Dict{String,SolverResult}
    sat_models::Vector{Tuple{String,Dict{Symbol,Bool},Vector{String}}}
    unsat_sets::Vector{Tuple{Set{String},String,SolverResult}}
    partial_models::Dict{String,Dict{Symbol,Bool}}
    counters::Dict{String,Int}
end

function SolverResultCache()
    return SolverResultCache(
        Dict{String,SolverResult}(),
        Dict{String,SolverResult}(),
        Tuple{String,Dict{Symbol,Bool},Vector{String}}[],
        Tuple{Set{String},String,SolverResult}[],
        Dict{String,Dict{Symbol,Bool}}(),
        Dict{String,Int}(
            "cache_hits" => 0,
            "exact_hits" => 0,
            "branch_hits" => 0,
            "model_hits" => 0,
            "unsat_subsumption_hits" => 0,
            "partial_model_hits" => 0,
            "stale_hits_rejected" => 0,
            "validation_failures" => 0,
        ),
    )
end

mutable struct PersistentZ3Backend <: AbstractConcolicSolver
    delegate::Z3Backend
    io::Any
    lock::ReentrantLock
    query_counter::Int
    restart_counter::Int
    timeout_counter::Int
    fallback_counter::Int
    total_solve_ms::Float64
end

PersistentZ3Backend(delegate::Z3Backend) =
    PersistentZ3Backend(delegate, nothing, ReentrantLock(), 0, 0, 0, 0, 0.0)

function persistent_z3_stats(solver::PersistentZ3Backend)
    return Dict{String,Any}(
        "persistent_query_count" => solver.query_counter,
        "persistent_restarts" => solver.restart_counter,
        "persistent_timeouts" => solver.timeout_counter,
        "persistent_fallbacks" => solver.fallback_counter,
        "persistent_total_solve_ms" => solver.total_solve_ms,
    )
end

function persistent_z3_reset!(solver::PersistentZ3Backend)
    solver.query_counter = 0
    solver.restart_counter = 0
    solver.timeout_counter = 0
    solver.fallback_counter = 0
    solver.total_solve_ms = 0.0
    solver.io === nothing && return solver
    try
        close(solver.io)
    catch
    finally
        solver.io = nothing
    end
    return solver
end

function Base.close(solver::PersistentZ3Backend)
    solver.io === nothing && return nothing
    try
        close(solver.io)
    catch
    finally
        solver.io = nothing
    end
    return nothing
end

function persistent_base_backend(base::AbstractConcolicSolver, incremental::Bool)
    incremental && base isa Z3Backend && return PersistentZ3Backend(base)
    return base
end

mutable struct SolverChainBackend <: AbstractConcolicSolver
    fault_vars::Vector{Symbol}
    base::AbstractConcolicSolver
    mode::Symbol
    normalization::Bool
    slicing::Bool
    cache_enabled::Bool
    cache_mode::Symbol
    presolve_enabled::Bool
    incremental::Bool
    validate_model::Bool
    construct_cache::Bool
    solver_chain_log::Union{Nothing,String}
    query_profile::Union{Nothing,String}
    debug_export::Bool
    cache::SolverResultCache
end

function SolverChainBackend(base::AbstractConcolicSolver;
    mode=:transparent,
    normalization=true,
    slicing=true,
    cache=true,
    cache_mode=:validated,
    presolve=true,
    incremental=true,
    validate_model=true,
    construct_cache=true,
    solver_chain_log=nothing,
    query_profile=nothing,
    debug_export=false)

    mode_symbol = Symbol(mode)
    mode_symbol in (:off, :transparent, :generational) ||
        error("solver-chain mode must be :off, :transparent, or :generational")
    if mode_symbol == :generational
        @warn("Generational mode currently uses the transparent semantics path; " *
            "batch/parallel scheduling is deferred to a later phase.")
    end
    cache_mode_symbol = Symbol(cache_mode)
    cache_mode_symbol in (:exact, :validated) ||
        error("solver-chain cache_mode must be :exact or :validated")
    return SolverChainBackend(
        solver_fault_vars(base),
        persistent_base_backend(base, Bool(incremental)),
        mode_symbol,
        Bool(normalization),
        Bool(slicing),
        Bool(cache),
        cache_mode_symbol,
        Bool(presolve),
        Bool(incremental),
        Bool(validate_model),
        Bool(construct_cache),
        solver_chain_log === nothing ? nothing : String(solver_chain_log),
        query_profile === nothing ? nothing : String(query_profile),
        Bool(debug_export),
        SolverResultCache(),
    )
end

function SolverChainBackend(fault_vars::Vector{Symbol};
    mode=:transparent,
    backend="z3",
    solver_path=nothing,
    solver_timeout_ms=30000,
    max_weight=1,
    keep_query_files=false,
    query_dir=nothing,
    normalization=true,
    slicing=true,
    cache=true,
    cache_mode=:validated,
    presolve=true,
    incremental=true,
    validate_model=true,
    construct_cache=true,
    solver_chain_log=nothing,
    query_profile=nothing,
    debug_export=false)

    base = constraint_backend_from_name(
        fault_vars;
        backend=backend,
        solver_path=solver_path,
        solver_timeout_ms=solver_timeout_ms,
        max_weight=max_weight,
        keep_query_files=keep_query_files,
        query_dir=query_dir,
    )
    return SolverChainBackend(
        base;
        mode=mode,
        normalization=normalization,
        slicing=slicing,
        cache=cache,
        cache_mode=cache_mode,
        presolve=presolve,
        incremental=incremental,
        validate_model=validate_model,
        construct_cache=construct_cache,
        solver_chain_log=solver_chain_log,
        query_profile=query_profile,
        debug_export=debug_export,
    )
end

solver_name(solver::SolverChainBackend) =
    "solver-chain:" * solver_name(solver.base)

solver_name(::PersistentZ3Backend) = "persistent-z3"

solver_fault_vars(solver::PersistentZ3Backend) = solver_fault_vars(solver.delegate)

solver_max_weight(solver::PersistentZ3Backend) = solver_max_weight(solver.delegate)

solver_fault_vars(solver::SolverChainBackend) = copy(solver.fault_vars)

solver_max_weight(solver::SolverChainBackend) = solver_max_weight(solver.base)

function solver_chain_enabled(solver::SolverChainBackend)
    solver.mode != :off &&
        (solver.normalization || solver.slicing || solver.cache_enabled ||
            solver.presolve_enabled || solver.incremental)
end

function solver_chain_order_preserving_exact_cache(solver::SolverChainBackend)
    return solver.mode != :off &&
        solver.cache_enabled &&
        solver.cache_mode == :exact &&
        !solver.normalization &&
        !solver.slicing &&
        !solver.presolve_enabled &&
        !solver.incremental
end

function stable_hash(parts...)
    io = IOBuffer()
    for part in parts
        print(io, string(part))
        write(io, UInt8(0))
    end
    return bytes2hex(sha256(String(take!(io))))
end

function canonical_expr_key(expr::BoolExpr)
    if expr isa BoolVar
        return "var:" * string(expr.name)
    elseif expr isa BoolConst
        return expr.value ? "const:true" : "const:false"
    elseif expr isa BoolNot
        return "not(" * canonical_expr_key(expr.term) * ")"
    elseif expr isa BoolAnd
        terms = sort!(canonical_expr_key.(expr.terms))
        return "and(" * join(terms, ",") * ")"
    elseif expr isa BoolOr
        terms = sort!(canonical_expr_key.(expr.terms))
        return "or(" * join(terms, ",") * ")"
    elseif expr isa BoolXor
        terms = sort!([canonical_expr_key(expr.left), canonical_expr_key(expr.right)])
        return "xor(" * join(terms, ",") * ")"
    elseif expr isa BoolEq
        terms = sort!([canonical_expr_key(expr.left), canonical_expr_key(expr.right)])
        return "eq(" * join(terms, ",") * ")"
    end
    return string(typeof(expr), ":", expr_to_string(expr))
end

function hash_cons!(cache::ExprConstructCache, expr::BoolExpr)
    key = canonical_expr_key(expr)
    if haskey(cache.nodes, key)
        cache.hits += 1
        return cache.nodes[key]
    end
    cache.misses += 1
    cache.nodes[key] = expr
    return expr
end

function simplify_expr(expr::BoolExpr, cache::ExprConstructCache=ExprConstructCache())
    if expr isa BoolVar || expr isa BoolConst
        return hash_cons!(cache, expr)
    elseif expr isa BoolNot
        term = simplify_expr(expr.term, cache)
        term isa BoolConst && return hash_cons!(cache, bconst(!term.value))
        term isa BoolNot && return simplify_expr(term.term, cache)
        return hash_cons!(cache, BoolNot(term))
    elseif expr isa BoolAnd
        terms = BoolExpr[]
        for term in expr.terms
            simplified = simplify_expr(term, cache)
            if simplified isa BoolConst
                simplified.value || return hash_cons!(cache, bconst(false))
                continue
            elseif simplified isa BoolAnd
                append!(terms, simplified.terms)
            else
                push!(terms, simplified)
            end
        end
        isempty(terms) && return hash_cons!(cache, bconst(true))
        keyed = Dict{String,BoolExpr}()
        for term in terms
            keyed[canonical_expr_key(term)] = term
        end
        ordered = [keyed[key] for key in sort!(collect(keys(keyed)))]
        length(ordered) == 1 && return hash_cons!(cache, ordered[1])
        return hash_cons!(cache, BoolAnd(ordered))
    elseif expr isa BoolOr
        terms = BoolExpr[]
        for term in expr.terms
            simplified = simplify_expr(term, cache)
            if simplified isa BoolConst
                simplified.value && return hash_cons!(cache, bconst(true))
                continue
            elseif simplified isa BoolOr
                append!(terms, simplified.terms)
            else
                push!(terms, simplified)
            end
        end
        isempty(terms) && return hash_cons!(cache, bconst(false))
        keyed = Dict{String,BoolExpr}()
        for term in terms
            keyed[canonical_expr_key(term)] = term
        end
        ordered = [keyed[key] for key in sort!(collect(keys(keyed)))]
        length(ordered) == 1 && return hash_cons!(cache, ordered[1])
        return hash_cons!(cache, BoolOr(ordered))
    elseif expr isa BoolXor
        left = simplify_expr(expr.left, cache)
        right = simplify_expr(expr.right, cache)
        canonical_expr_key(left) == canonical_expr_key(right) &&
            return hash_cons!(cache, bconst(false))
        left isa BoolConst && !left.value && return hash_cons!(cache, right)
        right isa BoolConst && !right.value && return hash_cons!(cache, left)
        left isa BoolConst && left.value && return simplify_expr(BoolNot(right), cache)
        right isa BoolConst && right.value && return simplify_expr(BoolNot(left), cache)
        if canonical_expr_key(right) < canonical_expr_key(left)
            left, right = right, left
        end
        return hash_cons!(cache, BoolXor(left, right))
    elseif expr isa BoolEq
        left = simplify_expr(expr.left, cache)
        right = simplify_expr(expr.right, cache)
        canonical_expr_key(left) == canonical_expr_key(right) &&
            return hash_cons!(cache, bconst(true))
        left isa BoolConst && return simplify_expr(left.value ? right : BoolNot(right), cache)
        right isa BoolConst && return simplify_expr(right.value ? left : BoolNot(left), cache)
        if canonical_expr_key(right) < canonical_expr_key(left)
            left, right = right, left
        end
        return hash_cons!(cache, BoolEq(left, right))
    end
    return hash_cons!(cache, expr)
end

function canonicalize_constraints(constraints::AbstractVector{<:BoolExpr};
    construct_cache=true,
    cache=ExprConstructCache())

    keyed = Dict{String,BoolExpr}()
    before_nodes = length(constraints)
    for constraint in constraints
        simplified = if construct_cache
            simplify_expr(constraint, cache)
        else
            simplify_expr(constraint)
        end
        simplified isa BoolConst && simplified.value && continue
        key = canonical_expr_key(simplified)
        keyed[key] = simplified
    end
    keys_sorted = sort!(collect(keys(keyed)))
    return [keyed[key] for key in keys_sorted],
        keys_sorted,
        Dict{String,Any}(
        "nodes_before" => before_nodes,
        "nodes_after" => length(keys_sorted),
        "eliminated_constraints" => max(0, before_nodes - length(keys_sorted)),
        "hashcons_hits" => construct_cache ? cache.hits : 0,
        "hashcons_misses" => construct_cache ? cache.misses : 0,
    )
end

function avoid_hash(avoid::Set{String})
    return stable_hash("avoid", join(sort!(collect(avoid)), "\n"))
end

function solver_chain_trace_context(trace::ConcolicTrace)
    names = fieldnames(typeof(trace))
    read_field = function(trace, candidates::Vector{Symbol}, fallback::AbstractString)
        for key in candidates
            key in names || continue
            value = getfield(trace, key)
            value === nothing && continue
            return string(value)
        end
        return fallback
    end
    return Dict{String,String}(
        "subject_id" => read_field(trace, [:subject_name, :subject, :name], "unknown"),
        "bug_id" => read_field(trace, [:bug_id, :bug, :label], "none"),
        "seed" => read_field(trace, [:seed, :seed_id, :run_seed, :rng_seed], "none"),
        "baseline" => read_field(trace, [:baseline, :variant, :preset], "none"),
    )
end

function query_hashes(canonical_constraints::Vector{String},
    fault_vars::Vector{Symbol},
    avoid::Set{String};
    subject="unknown",
    prefix_key="",
    branch_key="",
    subject_id="unknown",
    bug_id="none",
    baseline="none",
    seed="none",
    max_fault_weight=nothing)

    subject_hash = stable_hash("subject", subject)
    subject_id_hash = stable_hash("subject-id", subject_id)
    bug_id_hash = stable_hash("bug-id", bug_id)
    baseline_hash = stable_hash("baseline", baseline)
    seed_hash = stable_hash("seed", seed)
    fault_model_hash = stable_hash("fault-vars", join(string.(fault_vars), ","))
    static_constraint_hash = stable_hash("constraints", join(canonical_constraints, "\n"))
    prefix_hash = stable_hash("prefix", prefix_key)
    branch_flip_hash = stable_hash("branch", branch_key)
    capacity_hash = stable_hash("capacity", max_fault_weight === nothing ? "none" : string(max_fault_weight))
    ahash = avoid_hash(avoid)
    full_query_hash = stable_hash(
        subject_hash,
        fault_model_hash,
        static_constraint_hash,
        prefix_hash,
        branch_flip_hash,
        capacity_hash,
        ahash,
        subject_id_hash,
        bug_id_hash,
        baseline_hash,
        seed_hash,
    )
    return Dict{String,String}(
        "subject_hash" => subject_hash,
        "subject_id_hash" => subject_id_hash,
        "bug_id_hash" => bug_id_hash,
        "baseline_hash" => baseline_hash,
        "seed_hash" => seed_hash,
        "fault_model_hash" => fault_model_hash,
        "static_constraint_hash" => static_constraint_hash,
        "prefix_hash" => prefix_hash,
        "branch_flip_hash" => branch_flip_hash,
        "capacity_hash" => capacity_hash,
        "avoid_hash" => ahash,
        "full_query_hash" => full_query_hash,
    )
end

function normalize_query(constraints::AbstractVector{<:BoolExpr},
    fault_vars::Vector{Symbol};
    avoid=Set{String}(),
    target_branch_id=nothing,
    target_branch_index=nothing,
    target_branch_stage=nothing,
    target_expr_vars=Symbol[],
    max_fault_weight=nothing,
    subject="unknown",
    prefix_key="",
    branch_key="",
    subject_id="unknown",
    bug_id="none",
    baseline="none",
    seed="none",
    construct_cache=true,
    metadata=Dict{String,Any}())

    start_ns = time_ns()
    expr_cache = ExprConstructCache()
    normalized_constraints, keys, simplification_metadata =
        canonicalize_constraints(constraints; cache=expr_cache, construct_cache=construct_cache)
    normalized_fault_vars = sort!(copy(fault_vars), by=string)
    normalized_avoid = Set{String}(String.(collect(avoid)))
    hashes = query_hashes(
        keys,
        normalized_fault_vars,
        normalized_avoid;
        subject=subject,
        prefix_key=prefix_key,
        branch_key=branch_key,
        subject_id=get(metadata, "subject_id", subject_id),
        bug_id=get(metadata, "bug_id", bug_id),
        baseline=get(metadata, "baseline", baseline),
        seed=get(metadata, "seed", seed),
        max_fault_weight=max_fault_weight,
    )
    elapsed_ms = (time_ns() - start_ns) / 1_000_000
    out_metadata = merge(
        Dict{String,Any}(
            "schema_version" => SOLVER_CHAIN_SCHEMA_VERSION,
            "normalization_time_ms" => round(elapsed_ms; digits=3),
            "normalization_enabled" => true,
            "construct_cache_enabled" => construct_cache,
        ),
        simplification_metadata,
        Dict{String,Any}(string(key) => value for (key, value) in metadata),
    )
    return NormalizedQuery(
        normalized_constraints,
        normalized_fault_vars,
        normalized_avoid,
        target_branch_id === nothing ? nothing : String(target_branch_id),
        target_branch_index === nothing ? nothing : Int(target_branch_index),
        target_branch_stage === nothing ? nothing : String(target_branch_stage),
        sort!(copy(Symbol.(target_expr_vars)), by=string),
        max_fault_weight === nothing ? nothing : Int(max_fault_weight),
        hashes,
        keys,
        out_metadata,
    )
end

function normalize_query(query::ConstraintQuery)
    hashes = Dict{String,String}(
        "subject_hash" => stable_hash("subject", get(query.metadata, "subject", "unknown")),
        "subject_id_hash" => stable_hash("subject-id", get(query.metadata, "subject_id", "unknown")),
        "bug_id_hash" => stable_hash("bug-id", get(query.metadata, "bug_id", "none")),
        "baseline_hash" => stable_hash("baseline", get(query.metadata, "baseline", "none")),
        "seed_hash" => stable_hash("seed", get(query.metadata, "seed", "none")),
        "fault_model_hash" => stable_hash("fault-vars", join(string.(query.fault_vars), ",")),
        "static_constraint_hash" => stable_hash("query-text", query.text),
        "prefix_hash" => stable_hash("prefix", get(query.metadata, "prefix_hash", "")),
        "branch_flip_hash" => stable_hash("branch", something(query.selected_branch_id, "")),
        "capacity_hash" => stable_hash("capacity", get(query.metadata, "max_fault_weight", "none")),
        "avoid_hash" => stable_hash("avoid", get(query.metadata, "avoid_count", 0)),
        "full_query_hash" => query.query_hash,
    )
    return NormalizedQuery(
        BoolExpr[],
        copy(query.fault_vars),
        Set{String}(),
        query.selected_branch_id,
        query.selected_branch_index,
        get(query.metadata, "selected_branch_stage", nothing),
        Symbol[],
        get(query.metadata, "max_fault_weight", nothing),
        hashes,
        String[query.query_hash],
        Dict{String,Any}(
            "schema_version" => SOLVER_CHAIN_SCHEMA_VERSION,
            "normalized_from_constraint_query" => true,
            "query_hash" => query.query_hash,
            "query_bytes" => query_bytes(query),
        ),
    )
end

function normalize_query(trace::ConcolicTrace, branch_index::Integer;
    avoid=Set{String}(),
    full_path=true,
    construct_cache=true)

    guard = require_path_constraint_branch(trace, branch_index)
    branch_expr_vars = expr_vars(guard.condition)
    constraints = branch_query_constraints(
        trace,
        branch_index;
        full_path=full_path,
        include_capacity=false,
    )
    trace_context = solver_chain_trace_context(trace)
    prefix_signature = branch_signature_key(branch_signature(trace; branch_index=branch_index))
    branch_key = string(guard.id, "=", guard.taken ? "0" : "1")
    return normalize_query(
        constraints,
        trace.fault_vars;
        avoid=avoid,
        target_branch_id=guard.id,
        target_branch_index=branch_index,
        target_branch_stage=guard.stage,
        target_expr_vars=branch_expr_vars,
        max_fault_weight=max_fault_weight(trace),
        subject=trace.subject_name,
        prefix_key=prefix_signature,
        branch_key=branch_key,
        construct_cache=construct_cache,
        subject_id=trace_context["subject_id"],
        bug_id=trace_context["bug_id"],
        baseline=trace_context["baseline"],
        seed=trace_context["seed"],
        metadata=Dict{String,Any}(
            "subject_id" => trace_context["subject_id"],
            "bug_id" => trace_context["bug_id"],
            "baseline" => trace_context["baseline"],
            "seed" => trace_context["seed"],
            "subject" => trace.subject_name,
            "query_role" => "generation",
            "selected_branch_stage" => string(guard.stage),
            "prefix_length" => branch_index,
            "candidate_branch_count" => length(path_branch_indices(trace)),
            "branch_id" => guard.id,
            "branch_index" => branch_index,
            "dependency_seed_vars" => string.(sort!(collect(branch_expr_vars), by=string)),
        ),
    )
end

function normalize_branch_query(trace::ConcolicTrace, branch_index::Integer; kwargs...)
    return normalize_query(trace, branch_index; kwargs...)
end

function slice_query(query::NormalizedQuery, target_branch=nothing)
    start_ns = time_ns()
    all_constraint_vars = [Set(expr_vars(constraint)) for constraint in query.constraints]
    retained = Set{Symbol}(dependency_slice_variables(query))
    changed = true
    while changed
        changed = false
        for vars in all_constraint_vars
            isempty(intersect(retained, vars)) && continue
            old_len = length(retained)
            union!(retained, vars)
            changed |= length(retained) != old_len
        end
    end

    sliced_constraints = BoolExpr[]
    dropped = 0
    for (constraint, vars) in zip(query.constraints, all_constraint_vars)
        if constraint isa BoolConst || !isempty(intersect(retained, vars))
            push!(sliced_constraints, constraint)
        else
            dropped += 1
        end
    end
    sliced_fault_vars = [var for var in query.fault_vars if var in retained]
    isempty(sliced_fault_vars) && (sliced_fault_vars = copy(query.fault_vars))
    sliced_keys = canonical_expr_key.(sliced_constraints)
    hashes = copy(query.hashes)
    hashes["slice_hash"] = stable_hash(
        "slice",
        query.hashes["full_query_hash"],
        join(sort!(copy(sliced_keys)), "\n"),
        join(string.(sliced_fault_vars), ","),
    )
    elapsed_ms = (time_ns() - start_ns) / 1_000_000
    original_count = length(query.constraints)
    ratio = original_count == 0 ? 1.0 : length(sliced_constraints) / original_count
    return SlicedQuery(
        query,
        sliced_constraints,
        sliced_fault_vars,
        sort!(collect(retained), by=string),
        dropped,
        original_count,
        hashes,
        Dict{String,Any}(
            "slice_time_ms" => round(elapsed_ms; digits=3),
            "original_constraints" => original_count,
            "sliced_constraints" => length(sliced_constraints),
            "original_vars" => length(query.fault_vars),
            "sliced_vars" => length(sliced_fault_vars),
            "slice_ratio" => round(ratio; digits=4),
            "slicing_fallback_reason" => "",
        ),
    )
end

function no_slice_query(query::NormalizedQuery)
    hashes = copy(query.hashes)
    hashes["slice_hash"] = query.hashes["full_query_hash"]
    return SlicedQuery(
        query,
        copy(query.constraints),
        copy(query.fault_vars),
        copy(query.fault_vars),
        0,
        length(query.constraints),
        hashes,
        Dict{String,Any}(
            "slice_time_ms" => 0.0,
            "original_constraints" => length(query.constraints),
            "sliced_constraints" => length(query.constraints),
            "original_vars" => length(query.fault_vars),
            "sliced_vars" => length(query.fault_vars),
            "slice_ratio" => 1.0,
            "slicing_fallback_reason" => "disabled",
        ),
    )
end

function extend_model(fault_vars::Vector{Symbol}, model::AbstractDict)
    out = Dict{Symbol,Bool}()
    for var in fault_vars
        out[var] = model_bool(model, var; default=false)
    end
    return out
end

function model_within_capacity(query::NormalizedQuery, model::AbstractDict)
    query.max_fault_weight === nothing && return true
    return model_fault_weight(query.fault_vars, model) <= query.max_fault_weight
end

function validate_model(query::NormalizedQuery, model::AbstractDict)
    full_model = extend_model(query.fault_vars, model)
    assignment_key(query.fault_vars, full_model) in query.avoid && return false
    model_within_capacity(query, full_model) || return false
    return all(constraint -> evaluate(constraint, full_model), query.constraints)
end

function projected_avoid(avoid::Set{String},
    full_fault_vars::Vector{Symbol},
    sliced_fault_vars::Vector{Symbol})

    isempty(avoid) && return Set{String}()
    out = Set{String}()
    for key in avoid
        assignments = Dict{Symbol,Bool}()
        for part in split(String(key), ';')
            isempty(part) && continue
            pieces = split(part, '='; limit=2)
            length(pieces) == 2 || continue
            assignments[Symbol(pieces[1])] = pieces[2] == "1"
        end
        all(var -> haskey(assignments, var), sliced_fault_vars) || continue
        push!(out, assignment_key(sliced_fault_vars, assignments))
    end
    return out
end

function presolve(query::SlicedQuery)
    return run_qecc_presolve(query)
end

presolve(query::NormalizedQuery) = presolve(no_slice_query(query))

function cache_counter!(cache::SolverResultCache, key::AbstractString)
    cache.counters[String(key)] = get(cache.counters, String(key), 0) + 1
    return cache.counters[String(key)]
end

function result_with_metadata(result::SolverResult, metadata::AbstractDict)
    merged = Dict{String,Any}(result.metadata)
    for (key, value) in metadata
        merged[string(key)] = value
    end
    return SolverResult(result.status, result.model, result.query_text, result.backend, merged)
end

function solver_chain_metadata(solver::SolverChainBackend, query::NormalizedQuery)
    return Dict{String,Any}(
        "schema_version" => SOLVER_CHAIN_SCHEMA_VERSION,
        "solver_chain" => "on",
        "solver_chain_mode" => string(solver.mode),
        "solver_chain_base_backend" => solver_name(solver.base),
        "normalization_enabled" => solver.normalization,
        "slicing_enabled" => solver.slicing,
        "cache_enabled" => solver.cache_enabled,
        "cache_mode" => string(solver.cache_mode),
        "presolver_enabled" => solver.presolve_enabled,
        "incremental_enabled" => solver.incremental,
        "validate_model" => solver.validate_model,
        "construct_cache" => solver.construct_cache,
        "solver_chain_log" => (solver.solver_chain_log === nothing ? nothing : solver.solver_chain_log),
        "query_profile" => (solver.query_profile === nothing ? nothing : solver.query_profile),
        "persistent_backend" => solver.base isa PersistentZ3Backend ? "z3-stdin" :
            (solver.incremental ? "requested-command-fallback" : "disabled"),
        "persistent_query_count" => solver.base isa PersistentZ3Backend ?
            solver.base.query_counter : 0,
        "persistent_restarts" => solver.base isa PersistentZ3Backend ?
            solver.base.restart_counter : 0,
        "persistent_timeouts" => solver.base isa PersistentZ3Backend ?
            solver.base.timeout_counter : 0,
        "persistent_fallbacks" => solver.base isa PersistentZ3Backend ?
            solver.base.fallback_counter : 0,
        "full_query_hash" => query.hashes["full_query_hash"],
        "subject_hash" => query.hashes["subject_hash"],
        "fault_model_hash" => query.hashes["fault_model_hash"],
        "static_constraint_hash" => query.hashes["static_constraint_hash"],
        "prefix_hash" => query.hashes["prefix_hash"],
        "branch_flip_hash" => query.hashes["branch_flip_hash"],
        "capacity_hash" => query.hashes["capacity_hash"],
        "avoid_hash" => query.hashes["avoid_hash"],
        "subject_id_hash" => query.hashes["subject_id_hash"],
        "bug_id_hash" => query.hashes["bug_id_hash"],
        "baseline_hash" => query.hashes["baseline_hash"],
        "seed_hash" => query.hashes["seed_hash"],
    )
end

function cache_lookup(solver::SolverChainBackend, query::NormalizedQuery)
    solver.cache_enabled || return nothing
    cache = solver.cache
    cache_counter!(cache, "cache_lookup")
    full_hash = query.hashes["full_query_hash"]
    if haskey(cache.exact, full_hash)
        cache_counter!(cache, "cache_hits")
        cache_counter!(cache, "exact_hits")
        return result_with_metadata(
            cache.exact[full_hash],
            Dict{String,Any}("cache_hit" => true, "cache_hit_kind" => "exact"),
        )
    end
    solver.cache_mode == :exact && return nothing
    branch_key = stable_hash(
        "branch-cache",
        query.hashes["prefix_hash"],
        query.hashes["branch_flip_hash"],
        query.hashes["capacity_hash"],
        query.hashes["avoid_hash"],
    )
    if haskey(cache.branch, branch_key)
        cached = cache.branch[branch_key]
        if cached.status != :sat || (cached.model !== nothing && validate_model(query, cached.model))
            cache_counter!(cache, "cache_hits")
            cache_counter!(cache, "branch_hits")
            return result_with_metadata(
                cached,
                Dict{String,Any}("cache_hit" => true, "cache_hit_kind" => "branch"),
            )
        end
        cache_counter!(cache, "stale_hits_rejected")
    end
    for (_, model, _) in cache.sat_models
        if validate_model(query, model)
            cache_counter!(cache, "cache_hits")
            cache_counter!(cache, "model_hits")
            result = SolverResult(
                :sat,
                extend_model(query.fault_vars, model),
                nothing,
                solver_name(solver),
                Dict{String,Any}(
                    "backend" => solver_name(solver),
                    "solver_status" => "SAT",
                    "cache_hit" => true,
                    "cache_hit_kind" => "model",
                    "solve_time_ms" => 0.0,
                ),
            )
            return result
        end
    end
    query_set = Set(query.canonical_constraints)
    for (unsat_set, capacity_hash, result) in cache.unsat_sets
        capacity_hash == query.hashes["capacity_hash"] || continue
        if issubset(unsat_set, query_set)
            cache_counter!(cache, "cache_hits")
            cache_counter!(cache, "unsat_subsumption_hits")
            return result_with_metadata(
                result,
                Dict{String,Any}("cache_hit" => true, "cache_hit_kind" => "unsat-subsumption"),
            )
        end
    end
    return nothing
end

function cache_store!(solver::SolverChainBackend, query::NormalizedQuery, result::SolverResult)
    solver.cache_enabled || return result
    full_hash = query.hashes["full_query_hash"]
    solver.cache.exact[full_hash] = result
    branch_key = stable_hash(
        "branch-cache",
        query.hashes["prefix_hash"],
        query.hashes["branch_flip_hash"],
        query.hashes["capacity_hash"],
        query.hashes["avoid_hash"],
    )
    if solver.cache_mode != :exact
        solver.cache.branch[branch_key] = result
        if result.status == :sat && result.model !== nothing
            push!(
                solver.cache.sat_models,
                (full_hash, extend_model(query.fault_vars, result.model), copy(query.canonical_constraints)),
            )
        elseif result.status == :unsat
            push!(
                solver.cache.unsat_sets,
                (Set(query.canonical_constraints), query.hashes["capacity_hash"], result),
            )
        end
    end
    return result
end

function exact_constraint_query_cache_lookup(solver::SolverChainBackend, query::ConstraintQuery)
    solver.cache_enabled || return nothing
    cache_counter!(solver.cache, "cache_lookup")
    if haskey(solver.cache.exact, query.query_hash)
        cache_counter!(solver.cache, "cache_hits")
        cache_counter!(solver.cache, "exact_hits")
        return result_with_metadata(
            solver.cache.exact[query.query_hash],
            Dict{String,Any}(
                "cache_hit" => true,
                "cache_hit_kind" => "exact",
                "order_preserving_query_cache" => true,
            ),
        )
    end
    return nothing
end

function exact_constraint_query_cache_store!(solver::SolverChainBackend,
    query::ConstraintQuery,
    result::SolverResult)

    solver.cache_enabled || return result
    solver.cache.exact[query.query_hash] = result
    return result
end

function order_preserving_cache_metadata(solver::SolverChainBackend, query::ConstraintQuery)
    return Dict{String,Any}(
        "schema_version" => SOLVER_CHAIN_SCHEMA_VERSION,
        "solver_chain" => "on",
        "solver_chain_mode" => string(solver.mode),
        "solver_chain_base_backend" => solver_name(solver.base),
        "normalization_enabled" => false,
        "slicing_enabled" => false,
        "cache_enabled" => solver.cache_enabled,
        "cache_mode" => string(solver.cache_mode),
        "presolver_enabled" => false,
        "incremental_enabled" => false,
        "validate_model" => solver.validate_model,
        "construct_cache" => false,
        "order_preserving_query_cache" => true,
        "full_query_hash" => query.query_hash,
        "query_hash" => query.query_hash,
        "query_bytes" => query_bytes(query),
    )
end

function solve_order_preserving_cached_query(solver::SolverChainBackend,
    query::ConstraintQuery)

    cached = exact_constraint_query_cache_lookup(solver, query)
    cached !== nothing && return cached
    result = solve_query(solver.base, query)
    final = result_with_metadata(result, order_preserving_cache_metadata(solver, query))
    return exact_constraint_query_cache_store!(solver, query, final)
end

function solver_for_fault_vars(solver::LocalEnumeratorBackend, fault_vars::Vector{Symbol})
    return LocalEnumeratorBackend(fault_vars; max_weight=solver.max_weight)
end

function solver_for_fault_vars(solver::SMTLibExportBackend, fault_vars::Vector{Symbol})
    return SMTLibExportBackend(fault_vars; logic=solver.logic, include_get_model=solver.include_get_model)
end

function solver_for_fault_vars(solver::ExternalSmtSolver, fault_vars::Vector{Symbol})
    return ExternalSmtSolver(fault_vars; command=solver.command, args=solver.args, logic=solver.logic)
end

function solver_for_fault_vars(solver::Z3Backend, fault_vars::Vector{Symbol})
    return Z3Backend(
        fault_vars;
        solver_path=solver.solver_path,
        args=solver.args,
        logic=solver.logic,
        timeout_ms=solver.timeout_ms,
        max_weight=solver.max_weight,
        keep_query_files=solver.keep_query_files,
        query_dir=solver.query_dir,
    )
end

function solver_for_fault_vars(solver::PersistentZ3Backend, fault_vars::Vector{Symbol})
    return PersistentZ3Backend(solver_for_fault_vars(solver.delegate, fault_vars))
end

function solver_for_fault_vars(solver::BitwuzlaBackend, fault_vars::Vector{Symbol})
    return BitwuzlaBackend(
        fault_vars;
        solver_path=solver.solver_path,
        args=solver.args,
        logic=solver.logic,
        timeout_ms=solver.timeout_ms,
        max_weight=solver.max_weight,
        keep_query_files=solver.keep_query_files,
        query_dir=solver.query_dir,
    )
end

function solver_for_fault_vars(solver::SolverChainBackend, fault_vars::Vector{Symbol})
    return SolverChainBackend(
        solver_for_fault_vars(solver.base, fault_vars);
        mode=solver.mode,
        normalization=solver.normalization,
        slicing=solver.slicing,
        cache=solver.cache_enabled,
        cache_mode=solver.cache_mode,
        presolve=solver.presolve_enabled,
        incremental=solver.incremental,
        validate_model=solver.validate_model,
        construct_cache=solver.construct_cache,
        solver_chain_log=solver.solver_chain_log,
        query_profile=solver.query_profile,
        debug_export=solver.debug_export,
    )
end

function persistent_z3_io(solver::PersistentZ3Backend)
    solver.io === nothing || return solver.io
    args = String["-in"]
    append!(args, solver.delegate.args)
    try
        solver.io = open(Cmd([solver.delegate.solver_path; args]), "r+")
    catch
        solver.fallback_counter += 1
        rethrow()
    end
    return solver.io
end

function solve_query(backend::PersistentZ3Backend, query::ConstraintQuery)
    lock(backend.lock)
    try
        backend.query_counter += 1
        sentinel = "__CONQEC_END_" * string(backend.query_counter) * "__"
        start_ns = time_ns()
        output_text = ""
        backend.total_solve_ms += 0.0
        try
            io = persistent_z3_io(backend)
            write(io, "(reset)\n")
            write(io, query.text)
            write(io, "\n(echo \"", sentinel, "\")\n")
            flush(io)
            lines = String[]
            while true
                line = readline(io)
                strip(line) == sentinel && break
                push!(lines, line)
            end
            output_text = join(lines, "\n") * "\n"
        catch err
            backend.io = nothing
            backend.restart_counter += 1
            backend.fallback_counter += 1
            fallback = solve_query(backend.delegate, query)
            fallback.metadata["persistent_backend"] = "fallback-command-line"
            fallback.metadata["persistent_error"] = sprint(showerror, err)
            return fallback
        end
        elapsed_ms = (time_ns() - start_ns) / 1_000_000
        backend.total_solve_ms += elapsed_ms
        if output_text === ""
            backend.fallback_counter += 1
        end
        status = :error
        model = nothing
        parse_error = nothing
        try
            status, model = parse_model(output_text, query.variable_map)
        catch err
            parse_error = sprint(showerror, err)
        end
        status == :timeout && (backend.timeout_counter += 1)
        metadata = Dict{String,Any}(
            "backend" => solver_name(backend),
            "solver_path" => backend.delegate.solver_path,
            "solver_version" => solver_version(backend.delegate.solver_path),
            "query_file_path" => nothing,
            "query_hash" => query.query_hash,
            "query_bytes" => query_bytes(query),
            "fault_variable_count" => query.fault_variable_count,
            "syndrome_variable_count" => query.syndrome_variable_count,
            "branch_constraint_count" => query.branch_constraint_count,
            "selected_branch_id" => query.selected_branch_id,
            "selected_branch_index" => query.selected_branch_index,
            "solver_status" => solver_status_text(status),
            "solve_time_ms" => round(Float64(elapsed_ms); digits=3),
            "timed_out" => false,
            "timeout_ms" => backend.delegate.timeout_ms,
            "solver_args" => ["-in"; backend.delegate.args],
            "persistent_backend" => "z3-stdin",
            "replay_success" => nothing,
        )
        parse_error === nothing || (metadata["parse_error"] = parse_error)
        if model !== nothing
            metadata["parsed_model"] = Dict{String,Any}(
                string(var) => model_bool(model, var)
                for var in query.variable_map
            )
            metadata["generated_concrete_fault_pattern"] =
                model_to_fault_pattern(query.fault_vars, model)
        end
        return SolverResult(status, model, query.text, solver_name(backend), metadata)
    finally
        unlock(backend.lock)
    end
end

function solve_model(
    solver::PersistentZ3Backend,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    constraints_with_capacity = add_fault_capacity_constraint(
        constraints,
        solver_fault_vars(solver);
        max_weight=solver_max_weight(solver),
    )
    query = build_query(
        constraints_with_avoidance(solver_fault_vars(solver), constraints_with_capacity, avoid),
        nothing,
        solver_fault_vars(solver),
        Dict{String,Any}("logic" => solver_logic(solver.delegate), "include_get_model" => true),
    )
    return solve_query(solver, query)
end

function solve_constraints_with_backend(
    backend::AbstractConcolicSolver,
    constraints::Vector{BoolExpr},
    fault_vars::Vector{Symbol};
    avoid=Set{String}())

    local_backend = solver_fault_vars(backend) == fault_vars ?
        backend :
        solver_for_fault_vars(backend, fault_vars)
    return solve_model(local_backend, constraints; avoid=avoid)
end

function solve_normalized_with_backend(
    solver::SolverChainBackend,
    query::NormalizedQuery,
    sliced::SlicedQuery)

    avoid = projected_avoid(query.avoid, query.fault_vars, sliced.fault_vars)
    result = solve_constraints_with_backend(
        solver.base,
        sliced.constraints,
        sliced.fault_vars;
        avoid=avoid,
    )
    if result.status == :sat && result.model !== nothing
        model = extend_model(query.fault_vars, result.model)
        return SolverResult(result.status, model, result.query_text, result.backend, result.metadata)
    end
    return result
end

function solve_full_query_with_backend(
    solver::SolverChainBackend,
    query::NormalizedQuery)

    return solve_constraints_with_backend(
        solver.base,
        query.constraints,
        query.fault_vars;
        avoid=query.avoid,
    )
end

function solve_result_profile_path!(path::AbstractString, row::AbstractDict)
    mkpath(dirname(path))
    open(path, "a") do io
        println(io, compact_json_string(row))
    end
    return nothing
end

function log_solver_chain_result(
    solver::SolverChainBackend,
    event::AbstractString,
    query::NormalizedQuery,
    result::SolverResult)

    payload = merge(
        Dict{String,Any}(
            "schema_version" => SOLVER_CHAIN_SCHEMA_VERSION,
            "event" => event,
            "query_hash" => query.hashes["full_query_hash"],
            "solver_chain_mode" => string(solver.mode),
            "status" => string(result.status),
            "cache_hit" => get(result.metadata, "cache_hit", false),
            "cache_hit_kind" => get(result.metadata, "cache_hit_kind", "none"),
            "solver_status" => string(get(result.metadata, "solver_status", result.status)),
            "solve_time_ms" => get(result.metadata, "solve_time_ms", 0.0),
            "slicing_enabled" => solver.slicing,
            "presolve_enabled" => solver.presolve_enabled,
            "construct_cache_enabled" => solver.construct_cache,
            "validate_model" => solver.validate_model,
            "validate_model_enabled" => get(result.metadata, "validate_model_enabled", true),
            "full_query_hash" => query.hashes["full_query_hash"],
            "subject_hash" => query.hashes["subject_hash"],
            "subject_id_hash" => query.hashes["subject_id_hash"],
            "bug_id_hash" => query.hashes["bug_id_hash"],
            "seed_hash" => query.hashes["seed_hash"],
            "baseline_hash" => query.hashes["baseline_hash"],
            "avoid_count" => length(query.avoid),
            "normalized_constraint_count" => length(query.constraints),
            "normalized_variable_count" => length(query.fault_vars),
        ),
        Dict{String,Any}(result.metadata),
    )
    solver.solver_chain_log === nothing || solve_result_profile_path!(solver.solver_chain_log, payload)
    solver.query_profile === nothing || solve_result_profile_path!(solver.query_profile, payload)
    return nothing
end

function solver_result_from_presolve(
    solver::SolverChainBackend,
    query::NormalizedQuery,
    model::Dict{Symbol,Bool},
    metadata::AbstractDict)

    full_model = extend_model(query.fault_vars, model)
    return SolverResult(
        :sat,
        full_model,
        nothing,
        solver_name(solver),
        merge(
            Dict{String,Any}(
                "backend" => solver_name(solver),
                "solver_status" => "SAT",
                "solve_time_ms" => 0.0,
                "query_hash" => query.hashes["full_query_hash"],
                "fault_variable_count" => length(query.fault_vars),
                "query_bytes" => 0,
                "generated_concrete_fault_pattern" =>
                    model_to_fault_pattern(query.fault_vars, full_model),
            ),
            Dict{String,Any}(metadata),
        ),
    )
end

function solve(solver::SolverChainBackend, query::NormalizedQuery)
    cached = cache_lookup(solver, query)
    if cached !== nothing
        log_solver_chain_result(solver, "cache-hit", query, cached)
        return cached
    end

    chain_metadata = merge(solver_chain_metadata(solver, query), query.metadata)
    sliced = dependency_slice_query(query; enabled=solver.slicing)
    merge!(chain_metadata, sliced.metadata)

    if solver.presolve_enabled && !(solver.base isa SMTLibExportBackend)
        presolved = presolve(sliced)
        merge!(chain_metadata, presolved.metadata)
        if presolved.status == :sat && presolved.model !== nothing
            candidate = extend_model(query.fault_vars, presolved.model)
            if !solver.validate_model || validate_model(query, candidate)
                result = solver_result_from_presolve(solver, query, candidate, chain_metadata)
                final = cache_store!(solver, query, result)
                log_solver_chain_result(solver, "presolve-hit", query, final)
                return final
            end
            cache_counter!(solver.cache, "validation_failures")
            chain_metadata["presolver_validation_failed"] = true
        elseif presolved.status == :unsat && sliced.dropped_constraint_count == 0
            result = SolverResult(
                :unsat,
                nothing,
                nothing,
                solver_name(solver),
                merge(
                    Dict{String,Any}(
                        "backend" => solver_name(solver),
                        "solver_status" => "UNSAT",
                        "solve_time_ms" => 0.0,
                        "query_hash" => query.hashes["full_query_hash"],
                    ),
                    chain_metadata,
                ),
            )
            final = cache_store!(solver, query, result)
            log_solver_chain_result(solver, "satisfiable-shortcut", query, final)
            return final
        end
    end

    result = solve_normalized_with_backend(solver, query, sliced)
    if result.status == :sat && result.model !== nothing
        if !solver.validate_model || validate_model(query, result.model)
            final = result_with_metadata(result, chain_metadata)
            final = cache_store!(solver, query, final)
            log_solver_chain_result(solver, "backend-hit", query, final)
            return final
        end
        cache_counter!(solver.cache, "validation_failures")
        chain_metadata["slice_validation_failed"] = true
        chain_metadata["slicing_fallback_reason"] = "full-query-validation-failed"
    elseif result.status == :unsat && sliced.dropped_constraint_count > 0
        chain_metadata["slicing_fallback_reason"] = "sliced-unsat-requires-full-check"
    else
        final = result_with_metadata(result, chain_metadata)
        final = cache_store!(solver, query, final)
        log_solver_chain_result(solver, "backend-hit", query, final)
        return final
    end

    full_result = solve_full_query_with_backend(solver, query)
    final = result_with_metadata(
        full_result,
        merge(chain_metadata, Dict{String,Any}("fallback_to_full_query" => true)),
    )
    final = cache_store!(solver, query, final)
    log_solver_chain_result(solver, "full-query-fallback", query, final)
    return final
end

function solve_query(backend::SolverChainBackend, query::ConstraintQuery)
    if solver_chain_order_preserving_exact_cache(backend)
        return solve_order_preserving_cached_query(backend, query)
    end
    if !solver_chain_enabled(backend)
        result = solve_query(backend.base, query)
        return result_with_metadata(
            result,
            Dict{String,Any}(
                "solver_chain" => "on",
                "solver_chain_base_backend" => solver_name(backend.base),
                "solver_chain_optimizations" => "disabled",
            ),
        )
    end
    normalized = normalize_query(query)
    if !backend.validate_model
        normalized.metadata["validate_model_enabled"] = false
    end
    cached = cache_lookup(backend, normalized)
    if cached !== nothing
        log_solver_chain_result(backend, "cache-hit", normalized, cached)
        return cached
    end
    result = solve_query(backend.base, query)
    final = result_with_metadata(result, solver_chain_metadata(backend, normalized))
    final = cache_store!(backend, normalized, final)
    log_solver_chain_result(backend, "backend-query", normalized, final)
    return final
end

function solve_model(
    solver::SolverChainBackend,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    if solver_chain_order_preserving_exact_cache(solver)
        constraints_with_capacity = add_fault_capacity_constraint(
            constraints,
            solver_fault_vars(solver);
            max_weight=solver_max_weight(solver),
        )
        query = build_query(
            constraints_with_avoidance(solver_fault_vars(solver), constraints_with_capacity, avoid),
            nothing,
            solver_fault_vars(solver),
            Dict{String,Any}("logic" => solver_chain_query_logic(solver), "include_get_model" => true),
        )
        return solve_order_preserving_cached_query(solver, query)
    end

    if !solver_chain_enabled(solver)
        result = solve_model(solver.base, constraints; avoid=avoid)
        return result_with_metadata(
            result,
            Dict{String,Any}(
                "solver_chain" => "on",
                "solver_chain_base_backend" => solver_name(solver.base),
                "solver_chain_optimizations" => "disabled",
            ),
        )
    end
    normalized = normalize_query(
        constraints,
        solver.fault_vars;
        avoid=avoid,
        max_fault_weight=solver_max_weight(solver),
        construct_cache=solver.construct_cache,
        metadata=Dict{String,Any}("query_role" => "generation"),
    )
    return solve(solver, normalized)
end

function solver_query_text(
    solver::SolverChainBackend,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    return solver_query_text(solver.base, constraints; avoid=avoid)
end

function solver_chain_query_logic(solver::SolverChainBackend)
    solver.base isa PersistentZ3Backend && return solver_logic(solver.base.delegate)
    solver.base isa Union{Z3Backend,BitwuzlaBackend} && return solver_logic(solver.base)
    return "QF_BV"
end

function ordered_single_fault_model_result(
    solver::SolverChainBackend,
    trace::ConcolicTrace,
    branch_index::Integer,
    avoid,
    result::SolverResult)

    result.status == :sat || return result
    result.model === nothing && return result
    solver_max_weight(solver) == 1 || return result

    current_active = findfirst(var -> model_bool(result.model, var), trace.fault_vars)
    current_active === nothing && return result

    for idx in 1:(current_active - 1)
        extra_constraints = BoolExpr[boolvar(trace.fault_vars[idx])]
        for previous in 1:(idx - 1)
            push!(extra_constraints, bnot(boolvar(trace.fault_vars[previous])))
        end
        constraints = branch_query_constraints(trace, branch_index; include_capacity=false)
        append!(constraints, extra_constraints)
        candidate = solve_model(solver, constraints; avoid=avoid)
        candidate.status == :sat || continue
        candidate.metadata["model_selection"] = "ordered_single_fault_preference"
        candidate.metadata["model_selection_original_active_fault"] =
            string(trace.fault_vars[current_active])
        candidate.metadata["model_selection_selected_fault"] =
            string(trace.fault_vars[idx])
        return candidate
    end
    return result
end

function solve_branch_query(solver::SolverChainBackend,
    trace::ConcolicTrace,
    branch_index::Integer;
    avoid=Set{String}(),
    ordered_model=true)

    if solver_chain_order_preserving_exact_cache(solver)
        ensure_branch_solver_fault_vars(solver, trace)
        query = build_query(
            trace,
            branch_index;
            include_get_model=true,
            logic=solver_chain_query_logic(solver),
            avoid=avoid,
        )
        result = solve_order_preserving_cached_query(solver, query)
        ordered_model || return result
        return ordered_single_fault_model_result(solver.base, trace, branch_index, avoid, result)
    end

    if !solver_chain_enabled(solver)
        result = solve_branch_query(
            solver.base,
            trace,
            branch_index;
            avoid=avoid,
            ordered_model=ordered_model,
        )
        return result_with_metadata(
            result,
            Dict{String,Any}(
                "solver_chain" => "on",
                "solver_chain_base_backend" => solver_name(solver.base),
                "solver_chain_optimizations" => "disabled",
            ),
        )
    end
    ensure_branch_solver_fault_vars(solver, trace)
    normalized = normalize_query(trace, branch_index; avoid=avoid, construct_cache=solver.construct_cache)
    result = solve(solver, normalized)
    result.metadata["selected_branch_index"] = branch_index
    result.metadata["selected_branch_id"] = trace.branch_guards[branch_index].id
    result.metadata["branch_rank"] = branch_index
    result.metadata["query_role"] = get(result.metadata, "query_role", "generation")
    ordered_model || return result
    return ordered_single_fault_model_result(solver, trace, branch_index, avoid, result)
end

function replay_fault(subject, fault::AbstractDict)
    try
        trace = run_subject(subject, fault)
        return ReplayResult(
            true,
            trace,
            Dict{String,Any}(
                "replay_success" => true,
                "subject" => subject_name(subject),
                "diagnostic_contract_match" => true,
            ),
        )
    catch err
        return ReplayResult(
            false,
            nothing,
            Dict{String,Any}(
                "replay_success" => false,
                "replay_error" => sprint(showerror, err),
            ),
        )
    end
end

function query_hash_breakdown(query::NormalizedQuery)
    out = Dict{String,Any}(query.hashes)
    out["canonical_constraints"] = copy(query.canonical_constraints)
    out["target_branch_id"] = query.target_branch_id
    out["target_branch_index"] = query.target_branch_index
    out["target_branch_stage"] = query.target_branch_stage
    out["fault_vars"] = string.(query.fault_vars)
    out["avoid_count"] = length(query.avoid)
    return out
end
