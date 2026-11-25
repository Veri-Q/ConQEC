# Query cache helpers used by transparent solver-chain mode.

const SOLVER_CHAIN_QUERY_CACHE_VERSION = "conqec-solver-chain-query-cache-v1"

function query_cache_version()
    return SOLVER_CHAIN_QUERY_CACHE_VERSION
end

function solver_chain_cache_snapshot(solver::SolverChainBackend)
    counters = Dict{String,Any}(solver.cache.counters)
    counters["version"] = SOLVER_CHAIN_QUERY_CACHE_VERSION
    return Dict(
        "exact" => length(solver.cache.exact),
        "branch" => length(solver.cache.branch),
        "sat_model_samples" => length(solver.cache.sat_models),
        "unsat_samples" => length(solver.cache.unsat_sets),
        "partial_model_samples" => length(solver.cache.partial_models),
        "counters" => counters,
        "schema_version" => SOLVER_CHAIN_SCHEMA_VERSION,
    )
end

function solver_chain_cache_stats(solver::SolverChainBackend)
    return Dict{String,Any}(solver.cache.counters)
end

function solver_chain_cache_hit_rate(solver::SolverChainBackend)
    count = get(solver.cache.counters, "cache_hits", 0)
    total = get(solver.cache.counters, "cache_lookup", 0)
    if total == 0
        return 0.0
    end
    return round(100 * count / total; digits=3)
end

function solver_chain_cache_clear!(solver::SolverChainBackend)
    solver.cache = SolverResultCache()
    return solver
end

function query_cache_lookup(solver::SolverChainBackend, query::NormalizedQuery)
    return cache_lookup(solver, query)
end

function query_cache_store!(solver::SolverChainBackend, query::NormalizedQuery, result::SolverResult)
    return cache_store!(solver, query, result)
end
