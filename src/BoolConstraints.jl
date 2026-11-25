abstract type BoolExpr end

struct BoolVar <: BoolExpr
    name::Symbol
end

struct BoolConst <: BoolExpr
    value::Bool
end

struct BoolNot <: BoolExpr
    term::BoolExpr
end

struct BoolAnd <: BoolExpr
    terms::Vector{BoolExpr}
end

struct BoolOr <: BoolExpr
    terms::Vector{BoolExpr}
end

struct BoolXor <: BoolExpr
    left::BoolExpr
    right::BoolExpr
end

struct BoolEq <: BoolExpr
    left::BoolExpr
    right::BoolExpr
end

boolvar(name::Symbol) = BoolVar(name)
boolvar(name::AbstractString) = BoolVar(Symbol(name))
bconst(value::Bool) = BoolConst(value)

function bnot(term::BoolExpr)
    term isa BoolConst && return BoolConst(!term.value)
    term isa BoolNot && return term.term
    return BoolNot(term)
end

function band(args::BoolExpr...)
    terms = BoolExpr[]
    for arg in args
        if arg isa BoolConst
            arg.value || return BoolConst(false)
        elseif arg isa BoolAnd
            append!(terms, arg.terms)
        else
            push!(terms, arg)
        end
    end
    isempty(terms) && return BoolConst(true)
    length(terms) == 1 && return terms[1]
    return BoolAnd(terms)
end

function bor(args::BoolExpr...)
    terms = BoolExpr[]
    for arg in args
        if arg isa BoolConst
            arg.value && return BoolConst(true)
        elseif arg isa BoolOr
            append!(terms, arg.terms)
        else
            push!(terms, arg)
        end
    end
    isempty(terms) && return BoolConst(false)
    length(terms) == 1 && return terms[1]
    return BoolOr(terms)
end

function bxor(left::BoolExpr, right::BoolExpr)
    left isa BoolConst && !left.value && return right
    right isa BoolConst && !right.value && return left
    left isa BoolConst && left.value && return bnot(right)
    right isa BoolConst && right.value && return bnot(left)
    return BoolXor(left, right)
end

function beq(left::BoolExpr, right::BoolExpr)
    left isa BoolConst && return left.value ? right : bnot(right)
    right isa BoolConst && return right.value ? left : bnot(left)
    return BoolEq(left, right)
end

function evaluate(expr::BoolExpr, model::AbstractDict)
    if expr isa BoolVar
        haskey(model, expr.name) || error("Missing Boolean assignment for $(expr.name)")
        return Bool(model[expr.name])
    elseif expr isa BoolConst
        return expr.value
    elseif expr isa BoolNot
        return !evaluate(expr.term, model)
    elseif expr isa BoolAnd
        return all(term -> evaluate(term, model), expr.terms)
    elseif expr isa BoolOr
        return any(term -> evaluate(term, model), expr.terms)
    elseif expr isa BoolXor
        return evaluate(expr.left, model) != evaluate(expr.right, model)
    elseif expr isa BoolEq
        return evaluate(expr.left, model) == evaluate(expr.right, model)
    end
    error("Unsupported BoolExpr: $(typeof(expr))")
end

function expr_vars(expr::BoolExpr)
    out = Set{Symbol}()
    collect_expr_vars!(out, expr)
    return sort!(collect(out), by=string)
end

function collect_expr_vars!(out::Set{Symbol}, expr::BoolExpr)
    if expr isa BoolVar
        push!(out, expr.name)
    elseif expr isa BoolNot
        collect_expr_vars!(out, expr.term)
    elseif expr isa BoolAnd || expr isa BoolOr
        for term in expr.terms
            collect_expr_vars!(out, term)
        end
    elseif expr isa BoolXor || expr isa BoolEq
        collect_expr_vars!(out, expr.left)
        collect_expr_vars!(out, expr.right)
    end
    return out
end

