const DEM_DENSE_SYNDROME_KEY_THRESHOLD = 4096

function dem_parity_key(bits::AbstractVector{Bool})
    isempty(bits) && return ""
    return join((bit ? "1" : "0" for bit in bits), "")
end

dem_use_sparse_syndrome_key(model::DemParityModel) =
    model.detector_count > DEM_DENSE_SYNDROME_KEY_THRESHOLD

function dem_sparse_support_key(prefix::AbstractString, support::AbstractVector{Int})
    isempty(support) && return String(prefix) * ":"
    return String(prefix) * ":" * join(string.(support), ",")
end

function dem_bits_from_support(width::Integer, support::AbstractVector{Int})
    bits = falses(max(Int(width), 0))
    for idx in support
        idx >= 0 || continue
        idx < length(bits) || continue
        bits[idx + 1] = true
    end
    return bits
end

function dem_support_from_bits(bits::AbstractVector{Bool})
    out = Int[]
    for (idx, bit) in enumerate(bits)
        bit || continue
        push!(out, idx - 1)
    end
    return out
end

function dem_syndrome_support(model::DemParityModel, active::AbstractVector{Int})
    support = Int[]
    for idx in active
        1 <= idx <= length(model.faults) || continue
        for detector in model.faults[idx].detector_support
            detector >= 0 || continue
            detector < model.detector_count || continue
            dem_toggle_support!(support, detector)
        end
    end
    sort!(support)
    return support
end

function dem_syndrome_key_from_support(model::DemParityModel,
    support::AbstractVector{Int})

    if dem_use_sparse_syndrome_key(model)
        return dem_sparse_support_key("D", support)
    end
    return dem_parity_key(dem_bits_from_support(model.detector_count, support))
end

function dem_syndrome_key(model::DemParityModel, active::AbstractVector{Int})
    return dem_syndrome_key_from_support(model, dem_syndrome_support(model, active))
end

function dem_syndrome_key(model::DemParityModel, bits::AbstractVector{Bool})
    if dem_use_sparse_syndrome_key(model)
        return dem_sparse_support_key("D", dem_support_from_bits(bits))
    end
    return dem_parity_key(bits)
end

dem_syndrome_key_encoding(model::DemParityModel) =
    dem_use_sparse_syndrome_key(model) ? "sparse_detector_indices" : "dense_bitstring"

dem_observable_key_encoding(model::DemParityModel) = "dense_bitstring"

function dem_active_indices(model::DemParityModel, assignment::AbstractDict)
    vars = dem_fault_vars(model)
    active = Int[]
    for (idx, var) in enumerate(vars)
        model_bool(assignment, var) && push!(active, idx)
    end
    return active
end

function dem_fault_weight(model::DemParityModel, assignment::AbstractDict)
    return length(dem_active_indices(model, assignment))
end

function dem_syndrome_bits(model::DemParityModel, active::AbstractVector{Int})
    return dem_bits_from_support(model.detector_count, dem_syndrome_support(model, active))
end

function dem_logical_bits(model::DemParityModel, active::AbstractVector{Int})
    bits = falses(model.observable_count)
    for idx in active
        1 <= idx <= length(model.faults) || continue
        for logical in model.faults[idx].logical_support
            logical >= 0 || continue
            logical < length(bits) || continue
            bits[logical + 1] = !bits[logical + 1]
        end
    end
    return bits
end

dem_syndrome_bits(model::DemParityModel, assignment::AbstractDict) =
    dem_syndrome_bits(model, dem_active_indices(model, assignment))

dem_logical_bits(model::DemParityModel, assignment::AbstractDict) =
    dem_logical_bits(model, dem_active_indices(model, assignment))

function dem_xor_expr(terms::AbstractVector{<:BoolExpr})
    expr = bconst(false)
    for term in terms
        expr = bxor(expr, term)
    end
    return expr
end

function dem_detector_supports(model::DemParityModel)
    supports = [Int[] for _ in 1:model.detector_count]
    for (idx, fault) in enumerate(model.faults)
        for detector in fault.detector_support
            detector >= 0 || continue
            detector < model.detector_count || continue
            push!(supports[detector + 1], idx)
        end
    end
    return supports
