# QECC-specific pre-solver façade.

const SOLVER_CHAIN_QECC_PRESOLVER_VERSION = "conqec-solver-chain-qecc-presolver-v1"

struct _QeccLinearConstraint
    vars::Set{Symbol}
    rhs::Bool
    active::Bool
end

function qec_presolver_version()
    return SOLVER_CHAIN_QECC_PRESOLVER_VERSION
end

function qec_presolve_status(result::PresolveResult)
    return result.status
end

function qec_presolve_metadata(result::PresolveResult)
    metadata = Dict{String,Any}(
        "schema_version" => SOLVER_CHAIN_QECC_PRESOLVER_VERSION,
        "version" => SOLVER_CHAIN_QECC_PRESOLVER_VERSION,
        "presolve_status" => string(result.status),
        "presolver_reason" => result.reason,
    )
    for (key, value) in result.metadata
        metadata[string(key)] = value
    end
    return metadata
end

function _qec_vars_set(fault_vars::Vector{Symbol})
    return Set{Symbol}(fault_vars)
end

function qec_presolve_supported(query::NormalizedQuery)
    return qec_presolve_supported(no_slice_query(query))
end

function qec_presolve_supported(query::SlicedQuery)
    _, parsed_status, _ = _qec_parse_linear_rows(query)
    return parsed_status == :ok
end

function run_qecc_presolve(query::NormalizedQuery)
    return run_qecc_presolve(no_slice_query(query))
end

function run_qecc_presolve(query::SlicedQuery)
    start_ns = time_ns()
    parsed = _qec_parse_linear_rows(query)
    start_status = parsed[2]
    if start_status == :unsupported
        return PresolveResult(
            :unsupported,
            nothing,
            "qec-presolve-unsupported-expression-shape",
            Dict{String,Any}(
                "presolver_eligible" => false,
                "presolver_strategy" => "linear-gf2-presolve",
                "presolver_reason_detail" => "query_contains-nonlinear-expression",
            ),
        )
    end
    if start_status == :unsat
        elapsed_ms = (time_ns() - start_ns) / 1_000_000
        return PresolveResult(
            :unsat,
            nothing,
            "qec-presolve-linear-contradiction",
            Dict{String,Any}(
                "presolver_eligible" => true,
                "presolver_status" => "UNSAT",
                "presolver_time_ms" => round(elapsed_ms; digits=3),
                "presolver_strategy" => "linear-gf2-presolve",
                "presolver_reason_detail" => "linear-system-inconsistent",
            ),
        )
    end

    rows = parsed[3]
    nvar = length(query.fault_vars)
    if nvar == 0
        return PresolveResult(
            :sat,
            Dict{Symbol,Bool}(),
            "qec-presolve-empty-variable-space",
            Dict{String,Any}(
                "presolver_eligible" => true,
                "presolver_status" => "SAT",
                "presolver_time_ms" => 0.0,
                "presolver_strategy" => "linear-gf2-presolve",
                "z3_calls_avoided" => 1,
                "presolver_row_count" => 0,
            ),
        )
    end

    coeffs, rhs = _qec_matrix_from_rows(query.fault_vars, rows)
    coeff_copy = [copy(row) for row in coeffs]
    rhs_copy = copy(rhs)
    consistent, pivots = _qec_eliminate_linear_system!(coeff_copy, rhs_copy, nvar)

    if !consistent
        elapsed_ms = (time_ns() - start_ns) / 1_000_000
        return PresolveResult(
            :unsat,
            nothing,
            "qec-presolve-linear-unsat",
            Dict{String,Any}(
                "presolver_eligible" => true,
                "presolver_status" => "UNSAT",
                "presolver_time_ms" => round(elapsed_ms; digits=3),
                "presolver_strategy" => "linear-gf2-presolve",
                "presolver_reason_detail" => "linear-solver-inconsistent",
            ),
        )
    end

    max_weight = query.original.max_fault_weight
    candidate = _qec_find_weight_bounded_model(
        coeff_copy,
        rhs_copy,
        pivots,
        nvar,
        query.fault_vars,
        max_weight,
    )
    if candidate === nothing
        elapsed_ms = (time_ns() - start_ns) / 1_000_000
        return PresolveResult(
            :unsat,
            nothing,
            "qec-presolve-bounded-search-empty",
            Dict{String,Any}(
                "presolver_eligible" => true,
                "presolver_status" => "UNSAT",
                "presolver_time_ms" => round(elapsed_ms; digits=3),
                "presolver_strategy" => "linear-gf2-presolve",
                "presolver_reason_detail" => "bounded-search-empty",
            ),
        )
    end

    model_bits, model = candidate
    for constraint in query.constraints
        _qec_is_compatible_constraint(constraint, model) || return PresolveResult(
            :unsupported,
            nothing,
            "qec-presolve-unsupported-expression-shape",
            Dict{String,Any}(
                "presolver_eligible" => false,
                "presolver_status" => "UNSUPPORTED",
                "presolver_strategy" => "linear-gf2-presolve",
                "presolver_reason_detail" => "constraint-replay-failed",
            ),
        )
    end

    elapsed_ms = (time_ns() - start_ns) / 1_000_000
    return PresolveResult(
        :sat,
        model,
        "qec-presolve-sat",
        Dict{String,Any}(
            "presolver_eligible" => true,
            "presolver_status" => "SAT",
            "presolver_time_ms" => round(elapsed_ms; digits=3),
            "presolver_strategy" => "linear-gf2-presolve",
            "presolver_row_count" => length(rows),
            "presolver_pivot_count" => length(pivots),
            "z3_calls_avoided" => 1,
            "qec_model_weight" => count(model_bits),
        ),
    )