function expr_to_string(expr::BoolExpr)
    if expr isa BoolVar
        return string(expr.name)
    elseif expr isa BoolConst
        return expr.value ? "true" : "false"
    elseif expr isa BoolNot
        return "!(" * expr_to_string(expr.term) * ")"
    elseif expr isa BoolAnd
        return "(" * join(expr_to_string.(expr.terms), " && ") * ")"
    elseif expr isa BoolOr
        return "(" * join(expr_to_string.(expr.terms), " || ") * ")"
    elseif expr isa BoolXor
        return "(" * expr_to_string(expr.left) * " xor " * expr_to_string(expr.right) * ")"
    elseif expr isa BoolEq
        return "(" * expr_to_string(expr.left) * " == " * expr_to_string(expr.right) * ")"
    end
    return string(expr)
end

Base.show(io::IO, expr::BoolExpr) = print(io, expr_to_string(expr))

abstract type AbstractConstraintBackend end
abstract type AbstractConcolicSolver <: AbstractConstraintBackend end

struct SolverResult
    status::Symbol
    model::Union{Nothing,Dict{Symbol,Bool}}
    query_text::Union{Nothing,String}
    backend::String
    metadata::Dict{String,Any}
end

SolverResult(status::Symbol,
    model::Union{Nothing,Dict{Symbol,Bool}},
    query_text::Union{Nothing,String},
    backend::AbstractString) =
    SolverResult(status, model, query_text, String(backend), Dict{String,Any}())

solver_name(solver::AbstractConcolicSolver) = string(nameof(typeof(solver)))

