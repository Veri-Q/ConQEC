# Persistent Z3 backend helper layer.

const SOLVER_CHAIN_PERSISTENT_Z3_VERSION = "conqec-solver-chain-persistent-z3-v1"

function persistent_z3_version()
    return SOLVER_CHAIN_PERSISTENT_Z3_VERSION
end

is_persistent_z3_backend(solver::AbstractConcolicSolver) = solver isa PersistentZ3Backend

is_persistent_z3_backend(::Any) = false

function persistent_z3_metadata(solver::PersistentZ3Backend)
    return merge(
        Dict{String,Any}(
            "schema_version" => SOLVER_CHAIN_PERSISTENT_Z3_VERSION,
            "backend_type" => "persistent-z3",
        ),
        persistent_z3_stats(solver),
    )
end

function persistent_z3_metadata(::AbstractConcolicSolver)
    return Dict{String,Any}(
        "schema_version" => SOLVER_CHAIN_PERSISTENT_Z3_VERSION,
        "backend_type" => "non-persistent",
    )
end

function persistent_z3_query_id(solver::PersistentZ3Backend)
    return solver.query_counter
end

function ensure_persistent_z3_fallback(solver::PersistentZ3Backend)
    return solver.io === nothing
end