end

function _qec_parse_linear_rows(query::SlicedQuery)
    allowed = _qec_vars_set(query.fault_vars)
    constraints = query.constraints
    parsed = _QeccLinearConstraint[]
    for constraint in constraints
        row = _qec_parse_constraint(constraint, allowed)
        row === nothing && return (nothing, :unsupported, _QeccLinearConstraint[])
        row.active || continue
        if isempty(row.vars)
            row.rhs && return (nothing, :unsat, _QeccLinearConstraint[])
            continue
        end
        push!(parsed, row)
    end
    return (nothing, :ok, parsed)
end

function _qec_parse_constraint(expr::BoolExpr, allowed::Set{Symbol})
    expr isa BoolConst && return _qec_parse_bool_const(expr)
    if expr isa BoolEq
        linear = _qec_parse_eq(expr.left, expr.right, allowed)
        linear === nothing && return nothing
        return _QeccLinearConstraint(linear[1], linear[2], true)
    end
    if expr isa BoolNot && expr.term isa BoolEq
        linear = _qec_parse_eq(expr.term.left, expr.term.right, allowed)
        linear === nothing && return nothing
        return _QeccLinearConstraint(linear[1], !linear[2], true)
    end
    linear = _qec_parse_linear_expr(expr, allowed)
    linear === nothing && return nothing
    vars, constant = linear
    return _QeccLinearConstraint(vars, !constant, true)
end

function _qec_parse_bool_const(expr::BoolConst)
    if expr.value
        return _QeccLinearConstraint(Set{Symbol}(), false, false)
    end
    return _QeccLinearConstraint(Set{Symbol}(), true, true)
end

function _qec_parse_eq(lhs_expr::BoolExpr, rhs_expr::BoolExpr, allowed::Set{Symbol})
    lhs = _qec_parse_linear_expr(lhs_expr, allowed)
    rhs = _qec_parse_linear_expr(rhs_expr, allowed)
    lhs === nothing && return nothing
    rhs === nothing && return nothing
    lhs_vars, lhs_const = lhs
    rhs_vars, rhs_const = rhs
    vars = _qec_xor_vars(copy(lhs_vars), rhs_vars)
    rhs_value = lhs_const != rhs_const
    return (vars, rhs_value)
end

