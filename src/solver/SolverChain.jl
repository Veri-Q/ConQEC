# SolverChain façade and compatibility entry points.

const SOLVER_CHAIN_VERSION = "conqec-solver-chain-v1"

function solver_chain_version()
    return SOLVER_CHAIN_VERSION
end

function solve_query_chain(solver::SolverChainBackend, query::ConstraintQuery)
    return solve_query(solver, query)
end

function solve_model_chain(
    solver::SolverChainBackend,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    return solve_model(solver, constraints; avoid=avoid)
end

function solve_chain(solver::SolverChainBackend, query::NormalizedQuery)
    return solve(solver, query)
end

function is_solver_chain_enabled(solver::SolverChainBackend)
    return solver_chain_enabled(solver)
end
