function fault_weight(model::AbstractDict, fault_vars)
    vars = normalize_fault_vars(fault_vars)
    return count(var -> model_bool(model, var), vars)
end

function assignment_with_faults(fault_vars::Vector{Symbol}, active_indices::Vector{Int})
    model = zero_assignment(fault_vars)
    for idx in active_indices
        model[fault_vars[idx]] = true
    end
    return model
end

function append_fault_seed_combinations!(
    seeds::Vector{Dict{Symbol,Bool}},
    fault_vars::Vector{Symbol},
    active_indices::Vector{Int},
    start_index::Int,
    remaining::Int,
)
    if remaining == 0
        push!(seeds, assignment_with_faults(fault_vars, active_indices))
        return seeds
    end

    stop_index = length(fault_vars) - remaining + 1
    for idx in start_index:stop_index
        push!(active_indices, idx)
        append_fault_seed_combinations!(
            seeds,
            fault_vars,
            active_indices,
            idx + 1,
            remaining - 1,
        )
        pop!(active_indices)
    end
    return seeds
end

function generate_fault_seeds(fault_vars; max_fault_weight::Int=1, include_zero::Bool=true)
    max_fault_weight >= 0 ||
        error("max_fault_weight must be non-negative, got $(max_fault_weight)")

    vars = normalize_fault_vars(fault_vars)
    seeds = Dict{Symbol,Bool}[]

    include_zero && push!(seeds, zero_assignment(vars))
    max_weight = min(max_fault_weight, length(vars))
    for weight in 1:max_weight
        append_fault_seed_combinations!(seeds, vars, Int[], 1, weight)
    end

    return seeds
end
