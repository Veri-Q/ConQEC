# SMT-construction cache helpers for query canonization and simplification.

const SOLVER_CHAIN_CONSTRUCT_CACHE_VERSION = "conqec-solver-chain-construct-cache-v1"

function construct_cache_version()
    return SOLVER_CHAIN_CONSTRUCT_CACHE_VERSION
end

function build_expr_construct_cache()
    return ExprConstructCache()
end

function cache_constructed_expr!(cache::ExprConstructCache, expr::BoolExpr)
    return hash_cons!(cache, expr)
end

function cached_constraint_key(constraint::BoolExpr)
    return canonical_expr_key(constraint)
end

function simplify_constraints_with_construct_cache(
    constraints::AbstractVector{<:BoolExpr};
    cache::ExprConstructCache=ExprConstructCache(),
    construct_cache::Bool=true)

    return canonicalize_constraints(
        constraints;
        construct_cache=Bool(construct_cache),
        cache=cache,
    )
end
