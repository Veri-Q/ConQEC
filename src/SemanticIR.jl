const _SEMANTIC_ORACLE_TOKENS = ("oracle",)
const _SEMANTIC_TARGET_TOKENS = ("target",)
const _SEMANTIC_SEEDED_TOKENS = ("seeded",)
const _SEMANTIC_CONTRACT_TOKENS = ("contract",)
const _SEMANTIC_FORBIDDEN_FLIPPABLE_SOURCES = Set([
    :oracle,
    :target,
    :seeded,
    :contract,
    :seeded_contract,
])

abstract type AbstractSemanticExpr end
abstract type AbstractSemanticGuard end

struct SemanticExpr <: AbstractSemanticExpr
    expr::BoolExpr
end

struct FaultVar <: AbstractSemanticExpr
    expr::BoolExpr

    function FaultVar(name::Symbol)
        new(boolvar(name))
    end

    function FaultVar(name::AbstractString)
        new(boolvar(name))
    end

    function FaultVar(expr::BoolExpr)
        expr isa BoolVar || error("FaultVar expects a BoolVar expression, got $(typeof(expr))")
        new(expr)
    end
end

struct ParityExpr <: AbstractSemanticExpr
    expr::BoolExpr

    function ParityExpr(terms::AbstractVector{<:BoolExpr})
        if isempty(terms)
            return new(bconst(false))
        end
        expr = copy(terms)[1]
        for term in terms[2:end]
            expr = bxor(expr, term)
        end
        return new(expr)
    end

    ParityExpr(terms::Tuple) = ParityExpr(Vector{BoolExpr}(terms))
    ParityExpr(args::BoolExpr...) = ParityExpr(BoolExpr[args...])
    function ParityExpr(left::BoolExpr, right::BoolExpr)
        new(bxor(left, right))
    end
end

SemanticExpr(expr::BoolExpr) = SemanticExpr(expr)

to_bool_expr(expr::BoolExpr) = expr
to_bool_expr(expr::SemanticExpr) = expr.expr
to_bool_expr(expr::FaultVar) = expr.expr
to_bool_expr(expr::ParityExpr) = expr.expr

expr_vars(expr::AbstractSemanticExpr) = expr_vars(to_bool_expr(expr))
expr_to_string(expr::AbstractSemanticExpr) = expr_to_string(to_bool_expr(expr))

struct SemanticGuard <: AbstractSemanticGuard
    id::String
    stage::Symbol
    condition::BoolExpr
    taken::Bool
    concrete_value::Bool
    description::String
    path_constraint::Bool
    flippable::Bool
    diagnostic_only::Bool
    source::Symbol
end

struct OracleCheck <: AbstractSemanticGuard
    id::String
    stage::Symbol
    condition::BoolExpr
    accepted::Bool
    concrete_value::Bool
    description::String
    path_constraint::Bool
    flippable::Bool
    diagnostic_only::Bool
    source::Symbol
end

mutable struct SemanticTrace
    subject_name::String
    fault_vars::Vector{Symbol}
    fault_assignments::Dict{Symbol,Bool}
    semantic_guards::Vector{SemanticGuard}
    oracle_checks::Vector{OracleCheck}
    metadata::Dict{String,Any}
end

struct SemanticStateKey
    subject_name::String
    stage::Symbol
    assignment::String
end

function check_no_oracle_branch(guard::SemanticGuard)
    lowered_id = lowercase(String(guard.id))
    occursin(_SEMANTIC_ORACLE_TOKENS[1], lowered_id) &&
        error("semantic guard $(guard.id) is forbidden from referencing oracle")
    return true
end

function _check_no_dependency(expr::BoolExpr, tokens::Tuple, context::AbstractString)
    vars = expr_vars(expr)
    for name in vars
        lowered = lowercase(string(name))
        if any(occursin(token, lowered) for token in tokens)
            error("semantic guard $(context) uses forbidden dependency $(name)")
        end
    end
    return true
end

function _check_no_dependency(tokenized_text::AbstractString, tokens::Tuple, context::AbstractString)
    lowered = lowercase(tokenized_text)
    if any(occursin(token, lowered) for token in tokens)
        error("semantic guard $(context) contains forbidden token in identifier $(tokenized_text)")
    end
    return true
end

check_no_target_dependency(expr::BoolExpr) =
    _check_no_dependency(expr, _SEMANTIC_TARGET_TOKENS, "target")
check_no_target_dependency(expr::AbstractString) =
    _check_no_dependency(String(expr), _SEMANTIC_TARGET_TOKENS, "target")
