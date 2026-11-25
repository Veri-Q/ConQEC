# Dependency slicing helpers for transparent solver-chain execution.

const SOLVER_CHAIN_DEPENDENCY_SLICER_VERSION = "conqec-solver-chain-dependency-slicer-v1"

function dependency_slicer_version()
    return SOLVER_CHAIN_DEPENDENCY_SLICER_VERSION
end

function _collect_symbols_for_dependency_slicing(value)
    if value isa Symbol
        return Set([value])
    end
    if value isa AbstractString
        return Set(Symbol(strip(item)) for item in split(value, ',') if !isempty(strip(item)))
    end
    if value isa AbstractVector || value isa AbstractSet || value isa Tuple
        out = Set{Symbol}()
        for item in value
            for item_symbol in _collect_symbols_for_dependency_slicing(item)
                push!(out, item_symbol)
            end
        end
        return out
    end
    if value isa AbstractDict
        out = Set{Symbol}()
        for item in values(value)
            for item_symbol in _collect_symbols_for_dependency_slicing(item)
                push!(out, item_symbol)
            end
        end
        return out
    end
    if value isa AbstractFloat || value isa Integer || value isa Bool || value === nothing
        return Set{Symbol}()
    end
    return Set{Symbol}()
end

function dependency_slice_variables(query::NormalizedQuery)
    seed = Set{Symbol}(query.target_expr_vars)
    for key in (
        "dependency_seed_vars",
        "target_expr_vars",
        "branch_expr_vars",
        "syndrome_seed_vars",
        "decoder_guard_vars",
        "recovery_guard_vars",
        "slice_seed_vars",
        "slice_seed",
    )
        haskey(query.metadata, key) || continue
        for symbol_value in _collect_symbols_for_dependency_slicing(query.metadata[key])
            push!(seed, symbol_value)
        end
    end
    if isempty(seed)
        return sort!(collect(query.fault_vars), by=string)
    end
    return sort!(collect(seed), by=string)
end

function dependency_slicing_enabled(solver::SolverChainBackend)
    return Bool(solver.slicing)
end

function dependency_slice_enabled(query::NormalizedQuery, enabled::Bool)
    return Bool(enabled)
end

function dependency_slice_query(
    query::NormalizedQuery;
    enabled::Bool=true,
    target_branch=nothing)

    if !enabled
        return no_slice_query(query)
    end
    return slice_query(query, target_branch)
end

function dependency_slice_result(query::NormalizedQuery, sliced::SlicedQuery)
    return Dict{String,Any}(
        "version" => SOLVER_CHAIN_DEPENDENCY_SLICER_VERSION,
        "schema_version" => SOLVER_CHAIN_SCHEMA_VERSION,
        "original_var_count" => length(query.fault_vars),
        "sliced_var_count" => length(sliced.fault_vars),
        "original_constraint_count" => length(query.constraints),
        "sliced_constraint_count" => length(sliced.constraints),
        "dropped_constraint_count" => sliced.dropped_constraint_count,
        "slice_ratio" => sliced.metadata["slice_ratio"],
        "slice_time_ms" => sliced.metadata["slice_time_ms"],
        "slicing_fallback_reason" => get(sliced.metadata, "slicing_fallback_reason", "none"),
    )
end