function solver_query_text(
    solver::AbstractConcolicSolver,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    return nothing
end

struct LocalEnumeratorBackend <: AbstractConcolicSolver
    fault_vars::Vector{Symbol}
    max_weight::Union{Nothing,Int}
    var_index::Dict{Symbol,Int}
end

LocalEnumeratorBackend(fault_vars::Vector{Symbol}; max_weight=nothing) =
    LocalEnumeratorBackend(
        copy(fault_vars),
        max_weight,
        Dict(var => idx for (idx, var) in enumerate(fault_vars)),
    )

const BruteForceBoolSolver = LocalEnumeratorBackend

solver_name(::LocalEnumeratorBackend) = "bruteforce-bool"

solver_fault_vars(solver::LocalEnumeratorBackend) = copy(solver.fault_vars)

solver_max_weight(solver::AbstractConcolicSolver) = nothing

solver_max_weight(solver::LocalEnumeratorBackend) = solver.max_weight

bool_constraint_symbol(value::Symbol) = value
bool_constraint_symbol(value::AbstractString) = Symbol(value)
bool_constraint_symbol(value) = Symbol(string(value))

zero_assignment(fault_vars::Vector{Symbol}) = Dict(var => false for var in fault_vars)

function model_bool(model::AbstractDict, var::Symbol; default=false)
    value = if haskey(model, var)
        model[var]
    else
        get(model, string(var), default)
    end
    return Bool(value)
end

function normalize_assignment(fault_vars::Vector{Symbol}, input::AbstractDict)
    model = Dict{Symbol,Bool}()
    for var in fault_vars
        model[var] = model_bool(input, var)
    end
    return model
end

function assignment_key(fault_vars::Vector{Symbol}, model::AbstractDict)
    bits = String[]
    for var in fault_vars
        push!(bits, string(var) * "=" * (model_bool(model, var) ? "1" : "0"))
    end
    return join(bits, ";")
end

function active_index_model(fault_vars::Vector{Symbol}, active::AbstractVector{Int})
    model = Dict(var => false for var in fault_vars)
    for idx in active
        model[fault_vars[idx]] = true
    end
    return model
end

struct ActiveIndexAssignment <: AbstractDict{Symbol,Bool}
    fault_vars::Vector{Symbol}
    active::Vector{Int}
    var_index::Dict{Symbol,Int}
end

Base.length(model::ActiveIndexAssignment) = length(model.fault_vars)
Base.haskey(model::ActiveIndexAssignment, key::Symbol) = haskey(model.var_index, key)
Base.haskey(model::ActiveIndexAssignment, key) =
    key isa Symbol && haskey(model, key)

function Base.getindex(model::ActiveIndexAssignment, key::Symbol)
    idx = get(model.var_index, key, nothing)
    idx === nothing && error("Missing Boolean assignment for $(key)")
    return any(active -> active == idx, model.active)
end

function Base.iterate(model::ActiveIndexAssignment, state::Int=1)
    state > length(model.fault_vars) && return nothing
    var = model.fault_vars[state]
    return (var => model[var]), state + 1
end

function first_satisfying_model(
    solver::LocalEnumeratorBackend,
    constraints::AbstractVector{<:BoolExpr},
    active::AbstractVector{Int},
    avoid::Set{String})

    candidate = ActiveIndexAssignment(solver.fault_vars, collect(active), solver.var_index)
    all(constraint -> evaluate(constraint, candidate), constraints) || return nothing
    assignment_key(solver.fault_vars, candidate) in avoid && return nothing
    return active_index_model(solver.fault_vars, active)
end

function merge_literal_requirement!(
    requirements::Dict{Symbol,Bool},
    var::Symbol,
    value::Bool,
)
    if haskey(requirements, var)
        requirements[var] == value && return :ok
        return :unsat
    end
    requirements[var] = value
    return :ok
end

function collect_literal_requirements!(
    requirements::Dict{Symbol,Bool},
    expr::BoolExpr,
)
    expr isa BoolConst && return expr.value ? :ok : :unsat
    expr isa BoolVar &&
        return merge_literal_requirement!(requirements, expr.name, true)
    if expr isa BoolNot && expr.term isa BoolVar
        return merge_literal_requirement!(requirements, expr.term.name, false)
    end
    if expr isa BoolAnd
        for term in expr.terms
            status = collect_literal_requirements!(requirements, term)
            status == :ok || return status
        end
        return :ok
    end
    return :unsupported
end

function literal_constraint_model(
    solver::LocalEnumeratorBackend,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    requirements = Dict{Symbol,Bool}()
    for constraint in constraints
        status = collect_literal_requirements!(requirements, constraint)
        status == :unsupported && return (:unsupported, nothing)
        status == :unsat && return (:supported, nothing)
    end

    required_true = Symbol[
        var for (var, value) in requirements if value
    ]
    max_weight = solver.max_weight === nothing ? length(solver.fault_vars) :
        min(Int(solver.max_weight), length(solver.fault_vars))
    length(required_true) > max_weight && return (:supported, nothing)

    function candidate_model(extra_true::Vector{Symbol}=Symbol[])
        model = zero_assignment(solver.fault_vars)
        for var in required_true
            haskey(solver.var_index, var) || return nothing
            model[var] = true
        end
        for var in extra_true
            haskey(solver.var_index, var) || return nothing
            model[var] = true
        end
        for (var, value) in requirements
            haskey(solver.var_index, var) || return nothing
            value || (model[var] = false)
        end
        all(constraint -> evaluate(constraint, model), constraints) || return nothing
        assignment_key(solver.fault_vars, model) in avoid && return nothing
        return model
    end

    base = candidate_model()
    base !== nothing && return (:supported, base)
    length(required_true) >= max_weight && return (:supported, nothing)

    # Common concolic branch-query case: max_weight=1, flipped branch true was
    # avoided as the clean input, so choose the first optional literal model.
    for var in solver.fault_vars
        get(requirements, var, nothing) === false && continue
        get(requirements, var, nothing) === true && continue
        model = candidate_model(Symbol[var])
        model !== nothing && return (:supported, model)
    end
    return (:supported, nothing)
end

function bounded_weight_model(
    solver::LocalEnumeratorBackend,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    fast_status, fast_model = literal_constraint_model(solver, constraints; avoid=avoid)
    fast_status == :supported && return fast_model

    max_weight = min(Int(solver.max_weight), length(solver.fault_vars))
    max_weight < 0 && return nothing

    zero_model = first_satisfying_model(solver, constraints, Int[], avoid)
    zero_model !== nothing && return zero_model

    function search_fixed_weight!(active::Vector{Int}, remaining::Int, max_idx::Int)
        if remaining == 0
            return first_satisfying_model(solver, constraints, active, avoid)
        end

        for idx in remaining:max_idx
            push!(active, idx)
            result = search_fixed_weight!(active, remaining - 1, idx - 1)
            result === nothing || return result
            pop!(active)
        end
        return nothing
    end

    for weight in 1:max_weight
        result = search_fixed_weight!(Int[], weight, length(solver.fault_vars))
        result === nothing || return result
    end
    return nothing
end

function brute_force_model(
    solver::LocalEnumeratorBackend,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    solver.max_weight !== nothing &&
        return bounded_weight_model(solver, constraints; avoid=avoid)

    nvars = length(solver.fault_vars)
    masks = collect(0:(2^nvars - 1))
    sort!(masks, by=mask -> (count_ones(UInt(mask)), mask))

    for mask in masks
        solver.max_weight !== nothing && count_ones(UInt(mask)) > solver.max_weight && continue
        model = Dict{Symbol,Bool}()
        for (idx, var) in enumerate(solver.fault_vars)
            model[var] = ((mask >> (idx - 1)) & 1) == 1
        end
        assignment_key(solver.fault_vars, model) in avoid && continue
        all(constraint -> evaluate(constraint, model), constraints) || continue
        return model
    end
    return nothing
end

function solve_model(
    solver::LocalEnumeratorBackend,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    model = brute_force_model(solver, constraints; avoid=avoid)
    status = model === nothing ? :unsat : :sat
    return SolverResult(
        status,
        model,
        nothing,
        solver_name(solver),
        Dict{String,Any}(
            "backend" => solver_name(solver),
            "solver_status" => uppercase(String(status)),
            "solve_time_ms" => 0.0,
            "fault_variable_count" => length(solver.fault_vars),
            "max_fault_weight" => solver.max_weight,
        ),
    )
end

function solve(solver::AbstractConcolicSolver, constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    result = solve_model(solver, constraints; avoid=avoid)
    result.status == :sat || return nothing
    return result.model
end

function variable_location(var::Symbol)
    name = string(var)
    round_match = match(r"^[xyz]_r([0-9]+)_q([0-9]+)$", name)
    round_match !== nothing &&
        return "r" * round_match.captures[1] * ":q" * round_match.captures[2]
    if startswith(name, "x") || startswith(name, "z") || startswith(name, "y")
        suffix = name[2:end]
        !isempty(suffix) && all(isdigit, suffix) && return "q" * suffix
    end
    return name
end

function variable_pauli(var::Symbol, default_pauli::String)
    name = string(var)
    startswith(name, "x") && return "X"
    startswith(name, "z") && return "Z"
    startswith(name, "y") && return "Y"
    return default_pauli
end

function model_to_fault_pattern(fault_vars::Vector{Symbol}, model::AbstractDict; default_pauli="X")
    return [
        begin
            pauli = variable_pauli(var, default_pauli)
            location = variable_location(var)
            Dict{String,Any}(
                "variable" => string(var),
                "pauli" => pauli,
                "location" => location,
                "site" => "data",
                "label" => pauli * "@" * location,
                "active" => model_bool(model, var),
            )
        end
        for var in fault_vars
    ]
end

function model_to_fault_pattern(model::AbstractDict, fault_registry; default_pauli="X")
    if fault_registry isa AbstractVector
        return model_to_fault_pattern(
            [bool_constraint_symbol(var) for var in fault_registry],
            model;
            default_pauli=default_pauli,
        )
    elseif fault_registry isa AbstractDict
        vars = if haskey(fault_registry, "fault_vars")
            fault_registry["fault_vars"]
        elseif haskey(fault_registry, :fault_vars)
            fault_registry[:fault_vars]
        else
            error("fault registry dictionary must contain fault_vars")
        end
        return model_to_fault_pattern(
            [bool_constraint_symbol(var) for var in vars],
            model;
            default_pauli=default_pauli,
        )
    end
    error("unsupported fault registry for model_to_fault_pattern: $(typeof(fault_registry))")
end