end

function dem_logical_supports(model::DemParityModel)
    supports = [Int[] for _ in 1:model.observable_count]
    for (idx, fault) in enumerate(model.faults)
        for logical in fault.logical_support
            logical >= 0 || continue
            logical < model.observable_count || continue
            push!(supports[logical + 1], idx)
        end
    end
    return supports
end

function dem_syndrome_exprs(model::DemParityModel)
    vars = dem_fault_vars(model)
    return [
        dem_xor_expr(BoolExpr[boolvar(vars[idx]) for idx in support])
        for support in dem_detector_supports(model)
    ]
end

function dem_projected_syndrome_exprs(model::DemParityModel, limit::Integer)
    vars = dem_fault_vars(model)
    n = min(max(Int(limit), 0), model.detector_count)
    supports = [Int[] for _ in 1:n]
    overflow_support = Set{Int}()
    for (idx, fault) in enumerate(model.faults)
        for detector in fault.detector_support
            detector >= 0 || continue
            detector < model.detector_count || continue
            if detector < n
                push!(supports[detector + 1], idx)
            else
                if idx in overflow_support
                    delete!(overflow_support, idx)
                else
                    push!(overflow_support, idx)
                end
            end
        end
    end
    exprs = [
        dem_xor_expr(BoolExpr[boolvar(vars[idx]) for idx in support])
        for support in supports
    ]
    if model.detector_count > n
        overflow = sort!(collect(overflow_support))
        push!(exprs, dem_xor_expr(BoolExpr[boolvar(vars[idx]) for idx in overflow]))
    end
    return exprs
end

function dem_projected_syndrome_bits(bits::AbstractVector{Bool}, limit::Integer)
    n = min(max(Int(limit), 0), length(bits))
    out = Bool[bits[idx] for idx in 1:n]
    if length(bits) > n
        push!(out, isodd(count(identity, @view bits[(n + 1):end])))
    end
    return out
end

function dem_logical_exprs(model::DemParityModel)
    vars = dem_fault_vars(model)
    return [
        dem_xor_expr(BoolExpr[boolvar(vars[idx]) for idx in support])
        for support in dem_logical_supports(model)
    ]
end

function dem_bits_equal_expr(exprs::AbstractVector{<:BoolExpr},
    bits::AbstractVector{Bool};
    max_bits::Integer=length(exprs))

    n = min(length(exprs), length(bits), Int(max_bits))
    terms = BoolExpr[]
    for idx in 1:n
        push!(terms, bits[idx] ? exprs[idx] : bnot(exprs[idx]))
    end
    return band(terms...)
end

function dem_xor_bits(left::AbstractVector{Bool}, right::AbstractVector{Bool})
    n = max(length(left), length(right))
    out = Vector{Bool}(undef, n)
    for idx in 1:n
        a = idx <= length(left) ? left[idx] : false
        b = idx <= length(right) ? right[idx] : false
        out[idx] = a != b
    end
    return out
end

function dem_expr_contains_or(expr::BoolExpr)
    expr isa BoolOr && return true
    expr isa BoolNot && return dem_expr_contains_or(expr.term)
    if expr isa BoolAnd
        return any(dem_expr_contains_or, expr.terms)
    elseif expr isa BoolXor || expr isa BoolEq
        return dem_expr_contains_or(expr.left) || dem_expr_contains_or(expr.right)
    end
    return false
end

function dem_encoding_uses_or(model::DemParityModel)
    # DEM parity subjects encode detector/logical relations as XORs of fault
    # variables. Avoid materializing and recursively traversing very large DEM
    # expression trees just to rediscover that no OR nodes are introduced here.
    return false
end

function dem_active_detector_list(bits::AbstractVector{Bool}; limit::Integer=64)
    active = Int[]
    for (idx, bit) in enumerate(bits)
        bit || continue
        length(active) >= limit && break
        push!(active, idx - 1)
    end
    return active
end