function _qec_parse_linear_expr(expr::BoolExpr, allowed::Set{Symbol})
    expr isa BoolVar && return (_qec_linear_vars(expr, allowed))
    expr isa BoolConst && return (Set{Symbol}(), expr.value)
    expr isa BoolNot && return _qec_parse_negated_expr(expr.term, allowed)
    expr isa BoolXor && return _qec_parse_xor_expr(expr.left, expr.right, allowed)
    return nothing
end

function _qec_linear_vars(expr::BoolVar, allowed::Set{Symbol})
    expr.name in allowed || return nothing
    return (Set([expr.name]), false)
end

function _qec_parse_negated_expr(expr::BoolExpr, allowed::Set{Symbol})
    linear = _qec_parse_linear_expr(expr, allowed)
    linear === nothing && return nothing
    vars, constant = linear
    return (vars, !constant)
end

function _qec_parse_xor_expr(left::BoolExpr, right::BoolExpr, allowed::Set{Symbol})
    l = _qec_parse_linear_expr(left, allowed)
    r = _qec_parse_linear_expr(right, allowed)
    l === nothing && return nothing
    r === nothing && return nothing
    vars = _qec_xor_vars(copy(l[1]), r[1])
    return (vars, l[2] != r[2])
end

function _qec_xor_vars(target::Set{Symbol}, other::Set{Symbol})
    for variable in other
        if variable in target
            delete!(target, variable)
        else
            push!(target, variable)
        end
    end
    return target
end

function _qec_matrix_from_rows(fault_vars::Vector{Symbol}, rows::Vector{_QeccLinearConstraint})
    nvar = length(fault_vars)
    indices = Dict{Symbol,Int}()
    for (index, var) in enumerate(fault_vars)
        indices[var] = index
    end
    coeffs = Vector{Vector{Bool}}(undef, length(rows))
    rhs = Vector{Bool}(undef, length(rows))
    for (row_idx, row) in enumerate(rows)
        values = falses(nvar)
        for var in row.vars
            haskey(indices, var) || error("QECC pre-solver variable not in domain: $(var)")
            values[indices[var]] = true
        end
        coeffs[row_idx] = values
        rhs[row_idx] = row.rhs
    end
    return coeffs, rhs
end

function _qec_xor_in_place!(destination::Vector{Bool}, source::Vector{Bool})
    @inbounds for idx in eachindex(destination)
        destination[idx] = destination[idx] != source[idx]
    end
    return destination
end

function _qec_eliminate_linear_system!(coeffs::Vector{Vector{Bool}}, rhs::Vector{Bool}, nvar::Int)
    nrows = length(coeffs)
    pivots = Tuple{Int,Int}[]
    pivot_row = 1
    for col in 1:nvar
        pivot = 0
        for row in pivot_row:nrows
            coeffs[row][col] || continue
            pivot = row
            break
        end
        pivot == 0 && continue
        if pivot != pivot_row
            coeffs[pivot_row], coeffs[pivot] = coeffs[pivot], coeffs[pivot_row]
            rhs[pivot_row], rhs[pivot] = rhs[pivot], rhs[pivot_row]
        end
        for row in 1:nrows
            row == pivot_row && continue
            coeffs[row][col] || continue
            _qec_xor_in_place!(coeffs[row], coeffs[pivot_row])
            rhs[row] = rhs[row] != rhs[pivot_row]
        end
        push!(pivots, (pivot_row, col))
        pivot_row += 1
        pivot_row > nrows && break
    end
    for row in 1:nrows
        all_zero = true
        @inbounds for value in coeffs[row]
            value || continue
            all_zero = false
            break
        end
        if all_zero && rhs[row]
            return (false, pivots)
        end
    end
    return (true, pivots)
end

function _qec_build_model_bits(coeffs::Vector{Vector{Bool}}, rhs::Vector{Bool},
    pivots::Vector{Tuple{Int,Int}}, free_bits::AbstractVector{Bool})

    bits = copy(free_bits)
    nvar = length(free_bits)
    for pivot_pair in Iterators.reverse(pivots)
        row_idx, pivot_col = pivot_pair
        value = rhs[row_idx]
        row = coeffs[row_idx]
        for col in 1:nvar
            col == pivot_col && continue
            row[col] && (value = value != bits[col])
        end
        bits[pivot_col] = value
    end
    return bits