check_no_seeded_contract_dependency(expr::BoolExpr) =
    _check_no_dependency(expr, (_SEMANTIC_SEEDED_TOKENS..., _SEMANTIC_CONTRACT_TOKENS...), "seeded/contract")
check_no_seeded_contract_dependency(expr::AbstractString) =
    _check_no_dependency(String(expr), (_SEMANTIC_SEEDED_TOKENS..., _SEMANTIC_CONTRACT_TOKENS...), "seeded/contract")

function check_no_oracle_dependency(expr::BoolExpr)
    _check_no_dependency(expr, _SEMANTIC_ORACLE_TOKENS, "oracle")
end

function check_no_oracle_dependency(expr::AbstractString)
    _check_no_dependency(String(expr), _SEMANTIC_ORACLE_TOKENS, "oracle")
end

function check_branch_source_hygiene(guard::SemanticGuard)
    check_no_oracle_branch(guard)
    if guard.flippable
        guard.source in _SEMANTIC_FORBIDDEN_FLIPPABLE_SOURCES &&
            error("flippable semantic guard $(guard.id) uses forbidden source $(guard.source)")
        check_no_target_dependency(guard.id)
        check_no_target_dependency(guard.condition)
        check_no_oracle_dependency(guard.id)
        check_no_oracle_dependency(guard.condition)
        check_no_seeded_contract_dependency(guard.id)
        check_no_seeded_contract_dependency(guard.condition)
    end
    return guard
end

function SemanticGuard(
    id::AbstractString,
    stage::Symbol,
    condition::Union{AbstractSemanticExpr,BoolExpr},
    taken::Bool;
    description="",
    path_constraint=true,
    flippable=path_constraint,
    diagnostic_only=!path_constraint,
    source=:semantic,
)
    stage in DIVERGENCE_STAGES || error("Unsupported branch stage: $(stage)")
    Bool(flippable) && !Bool(path_constraint) &&
        error("flippable guard $(id) must also be a path constraint")
    guard = SemanticGuard(
        String(id),
        stage,
        to_bool_expr(condition),
        Bool(taken),
        Bool(taken),
        String(description),
        Bool(path_constraint),
        Bool(flippable),
        Bool(diagnostic_only),
        Symbol(source),
    )
    return check_branch_source_hygiene(guard)
end

function OracleCheck(
    id::AbstractString,
    stage::Symbol,
    condition::Union{AbstractSemanticExpr,BoolExpr},
    accepted::Bool;
    description="",
    source=:oracle,
)
    stage in DIVERGENCE_STAGES || error("Unsupported branch stage: $(stage)")
    return OracleCheck(
        String(id),
        stage,
        to_bool_expr(condition),
        Bool(accepted),
        Bool(accepted),
        String(description),
        false,
        false,
        true,
        Symbol(source),
    )
end

function SemanticTrace(subject_name::AbstractString;
    fault_vars=Symbol[],
    fault_assignments=Dict{Symbol,Bool}(),
    metadata=Dict{String,Any}())

    normalized_fault_vars = [to_symbol(var) for var in fault_vars]
    normalized_fault_assignments =
        normalize_trace_fault_assignments(normalized_fault_vars, fault_assignments)

    return SemanticTrace(
        String(subject_name),
        normalized_fault_vars,
        normalized_fault_assignments,
        SemanticGuard[],
        OracleCheck[],
        Dict{String,Any}(metadata),
    )
end

function record_semantic_guard!(trace::SemanticTrace, id::AbstractString, stage::Symbol,
    condition::Union{AbstractSemanticExpr,BoolExpr}, taken::Bool; kwargs...)

    push!(trace.semantic_guards, SemanticGuard(id, stage, condition, taken; kwargs...))
    return trace
end

function record_oracle_check!(trace::SemanticTrace, id::AbstractString, stage::Symbol,
    condition::Union{AbstractSemanticExpr,BoolExpr}, accepted::Bool; kwargs...)

    push!(trace.oracle_checks, OracleCheck(id, stage, condition, accepted; kwargs...))
    return trace
end

function path_constraint(trace::SemanticTrace)
    return [
        guard.taken ? guard.condition : bnot(guard.condition)
        for guard in trace.semantic_guards
        if guard.path_constraint
    ]
end

function SemanticStateKey(trace::SemanticTrace, stage::Symbol; assignments=trace.fault_assignments)
    assignment_text = assignment_key(trace.fault_vars, assignments)
    return SemanticStateKey(trace.subject_name, stage, assignment_text)
end
