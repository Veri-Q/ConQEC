const DIVERGENCE_STAGES = (
    :fault,
    :syndrome,
    :measurement_result,
    :decoder,
    :recovery,
    :repeated_round_control,
    :boundary_classification,
    :observable_mapping,
    :logical_check,
    :unknown,
)

const FORBIDDEN_FLIPPABLE_BRANCH_SOURCES = Set([
    :oracle,
    :target,
    :seeded,
    :contract,
    :seeded_contract,
])

struct BranchGuard
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

mutable struct ConcolicTrace
    subject_name::String
    code_size::Union{Nothing,Int}
    distance::Union{Nothing,Int}
    fault_vars::Vector{Symbol}
    fault_assignments::Dict{Symbol,Bool}
    branch_guards::Vector{BranchGuard}
    syndrome_values::Dict{String,Bool}
    syndrome_exprs::Dict{String,BoolExpr}
    decoder_decisions::Dict{String,Any}
    recovery_actions::Vector{Dict{String,Any}}
    logical_verdicts::Dict{String,Any}
    metadata::Dict{String,Any}
end

to_symbol(value::Symbol) = value
to_symbol(value::AbstractString) = Symbol(value)
to_symbol(value) = Symbol(string(value))

normalize_fault_vars(fault_vars) = [to_symbol(var) for var in fault_vars]

function normalize_trace_fault_assignments(fault_vars::Vector{Symbol}, input::AbstractDict)
    isempty(fault_vars) &&
        return Dict{Symbol,Bool}(to_symbol(key) => Bool(value) for (key, value) in input)
    return normalize_assignment(fault_vars, input)
end

function ConcolicTrace(subject_name::AbstractString;
    code_size=nothing,
    distance=nothing,
    fault_vars=Symbol[],
    fault_assignments=Dict{Symbol,Bool}(),
    metadata=Dict{String,Any}())

    normalized_fault_vars = normalize_fault_vars(fault_vars)
    normalized_fault_assignments =
        normalize_trace_fault_assignments(normalized_fault_vars, fault_assignments)

    return ConcolicTrace(
        String(subject_name),
        code_size,
        distance,
        normalized_fault_vars,
        normalized_fault_assignments,
        BranchGuard[],
        Dict{String,Bool}(),
        Dict{String,BoolExpr}(),
        Dict{String,Any}(),
        Dict{String,Any}[],
        Dict{String,Any}(),
        Dict{String,Any}(metadata),
    )
end

function record_branch!(trace::ConcolicTrace, id::AbstractString, stage::Symbol,
    condition::BoolExpr, taken::Bool; description="", path_constraint=true,
    flippable=path_constraint, diagnostic_only=!path_constraint, source=:legacy)

    stage in DIVERGENCE_STAGES || error("Unsupported branch stage: $(stage)")
    Bool(flippable) && !Bool(path_constraint) &&
        error("flippable branch $(id) must also be a path constraint")
    Bool(diagnostic_only) && Bool(flippable) &&
        error("branch $(id) cannot be both flippable and diagnostic-only")
    guard = BranchGuard(
        String(id),
        stage,
        condition,
        taken,
        taken,
        String(description),
        Bool(path_constraint),
        Bool(flippable),
        Bool(diagnostic_only),
        Symbol(source),
    )
    check_branch_guard_source_hygiene(guard)
    push!(trace.branch_guards, guard)
    return trace
end

function check_branch_guard_source_hygiene(guard::BranchGuard)
    if guard.flippable && guard.source in FORBIDDEN_FLIPPABLE_BRANCH_SOURCES
        error("flippable branch $(guard.id) uses forbidden source $(guard.source)")
    end
    return guard
end

function record_semantic_guard!(trace::ConcolicTrace, id::AbstractString, stage::Symbol,
    condition::BoolExpr, taken::Bool; description="", path_constraint=true,
    flippable=path_constraint)

    vars = Set(expr_vars(condition))
    fault_vars = Set(trace.fault_vars)
    if !issubset(vars, fault_vars)
        unexpected = sort!(collect(setdiff(vars, fault_vars)))
        error("semantic guard $(id) uses non-fault variables: $(join(string.(unexpected), ","))")
    end
    lowered_id = lowercase(String(id))
    forbidden_tokens = ("oracle", "target", "contract", "expected", "trigger")
    for token in forbidden_tokens
        occursin(token, lowered_id) &&
            error("semantic guard $(id) contains forbidden scheduler metadata token $(token)")
    end
    return record_branch!(
        trace,
        id,
        stage,
        condition,
        taken;
        description=description,
        path_constraint=path_constraint,
        flippable=flippable,
        diagnostic_only=!Bool(path_constraint),
        source=:semantic,
    )
end

function record_oracle_check!(trace::ConcolicTrace, id::AbstractString,
    condition::BoolExpr, accepted::Bool; description="")

    return record_branch!(
        trace,
        id,
        :logical_check,
        condition,
        accepted;
        description=description,
        path_constraint=false,
        flippable=false,
        diagnostic_only=true,
        source=:oracle,
    )
