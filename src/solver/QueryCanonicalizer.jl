# Query canonicalization helpers for solver-chain experiments.
#
# These helpers sit on top of the existing SolverPipeline normalization pipeline
# and provide a stable interface for phase-1/3 style metadata extraction and replay.

const SOLVER_CHAIN_QUERY_CANONICALIZER_VERSION = "conqec-solver-chain-canonicalizer-v1"

function query_smt_context(trace::ConcolicTrace)
    out = solver_chain_trace_context(trace)
    return Dict{String,Any}(
        "schema_version" => SOLVER_CHAIN_QUERY_CANONICALIZER_VERSION,
        "subject" => out["subject_id"],
        "subject_id" => out["subject_id"],
        "bug_id" => out["bug_id"],
        "seed" => out["seed"],
        "baseline" => out["baseline"],
    )
end

function canonicalize_branch_query(trace::ConcolicTrace, branch_index::Integer; kwargs...)
    return normalize_query(trace, branch_index; kwargs...)
end

function normalize_query_with_context(
    constraints::AbstractVector{<:BoolExpr},
    fault_vars::Vector{Symbol};
    subject="unknown",
    branch_id=nothing,
    branch_index=nothing,
    branch_stage=nothing,
    branch_expr_vars=Symbol[],
    max_fault_weight=nothing,
    construct_cache=true,
    context=nothing,
    avoid=Set{String}())

    metadata = Dict{String,Any}(
        "schema_version" => SOLVER_CHAIN_QUERY_CANONICALIZER_VERSION,
        "query_context" => true,
    )
    if context isa Dict
        for (k, v) in context
            metadata[k] = v
        end
    end
    return normalize_query(
        constraints,
        fault_vars;
        subject=subject,
        target_branch_id=branch_id,
        target_branch_index=branch_index,
        target_branch_stage=branch_stage,
        target_expr_vars=branch_expr_vars,
        max_fault_weight=max_fault_weight,
        construct_cache=construct_cache,
        metadata=metadata,
    )
end

function solver_chain_hash_components(query::NormalizedQuery)
    return Dict{String,String}(
        "schema_version" => SOLVER_CHAIN_QUERY_CANONICALIZER_VERSION,
        "full_query_hash" => query.hashes["full_query_hash"],
        "subject_hash" => query.hashes["subject_hash"],
        "subject_id_hash" => get(query.hashes, "subject_id_hash", ""),
        "bug_id_hash" => get(query.hashes, "bug_id_hash", ""),
        "seed_hash" => get(query.hashes, "seed_hash", ""),
        "baseline_hash" => get(query.hashes, "baseline_hash", ""),
        "capacity_hash" => query.hashes["capacity_hash"],
        "prefix_hash" => query.hashes["prefix_hash"],
        "branch_flip_hash" => query.hashes["branch_flip_hash"],
    )
end
