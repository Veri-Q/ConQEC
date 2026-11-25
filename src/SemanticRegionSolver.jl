struct SemanticRegionQuery
    mode::Symbol
    guard::SemanticRegionGuard
    constraints::Vector{BoolExpr}
    fault_vars::Vector{Symbol}
    max_fault_weight::Union{Nothing,Int}
    avoid::Set{String}
    branch_id::Union{Nothing,String}
    metadata::Dict{String,Any}
end

struct SemanticRegionSolveResult
    status::Symbol
    model::Union{Nothing,Dict{Symbol,Bool}}
    active_faults::Vector{Int}
    query::SemanticRegionQuery
    solver_backend::String
    metadata::Dict{String,Any}
end

function active_set_key(active::AbstractVector{Int})
    return join(string.(sort(collect(Int, active))), ",")
end

function semantic_region_key_xor(left::AbstractString, right::AbstractString)
    length(left) == length(right) ||
        error("cannot xor observable keys with lengths $(length(left)) and $(length(right))")
    chars = Char[]
    for (a, b) in zip(left, right)
        (a == '0' || a == '1') && (b == '0' || b == '1') ||
            error("observable keys must be bitstrings")
        push!(chars, a == b ? '0' : '1')
    end
    return String(chars)
end

function semantic_region_fault_observable_key(model::DemParityModel, idx::Integer)
    return dem_parity_key(dem_logical_bits(model, Int[Int(idx)]))
end

function semantic_region_assignment(model::DemParityModel, active::AbstractVector{Int})
    return active_index_model(dem_fault_vars(model), active)
end

function semantic_region_direct_exact_observable_active(
    model::DemParityModel,
    target_key::AbstractString;
    max_fault_weight::Integer=1,
    seen_active_keys=Set{String}())

    target = semantic_region_canonical_observable_key(model, target_key)
    max_weight = max(Int(max_fault_weight), 0)
    if all(ch -> ch == '0', target)
        active = Int[]
        active_set_key(active) in seen_active_keys || return active
    end
    max_weight >= 1 || return nothing
    for idx in eachindex(model.faults)
        active = Int[idx]
        active_set_key(active) in seen_active_keys && continue
        semantic_region_fault_observable_key(model, idx) == target && return active
    end
    max_weight >= 2 || return nothing

    by_key = Dict{String,Vector{Int}}()
    for idx in eachindex(model.faults)
        key = semantic_region_fault_observable_key(model, idx)
        push!(get!(by_key, key, Int[]), idx)
    end
    for left_key in sort(collect(keys(by_key)))
        right_key = semantic_region_key_xor(target, left_key)
        haskey(by_key, right_key) || continue
        for left in by_key[left_key]
            for right in by_key[right_key]
                left < right || continue
                active = Int[left, right]
                active_set_key(active) in seen_active_keys && continue
                return active
            end
        end
    end
    return nothing
end

function semantic_region_direct_new_observable_active(
    model::DemParityModel,
    seen_keys::AbstractVector{String};
    max_fault_weight::Integer=1,
    seen_active_keys=Set{String}())

    seen = Set(semantic_region_canonical_observable_key(model, key) for key in seen_keys)
    max_weight = max(Int(max_fault_weight), 0)
    if !("0" ^ model.observable_count in seen)
        active = Int[]
        active_set_key(active) in seen_active_keys || return active
    end
    max_weight >= 1 || return nothing
    for idx in eachindex(model.faults)
        active = Int[idx]
        active_set_key(active) in seen_active_keys && continue
        key = semantic_region_fault_observable_key(model, idx)
        key in seen && continue
        return active
    end
    max_weight >= 2 || return nothing
    by_key = Dict{String,Vector{Int}}()
    for idx in eachindex(model.faults)
        key = semantic_region_fault_observable_key(model, idx)
        push!(get!(by_key, key, Int[]), idx)
    end
    keys_sorted = sort(collect(keys(by_key)))
    for (left_pos, left_key) in enumerate(keys_sorted)
        for right_key in keys_sorted[left_pos:end]
            key = semantic_region_key_xor(left_key, right_key)
            key in seen && continue
            left_values = by_key[left_key]
            right_values = by_key[right_key]
            active = if left_key == right_key
                length(left_values) >= 2 ? Int[left_values[1], left_values[2]] : nothing
            else
                Int[left_values[1], right_values[1]]
            end
            active === nothing && continue
            sort!(active)
            active_set_key(active) in seen_active_keys && continue
            return active
        end
    end
    return nothing
end

