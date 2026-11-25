# Solver-chain validation helpers.

const SOLVER_CHAIN_VALIDATION_VERSION = "conqec-solver-chain-validation-v1"

function solver_chain_validation_version()
    return SOLVER_CHAIN_VALIDATION_VERSION
end

function validate_full_query(solver::SolverChainBackend, query::NormalizedQuery, model::AbstractDict)
    !solver.validate_model && return true
    return validate_model(query, model)
end

function validate_full_query(query::NormalizedQuery, model::AbstractDict)
    return validate_model(query, model)
end

function solver_chain_replay_result(query::NormalizedQuery, result::SolverResult)
    ok = result.status == :sat && result.model !== nothing && validate_full_query(query, result.model)
    return ok
end

function solver_chain_validate_metadata(query::NormalizedQuery, result::SolverResult)
    return Dict{String,Any}(
        "schema_version" => SOLVER_CHAIN_VALIDATION_VERSION,
        "query_full_hash" => query.hashes["full_query_hash"],
        "status_valid" => solver_chain_replay_result(query, result),
        "model_size" => result.model === nothing ? 0 : length(result.model),
    )
end