end

function record_syndrome_bit_branches!(trace::ConcolicTrace,
    names::AbstractVector,
    values::AbstractVector{Bool},
    exprs::AbstractVector{<:BoolExpr};
    id_prefix="syndrome",
    path_constraint=false)

    length(names) == length(values) == length(exprs) ||
        error("syndrome branch names, values, and expressions must have the same length")
    for (name, value, expr) in zip(names, values, exprs)
        record_branch!(
            trace,
            string(id_prefix) * ":" * string(name) * "_value",
            :syndrome,
            expr,
            value;
            description="observed syndrome bit $(name)",
            path_constraint=path_constraint,
            source=:semantic,
        )
    end
    return trace
end

branch_id_token(value) = replace(string(value), r"[^A-Za-z0-9_.-]" => "_")

function record_recovery_output_branches!(trace::ConcolicTrace,
    actual_decoder,
    output_conditions::AbstractVector{<:Tuple};
    id_prefix="recovery:decoder_output",
    description_prefix="recovery arm selected by decoder output")

    actual = string(actual_decoder)
    for (output, condition) in output_conditions
        output_text = string(output)
        taken = actual == output_text
        record_branch!(
            trace,
            string(id_prefix, "_", branch_id_token(output_text)),
            :recovery,
            condition,
            taken;
            description=string(description_prefix, " ", output_text),
            source=:semantic,
        )
        taken && return trace
    end
    return trace
end

function record_syndrome!(trace::ConcolicTrace, name::AbstractString, value::Bool,
    expr::BoolExpr)

    trace.syndrome_values[String(name)] = value
    trace.syndrome_exprs[String(name)] = expr
    return trace
end

function record_decoder_decision!(trace::ConcolicTrace, key::AbstractString, value)
    trace.decoder_decisions[String(key)] = value
    return trace
end

function record_recovery_action!(trace::ConcolicTrace, action::AbstractDict)
    push!(trace.recovery_actions, Dict{String,Any}(string(key) => value for (key, value) in action))
    return trace
end

function record_logical_verdict!(trace::ConcolicTrace, key::AbstractString, value)
    trace.logical_verdicts[String(key)] = value
    return trace
end

function path_constraint(trace::ConcolicTrace)
    return [
        guard.taken ? guard.condition : bnot(guard.condition)
        for guard in trace.branch_guards
        if guard.path_constraint
    ]
end

function require_path_constraint_branch(trace::ConcolicTrace, branch_index::Integer)
    1 <= branch_index <= length(trace.branch_guards) ||
        error("branch_index $(branch_index) is outside 1:$(length(trace.branch_guards))")
    guard = trace.branch_guards[branch_index]
    guard.path_constraint && guard.flippable && !guard.diagnostic_only ||
        error("branch_index $(branch_index) ($(guard.id)) is diagnostic-only and cannot be flipped")
    return guard
end

function branch_control_group(guard::BranchGuard)
    parts = split(guard.id, ':'; limit=2)
    length(parts) == 2 && return parts[1]
    return guard.id
end

function branch_control_dependent_suffix(target::BranchGuard, guard::BranchGuard)
    branch_control_group(guard) == branch_control_group(target) && return true
    return target.stage == :decoder &&
        guard.stage == :recovery &&
        startswith(guard.id, "recovery:decoder_output")
end

function flipped_path_constraint(trace::ConcolicTrace, branch_index::Integer)
    require_path_constraint_branch(trace, branch_index)

    constraints = BoolExpr[]
    for idx in 1:branch_index
        guard = trace.branch_guards[idx]
        guard.path_constraint || continue
        should_take = idx == branch_index ? !guard.taken : guard.taken
        push!(constraints, should_take ? guard.condition : bnot(guard.condition))
    end
    return constraints
end

function full_flipped_path_constraint(trace::ConcolicTrace, branch_index::Integer)
    target = require_path_constraint_branch(trace, branch_index)
    target_group = branch_control_group(target)

    constraints = BoolExpr[]
    for idx in eachindex(trace.branch_guards)
        guard = trace.branch_guards[idx]
        guard.path_constraint || continue
        idx > branch_index && branch_control_dependent_suffix(target, guard) && continue
        should_take = idx == branch_index ? !guard.taken : guard.taken
        push!(constraints, should_take ? guard.condition : bnot(guard.condition))
    end
    return constraints
end

max_fault_weight(trace::ConcolicTrace) =
    get(trace.metadata, "max_fault_weight", length(trace.fault_vars))

function syndrome_key(trace::ConcolicTrace)
    names = sort!(collect(keys(trace.syndrome_values)))
    isempty(names) && return "<none>"
    return join([name * "=" * (trace.syndrome_values[name] ? "1" : "0") for name in names], ",")
end

fault_pattern(trace::ConcolicTrace) =
    model_to_fault_pattern(trace.fault_vars, trace.fault_assignments)