end

function _qec_bits_weight(bits::AbstractVector{Bool})
    return sum(Int(flag) for flag in bits)
end

function _qec_model_is_valid(bits::AbstractVector{Bool}, coeffs::Vector{Vector{Bool}}, rhs::Vector{Bool})
    nvar = length(bits)
    for row_idx in eachindex(coeffs)
        left = false
        row = coeffs[row_idx]
        for col in 1:nvar
            row[col] && (left = left != bits[col])
        end
        left == rhs[row_idx] || return false
    end
    return true
end

function _qec_bits_to_dict(bits::AbstractVector{Bool}, fault_vars::Vector{Symbol})
    assignment = Dict{Symbol,Bool}()
    for (idx, var) in enumerate(fault_vars)
        assignment[var] = bits[idx]
    end
    return assignment
end

function _qec_choose_free_bits!(coeffs::Vector{Vector{Bool}}, rhs::Vector{Bool},
    pivots::Vector{Tuple{Int,Int}}, free_cols::Vector{Int}, start_idx::Int,
    target::Int, free_bits::AbstractVector{Bool}, max_weight::Union{Nothing,Int},
    fault_vars::Vector{Symbol})

    if target == 0
        model_bits = _qec_build_model_bits(coeffs, rhs, pivots, free_bits)
        if max_weight !== nothing && _qec_bits_weight(model_bits) > max_weight
            return nothing
        end
        _qec_model_is_valid(model_bits, coeffs, rhs) || return nothing
        return (model_bits, _qec_bits_to_dict(model_bits, fault_vars))
    end
    nfree = length(free_cols)
    start_idx > nfree && return nothing
    first = start_idx
    last_possible = nfree - target + 1
    first > last_possible && return nothing
    for pick in first:last_possible
        free_bits[free_cols[pick]] = true
        out = _qec_choose_free_bits!(
            coeffs,
            rhs,
            pivots,
            free_cols,
            pick + 1,
            target - 1,
            free_bits,
            max_weight,
            fault_vars,
        )
        out !== nothing && return out
        free_bits[free_cols[pick]] = false
    end
    return nothing
end

function _qec_find_weight_bounded_model(coeffs::Vector{Vector{Bool}}, rhs::Vector{Bool},
    pivots::Vector{Tuple{Int,Int}}, nvar::Int, fault_vars::Vector{Symbol},
    max_weight::Union{Nothing,Int})

    if isempty(coeffs)
        candidate = Dict{Symbol,Bool}(var => false for var in fault_vars)
        max_weight === nothing || model_fault_weight(fault_vars, candidate) <= max_weight ||
            return nothing
        return (falses(nvar), candidate)
    end

    free_cols = Int[]
    pivot_cols = Set{Int}()
    for (_, col) in pivots
        push!(pivot_cols, col)
    end
    for col in 1:nvar
        col in pivot_cols || push!(free_cols, col)
    end
    free_bits = falses(nvar)
    if max_weight === nothing
        model_bits = _qec_build_model_bits(coeffs, rhs, pivots, free_bits)
        _qec_model_is_valid(model_bits, coeffs, rhs) || return nothing
        return (model_bits, _qec_bits_to_dict(model_bits, fault_vars))
    end
    max_weight_value = Int(max_weight)
    max_try = min(max_weight_value, length(free_cols))
    for target in 0:max_try
        out = _qec_choose_free_bits!(
            coeffs,
            rhs,
            pivots,
            free_cols,
            1,
            target,
            free_bits,
            max_weight_value,
            fault_vars,
        )
        out !== nothing && return out
        for col in free_cols
            free_bits[col] = false
        end
    end
    return nothing
end

function _qec_is_compatible_constraint(expr::BoolExpr, assignment::AbstractDict)
    try
        return evaluate(expr, assignment)
    catch
        return true
    end
end