function semantic_region_direct_active(model::DemParityModel,
    guard::SemanticRegionGuard;
    max_fault_weight::Integer=1,
    seen_active_keys=Set{String}())

    if guard isa ObservableRegionGuard
        return semantic_region_direct_exact_observable_active(
            model,
            guard.key;
            max_fault_weight=max_fault_weight,
            seen_active_keys=seen_active_keys,
        )
    elseif guard isa NewObservableGuard
        return semantic_region_direct_new_observable_active(
            model,
            guard.seen_keys;
            max_fault_weight=max_fault_weight,
            seen_active_keys=seen_active_keys,
        )
    end
    return nothing
end

function build_pure_region_query(model::DemParityModel,
    guard::SemanticRegionGuard;
    max_fault_weight::Union{Nothing,Int}=1,
    avoid=Set{String}(),
    metadata=Dict{String,Any}())

    constraints = BoolExpr[guard_expr(model, guard)]
    return SemanticRegionQuery(
        :pure_region,
        guard,
        constraints,
        dem_fault_vars(model),
        max_fault_weight,
        Set{String}(avoid),
        nothing,
        merge(scheduler_visible_metadata(model, guard), Dict{String,Any}(metadata)),
    )
end

function build_branch_region_query(trace::ConcolicTrace,
    branch_index::Integer,
    model::DemParityModel,
    guard::SemanticRegionGuard;
    max_fault_weight::Union{Nothing,Int}=max_fault_weight(trace),
    avoid=Set{String}(),
    full_path::Bool=true,
    metadata=Dict{String,Any}())

    branch_constraints = branch_query_constraints(
        trace,
        branch_index;
        full_path=full_path,
        include_capacity=false,
    )
    constraints = BoolExpr[branch_constraints...]
    push!(constraints, guard_expr(model, guard))
    branch = require_path_constraint_branch(trace, branch_index)
    return SemanticRegionQuery(
        :branch_plus_region,
        guard,
        constraints,
        trace.fault_vars,
        max_fault_weight,
        Set{String}(avoid),
        branch.id,
        merge(scheduler_visible_metadata(model, guard), Dict{String,Any}(metadata)),
    )
end

function semantic_region_constraints_with_capacity(query::SemanticRegionQuery)
    return add_fault_capacity_constraint(
        query.constraints,
        query.fault_vars;
        max_weight=query.max_fault_weight,
    )
end

function solve_semantic_region_query(solver::AbstractConcolicSolver,
    model::DemParityModel,
    query::SemanticRegionQuery;
    prefer_direct::Bool=true)

    started = time()
    if prefer_direct && query.mode == :pure_region && query.max_fault_weight !== nothing
        active = semantic_region_direct_active(
            model,
            query.guard;
            max_fault_weight=query.max_fault_weight,
            seen_active_keys=Set{String}(),
        )
        if active !== nothing
            assignment = semantic_region_assignment(model, active)
            key = assignment_key(query.fault_vars, assignment)
            if !(key in query.avoid) && all(expr -> evaluate(expr, assignment), query.constraints)
                elapsed_ms = 1000.0 * (time() - started)
                return SemanticRegionSolveResult(
                    :sat,
                    assignment,
                    active,
                    query,
                    "direct-gf2-observable",
                    merge(
                        Dict{String,Any}(
                            "query_mode" => String(query.mode),
                            "solver_status" => "SAT",
                            "solve_time_ms" => elapsed_ms,
                            "gf2_variable_count" => length(query.fault_vars),
                            "gf2_equation_count" => query.guard isa ObservableRegionGuard ? model.observable_count : 0,
                            "pb_constraint_count" => 0,
                            "materialized_candidate_count" => length(active),
                            "cache_hit" => false,
                        ),
                        query.metadata,
                    ),
                )
            end
        end
    end

    constraints = semantic_region_constraints_with_capacity(query)
    result = solve_model(solver, constraints; avoid=query.avoid)
    elapsed_ms = 1000.0 * (time() - started)
    active = result.model === nothing ? Int[] : dem_active_indices(model, result.model)
    return SemanticRegionSolveResult(
        result.status,
        result.model,
        active,
        query,
        result.backend,
        merge(
            Dict{String,Any}(
                "query_mode" => String(query.mode),
                "solver_status" => solver_status_text(result.status),
                "solve_time_ms" => elapsed_ms,
                "gf2_variable_count" => length(query.fault_vars),
                "gf2_equation_count" => query.guard isa ObservableRegionGuard ? model.observable_count : 0,
                "pb_constraint_count" => query.max_fault_weight === nothing ? 0 : 1,
                "materialized_candidate_count" => 0,
                "cache_hit" => false,
            ),
            query.metadata,
            result.metadata,
        ),
    )
end
