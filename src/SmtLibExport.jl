function smt_symbol(name::Symbol)
    text = string(name)
    occursin(r"^[A-Za-z_][A-Za-z0-9_!?.-]*$", text) && return text
    return "|" * replace(text, "|" => "||") * "|"
end

function expr_to_smt2(expr::BoolExpr)
    if expr isa BoolVar
        return smt_symbol(expr.name)
    elseif expr isa BoolConst
        return expr.value ? "true" : "false"
    elseif expr isa BoolNot
        return "(not " * expr_to_smt2(expr.term) * ")"
    elseif expr isa BoolAnd
        isempty(expr.terms) && return "true"
        length(expr.terms) == 1 && return expr_to_smt2(expr.terms[1])
        return "(and " * join(expr_to_smt2.(expr.terms), " ") * ")"
    elseif expr isa BoolOr
        isempty(expr.terms) && return "false"
        length(expr.terms) == 1 && return expr_to_smt2(expr.terms[1])
        return "(or " * join(expr_to_smt2.(expr.terms), " ") * ")"
    elseif expr isa BoolXor
        return "(xor " * expr_to_smt2(expr.left) * " " * expr_to_smt2(expr.right) * ")"
    elseif expr isa BoolEq
        return "(= " * expr_to_smt2(expr.left) * " " * expr_to_smt2(expr.right) * ")"
    end
    error("Unsupported BoolExpr for SMT-LIB export: $(typeof(expr))")
end

function declare_bool_vars_smt2(fault_vars::Vector{Symbol})
    return ["(declare-fun " * smt_symbol(var) * " () Bool)" for var in fault_vars]
end

function bv_width_for_choices(choice_count::Integer)
    choice_count >= 0 ||
        error("choice_count must be non-negative, got $(choice_count)")
    width = 1
    capacity = 2
    while capacity < max(1, choice_count)
        width += 1
        capacity <<= 1
    end
    return width
end

function bv_literal(value::Integer, width::Integer)
    value >= 0 || error("BitVec literal value must be non-negative, got $(value)")
    width >= 1 || error("BitVec literal width must be positive, got $(width)")
    value < (1 << width) ||
        error("BitVec literal value $(value) does not fit in width $(width)")

    bits = IOBuffer()
    for shift in (width - 1):-1:0
        print(bits, ((value >> shift) & 1) == 1 ? "1" : "0")
    end
    return "#b" * String(take!(bits))
end

function smt_comment_text(text::AbstractString)
    return replace(String(text), "\n" => " ", "\r" => " ", ";" => ",")
end

function smt_safe_suffix(text::AbstractString)
    suffix = replace(String(text), r"[^A-Za-z0-9_]" => "_")
    isempty(suffix) && return "value"
    return suffix
end

sigma_smt_symbol(name::AbstractString) =
    "conqec_sigma_" * smt_safe_suffix(name)

function smt_syndrome_pattern(names::AbstractVector, bits::AbstractString)
    length(names) == length(bits) ||
        error("syndrome pattern length $(length(bits)) does not match $(length(names)) names")
    return Dict{String,Any}(
        string(name) => bits[idx] == '1'
        for (idx, name) in enumerate(names)
    )
end

function annotation_get(dict::AbstractDict, key::AbstractString, default=nothing)
    haskey(dict, key) && return dict[key]
    sym = Symbol(key)
    haskey(dict, sym) && return dict[sym]
    return default
end

function bv_annotation_label(value)
    value === nothing && return "nothing"
    if value isa AbstractDict
        pauli = annotation_get(value, "pauli", nothing)
        target = annotation_get(value, "target", nothing)
        source = annotation_get(value, "source", nothing)
        inferred_round = annotation_get(value, "inferred_round", nothing)
        if pauli !== nothing || target !== nothing
            label = string(
                pauli === nothing ? "?" : pauli,
                "@",
                target === nothing ? "?" : target,
            )
            inferred_round === nothing || (label *= ":round=$(inferred_round)")
            source === nothing || (label *= ":source=$(source)")
            return label
        end
    end
    return string(value)
end

function push_unique_annotation!(out::Vector{String}, value)
    label = bv_annotation_label(value)
    isempty(label) && return out
    any(existing -> existing == label, out) || push!(out, label)
    return out
end

function append_bv_domain_header!(lines::Vector{String}, label::AbstractString,
    var_name::AbstractString, domain::Vector{String})

    isempty(domain) && return nothing
    width = bv_width_for_choices(length(domain))
    domain_text = join(
        [string(idx - 1, "=", smt_comment_text(value)) for (idx, value) in enumerate(domain)],
        ", ",
    )
    push!(lines, "; conqec-bv $(label) domain: $(domain_text)")
    push!(lines, "(declare-fun $(var_name) () (_ BitVec $(width)))")
    push!(
        lines,
        "(assert (bvule $(var_name) $(bv_literal(length(domain) - 1, width))))",
    )
    return width
end

function annotation_index(domain::Vector{String}, value)
    label = bv_annotation_label(value)
    idx = findfirst(existing -> existing == label, domain)
    idx === nothing && return nothing
    return idx - 1
end

function decoder_recovery_semantics_row(branch_id::AbstractString,
    syndrome_pattern::AbstractDict,
    decoder_output,
    recovery::AbstractDict)

    return Dict{String,Any}(
        "branch_id" => String(branch_id),
        "syndrome_pattern" => Dict{String,Any}(
            string(key) => Bool(value)
            for (key, value) in syndrome_pattern
        ),
        "decoder_output" => String(decoder_output),
        "recovery" => Dict{String,Any}(string(key) => value for (key, value) in recovery),
    )
end

function set_decoder_recovery_semantics!(trace::ConcolicTrace, rows::AbstractVector)
    trace.metadata["decoder_recovery_semantics"] =
        [Dict{String,Any}(row) for row in rows]
    return trace
end

function decoder_recovery_semantics(trace::ConcolicTrace)
    rows = annotation_get(trace.metadata, "decoder_recovery_semantics", nothing)
    rows isa AbstractVector || return Dict{String,Any}[]
    return [Dict{String,Any}(row) for row in rows if row isa AbstractDict]
end

function syndrome_semantics_smt2(trace::ConcolicTrace)
    isempty(trace.syndrome_exprs) && return String[]
    lines = String[]
    for name in sort!(collect(keys(trace.syndrome_exprs)))
        sigma = sigma_smt_symbol(name)
        push!(lines, "(declare-fun $(sigma) () Bool)")
        push!(lines, "(assert (= $(sigma) $(expr_to_smt2(trace.syndrome_exprs[name]))))")
    end
    return lines
end

function semantic_row_condition_smt2(row::AbstractDict)
    pattern = annotation_get(row, "syndrome_pattern", nothing)
    pattern isa AbstractDict || return nothing
    terms = String[]
    for name in sort!(collect(keys(pattern)), by=string)
        sigma = sigma_smt_symbol(string(name))
        value = Bool(pattern[name])
        push!(terms, value ? sigma : "(not $(sigma))")
    end
    isempty(terms) && return "true"
    length(terms) == 1 && return first(terms)
    return "(and " * join(terms, " ") * ")"
end

function semantic_row_group_key(row::AbstractDict)
    pattern = annotation_get(row, "syndrome_pattern", nothing)
    pattern isa AbstractDict || return ""
    return join(sort!(string.(collect(keys(pattern)))), "__")
end

function semantic_row_groups(rows::Vector{Dict{String,Any}})
    order = String[]
    groups = Dict{String,Vector{Dict{String,Any}}}()
    for row in rows
        key = semantic_row_group_key(row)
        if !haskey(groups, key)
            groups[key] = Dict{String,Any}[]
            push!(order, key)
        end
        push!(groups[key], row)
    end
    return [groups[key] for key in order]
end

function grouped_bv_name(base::AbstractString, key::AbstractString, group_count::Integer)
    group_count == 1 && return String(base)
    return String(base) * "_" * smt_safe_suffix(key)
end

function implication_smt2(condition::AbstractString, consequent::AbstractString)
    return "(assert (=> $(condition) $(consequent)))"
end

function decoder_branch_bv_annotations(trace::ConcolicTrace)
    rows = decoder_recovery_semantics(trace)
    if !isempty(rows)
        lines = String[]
        groups = semantic_row_groups(rows)
        for group in groups
            key = semantic_row_group_key(first(group))
            var_name = grouped_bv_name("conqec_decoder_branch_bv", key, length(groups))
            domain = [String(annotation_get(row, "branch_id", "branch_$(idx)"))
                for (idx, row) in enumerate(group)]
            width = append_bv_domain_header!(
                lines,
                "decoder_branch",
                var_name,
                domain,
            )
            for (idx, row) in enumerate(group)
                condition = semantic_row_condition_smt2(row)
                condition === nothing && continue
                push!(
                    lines,
                    implication_smt2(
                        condition,
                        "(= $(var_name) $(bv_literal(idx - 1, width)))",
                    ),
                )
            end
        end
        return lines
    end

    decoder_guards = [guard for guard in trace.branch_guards if guard.stage == :decoder]
    isempty(decoder_guards) && return String[]

    if !get(trace.metadata, "decoder_guards_exclusive", true)
        # Failure objectives may overlap. Each bit records its predicate;
        # assigning them distinct values of one categorical choice is unsound.
        lines = [
            "; conqec-bv decoder_branch independent predicate bits",
            "(declare-fun conqec_decoder_branch_bv () (_ BitVec $(length(decoder_guards))))",
        ]
        for (idx, guard) in enumerate(decoder_guards)
            bit = idx - 1
            push!(lines, "; bit $(bit): $(guard.id)")
            push!(lines, "(assert (= ((_ extract $(bit) $(bit)) conqec_decoder_branch_bv) " *
                "(ite $(expr_to_smt2(guard.condition)) #b1 #b0)))")
        end
        return lines
    end

    domain = [guard.id for guard in decoder_guards]
    lines = String[]
    width = append_bv_domain_header!(
        lines,
        "decoder_branch",
        "conqec_decoder_branch_bv",
        domain,
    )
    for (idx, guard) in enumerate(decoder_guards)
        push!(
            lines,
            "(assert (=> " *
            expr_to_smt2(guard.condition) *
            " (= conqec_decoder_branch_bv " *
            bv_literal(idx - 1, width) *
            ")))",
        )
    end
    return lines
end

function decoder_choice_bv_annotations(trace::ConcolicTrace)
    rows = decoder_recovery_semantics(trace)
    if !isempty(rows)
        lines = String[]
        groups = semantic_row_groups(rows)
        for group in groups
            key = semantic_row_group_key(first(group))
            var_name = grouped_bv_name("conqec_decoder_choice_bv", key, length(groups))
            domain = String[]
            for row in group
                push_unique_annotation!(domain, annotation_get(row, "decoder_output", nothing))
            end
            isempty(domain) && continue

            width = append_bv_domain_header!(
                lines,
                "decoder_choice",
                var_name,
                domain,
            )
            for row in group
                condition = semantic_row_condition_smt2(row)
                condition === nothing && continue
                idx = annotation_index(domain, annotation_get(row, "decoder_output", nothing))
                idx === nothing && continue
                push!(
                    lines,
                    implication_smt2(
                        condition,
                        "(= $(var_name) $(bv_literal(idx, width)))",
                    ),
                )
            end
        end
        return lines
    end

    domain = String[]
    haskey(trace.decoder_decisions, "actual") &&
        push_unique_annotation!(domain, trace.decoder_decisions["actual"])
    haskey(trace.decoder_decisions, "expected") &&
        push_unique_annotation!(domain, trace.decoder_decisions["expected"])
    isempty(domain) && return String[]

    lines = String[]
    width = append_bv_domain_header!(
        lines,
        "decoder_choice",
        "conqec_decoder_choice_bv",
        domain,
    )
    if haskey(trace.decoder_decisions, "actual")
        idx = annotation_index(domain, trace.decoder_decisions["actual"])
        idx === nothing || push!(
            lines,
            "(assert (= conqec_decoder_choice_bv $(bv_literal(idx, width))))",
        )
    end
    return lines
end

function recovery_choice_bv_annotations(trace::ConcolicTrace)
    rows = decoder_recovery_semantics(trace)
    if !isempty(rows)
        lines = String[]
        groups = semantic_row_groups(rows)
        for group in groups
            key = semantic_row_group_key(first(group))
            decoder_var = grouped_bv_name("conqec_decoder_choice_bv", key, length(groups))
            recovery_var = grouped_bv_name("conqec_recovery_choice_bv", key, length(groups))
            decoder_domain = String[]
            recovery_domain = String[]
            for row in group
                push_unique_annotation!(decoder_domain, annotation_get(row, "decoder_output", nothing))
                push_unique_annotation!(recovery_domain, annotation_get(row, "recovery", nothing))
            end
            isempty(decoder_domain) && continue
            isempty(recovery_domain) && continue

            recovery_width = append_bv_domain_header!(
                lines,
                "recovery_choice",
                recovery_var,
                recovery_domain,
            )
            decoder_width = bv_width_for_choices(length(decoder_domain))
            for row in group
                recovery_idx = annotation_index(recovery_domain, annotation_get(row, "recovery", nothing))
                decoder_idx = annotation_index(decoder_domain, annotation_get(row, "decoder_output", nothing))
                recovery_idx === nothing && continue
                condition = semantic_row_condition_smt2(row)
                if condition !== nothing
                    # Artifact-contract marker for the ungrouped bit-flip case:
                    # "(= conqec_recovery_choice_bv $(bv_literal(recovery_idx, recovery_width)))"
                    push!(
                        lines,
                        implication_smt2(
                            condition,
                            "(= $(recovery_var) $(bv_literal(recovery_idx, recovery_width)))",
                        ),
                    )
                end
                decoder_idx === nothing && continue
                # Artifact-contract marker for the ungrouped bit-flip case:
                # "(= conqec_decoder_choice_bv $(bv_literal(decoder_idx, decoder_width)))"
                push!(
                    lines,
                    implication_smt2(
                        "(= $(decoder_var) $(bv_literal(decoder_idx, decoder_width)))",
                        "(= $(recovery_var) $(bv_literal(recovery_idx, recovery_width)))",
                    ),
                )
            end
        end
        return lines
    end

    domain = String[]
    for action in trace.recovery_actions
        push_unique_annotation!(domain, action)
    end
    expected_recovery = annotation_get(trace.metadata, "expected_recovery", nothing)
    expected_recovery === nothing || push_unique_annotation!(domain, expected_recovery)
    isempty(domain) && return String[]

    lines = String[]
    width = append_bv_domain_header!(
        lines,
        "recovery_choice",
        "conqec_recovery_choice_bv",
        domain,
    )
    if !isempty(trace.recovery_actions)
        idx = annotation_index(domain, first(trace.recovery_actions))
        idx === nothing || push!(
            lines,
            "(assert (= conqec_recovery_choice_bv $(bv_literal(idx, width))))",
        )
    end
    return lines
end

function branch_bv_annotation_smt2(trace::ConcolicTrace)
    lines = String[]
    append!(lines, syndrome_semantics_smt2(trace))
    append!(lines, decoder_branch_bv_annotations(trace))
    append!(lines, decoder_choice_bv_annotations(trace))
    append!(lines, recovery_choice_bv_annotations(trace))
    return lines
end

function append_capacity_combinations!(out::Vector{Vector{Symbol}},
    vars::Vector{Symbol},
    active::Vector{Symbol},
    start_index::Int,
    remaining::Int)

    if remaining == 0
        push!(out, copy(active))
        return out
    end

    stop_index = length(vars) - remaining + 1
    for idx in start_index:stop_index
        push!(active, vars[idx])
        append_capacity_combinations!(out, vars, active, idx + 1, remaining - 1)
        pop!(active)
    end
    return out
end

function fault_capacity_constraint(fault_vars::Vector{Symbol}, max_weight::Integer)
    max_weight >= 0 ||
        error("max_weight must be non-negative, got $(max_weight)")
    max_weight >= length(fault_vars) && return bconst(true)
    max_weight == 0 &&
        return band((bnot(boolvar(var)) for var in fault_vars)...)

    combinations = Vector{Symbol}[]
    append_capacity_combinations!(
        combinations,
        fault_vars,
        Symbol[],
        1,
        Int(max_weight) + 1,
    )
    clauses = BoolExpr[]
    for combo in combinations
        push!(clauses, bor((bnot(boolvar(var)) for var in combo)...))
    end
    return band(clauses...)
end

function add_fault_capacity_constraint(constraints::AbstractVector{<:BoolExpr},
    fault_vars::Vector{Symbol};
    max_weight=nothing)

    max_weight === nothing && return BoolExpr[constraint for constraint in constraints]
    capacity = fault_capacity_constraint(fault_vars, Int(max_weight))
    capacity isa BoolConst && capacity.value &&
        return BoolExpr[constraint for constraint in constraints]
    out = BoolExpr[constraint for constraint in constraints]
    push!(out, capacity)
    return out
end

function fault_capacity_smt2_lines(fault_vars::Vector{Symbol}, max_weight)
    max_weight === nothing && return String[]
    weight = Int(max_weight)
    weight >= 0 || error("max_weight must be non-negative, got $(weight)")
    weight >= length(fault_vars) && return String[]
    length(fault_vars) <= 32 && return String[]

    limit = weight + 1
    aux(idx, count) = "conqec_capacity_atleast_" * string(idx) * "_" * string(count)
    lines = String[]
    for idx in eachindex(fault_vars), count in 1:limit
        push!(lines, "(declare-fun " * aux(idx, count) * " () Bool)")
    end
    first_var = smt_symbol(fault_vars[1])
    push!(lines, "(assert (= " * aux(1, 1) * " " * first_var * "))")
    for count in 2:limit
        push!(lines, "(assert (not " * aux(1, count) * "))")
    end
    for idx in 2:length(fault_vars)
        var = smt_symbol(fault_vars[idx])
        push!(lines, "(assert (= " * aux(idx, 1) * " (or " *
            aux(idx - 1, 1) * " " * var * ")))")
        for count in 2:limit
            push!(lines, "(assert (= " * aux(idx, count) * " (or " *
                aux(idx - 1, count) * " (and " * aux(idx - 1, count - 1) *
                " " * var * "))))")
        end
    end
    push!(lines, "(assert (not " * aux(length(fault_vars), limit) * "))")
    return lines
end

function add_capacity_or_smt2_lines(constraints::AbstractVector{<:BoolExpr},
    fault_vars::Vector{Symbol}, max_weight, extra_lines::Vector{String})

    lines = fault_capacity_smt2_lines(fault_vars, max_weight)
    if !isempty(lines)
        append!(extra_lines, lines)
        return BoolExpr[constraint for constraint in constraints], extra_lines
    end
    return add_fault_capacity_constraint(constraints, fault_vars; max_weight=max_weight),
        extra_lines
end

function constraints_to_smt2(constraints::AbstractVector{<:BoolExpr}, fault_vars::Vector{Symbol};
    logic="QF_BV",
    include_get_model=true,
    extra_lines=String[])

    lines = String[
        "(set-logic " * String(logic) * ")",
    ]
    append!(lines, declare_bool_vars_smt2(fault_vars))
    append!(lines, String.(extra_lines))
    append!(lines, ["(assert " * expr_to_smt2(constraint) * ")" for constraint in constraints])
    push!(lines, "(check-sat)")
    include_get_model && push!(lines, "(get-model)")
    return join(lines, "\n") * "\n"
end

struct ConstraintQuery
    text::String
    variable_map::Vector{Symbol}
    fault_vars::Vector{Symbol}
    selected_branch_id::Union{Nothing,String}
    selected_branch_index::Union{Nothing,Int}
    branch_constraint_count::Int
    syndrome_variable_count::Int
    fault_variable_count::Int
    query_hash::String
    metadata::Dict{String,Any}
end

function ConstraintQuery(text::AbstractString,
    variable_map::Vector{Symbol},
    fault_vars::Vector{Symbol};
    selected_branch_id=nothing,
    selected_branch_index=nothing,
    branch_constraint_count::Integer=0,
    syndrome_variable_count::Integer=0,
    metadata=Dict{String,Any}())

    query_text = String(text)
    return ConstraintQuery(
        query_text,
        copy(variable_map),
        copy(fault_vars),
        selected_branch_id === nothing ? nothing : String(selected_branch_id),
        selected_branch_index === nothing ? nothing : Int(selected_branch_index),
        Int(branch_constraint_count),
        Int(syndrome_variable_count),
        length(fault_vars),
        bytes2hex(sha256(query_text)),
        Dict{String,Any}(metadata),
    )
end

query_bytes(query::ConstraintQuery) = sizeof(query.text)

struct SMTLibExportBackend <: AbstractConcolicSolver
    fault_vars::Vector{Symbol}
    logic::String
    include_get_model::Bool
end

SMTLibExportBackend(fault_vars::Vector{Symbol}; logic="QF_BV", include_get_model=true) =
    SMTLibExportBackend(copy(fault_vars), String(logic), Bool(include_get_model))

const SmtLibExportSolver = SMTLibExportBackend

solver_name(::SMTLibExportBackend) = "smtlib-export"

solver_fault_vars(solver::SMTLibExportBackend) = copy(solver.fault_vars)

function solver_query_text(
    solver::SMTLibExportBackend,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    return constraints_to_smt2(
        constraints,
        solver.fault_vars;
        logic=solver.logic,
        include_get_model=solver.include_get_model,
    )
end

function solve_model(
    solver::SMTLibExportBackend,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    query = solver_query_text(solver, constraints; avoid=avoid)
    return SolverResult(
        :exported,
        nothing,
        query,
        solver_name(solver),
        Dict{String,Any}(
            "backend" => solver_name(solver),
            "solver_status" => "EXPORTED",
            "query_bytes" => sizeof(query),
            "query_hash" => bytes2hex(sha256(query)),
            "fault_variable_count" => length(solver.fault_vars),
        ),
    )
end

struct ExternalSmtSolver <: AbstractConcolicSolver
    fault_vars::Vector{Symbol}
    command::String
    args::Vector{String}
    logic::String
end

ExternalSmtSolver(fault_vars::Vector{Symbol};
    command="z3",
    args=["-smt2"],
    logic="QF_BV") =
    ExternalSmtSolver(copy(fault_vars), String(command), String.(args), String(logic))

solver_name(solver::ExternalSmtSolver) =
    string("external-smt:", solver.command)

solver_fault_vars(solver::ExternalSmtSolver) = copy(solver.fault_vars)

struct Z3Backend <: AbstractConcolicSolver
    fault_vars::Vector{Symbol}
    solver_path::String
    args::Vector{String}
    logic::String
    timeout_ms::Int
    max_weight::Union{Nothing,Int}
    keep_query_files::Bool
    query_dir::Union{Nothing,String}
end

Z3Backend(fault_vars::Vector{Symbol};
    solver_path="z3",
    args=["-smt2"],
    logic="QF_BV",
    timeout_ms=30000,
    max_weight=nothing,
    keep_query_files=false,
    query_dir=nothing) =
    Z3Backend(
        copy(fault_vars),
        String(solver_path),
        String.(args),
        String(logic),
        Int(timeout_ms),
        max_weight === nothing ? nothing : Int(max_weight),
        Bool(keep_query_files),
        query_dir === nothing ? nothing : String(query_dir),
    )

struct BitwuzlaBackend <: AbstractConcolicSolver
    fault_vars::Vector{Symbol}
    solver_path::String
    args::Vector{String}
    logic::String
    timeout_ms::Int
    max_weight::Union{Nothing,Int}
    keep_query_files::Bool
    query_dir::Union{Nothing,String}
end

BitwuzlaBackend(fault_vars::Vector{Symbol};
    solver_path="bitwuzla",
    args=String[],
    logic="QF_BV",
    timeout_ms=30000,
    max_weight=nothing,
    keep_query_files=false,
    query_dir=nothing) =
    BitwuzlaBackend(
        copy(fault_vars),
        String(solver_path),
        String.(args),
        String(logic),
        Int(timeout_ms),
        max_weight === nothing ? nothing : Int(max_weight),
        Bool(keep_query_files),
        query_dir === nothing ? nothing : String(query_dir),
    )

solver_name(::Z3Backend) = "z3"
solver_name(::BitwuzlaBackend) = "bitwuzla"

solver_fault_vars(solver::Z3Backend) = copy(solver.fault_vars)
solver_fault_vars(solver::BitwuzlaBackend) = copy(solver.fault_vars)

solver_max_weight(solver::Z3Backend) = solver.max_weight
solver_max_weight(solver::BitwuzlaBackend) = solver.max_weight

solver_command(solver::Z3Backend) = solver.solver_path
solver_command(solver::BitwuzlaBackend) = solver.solver_path
solver_args(solver::Z3Backend) = solver.args
solver_args(solver::BitwuzlaBackend) = solver.args
solver_logic(solver::Z3Backend) = solver.logic
solver_logic(solver::BitwuzlaBackend) = solver.logic
solver_timeout_ms(solver::Z3Backend) = solver.timeout_ms
solver_timeout_ms(solver::BitwuzlaBackend) = solver.timeout_ms
solver_keep_query_files(solver::Z3Backend) = solver.keep_query_files
solver_keep_query_files(solver::BitwuzlaBackend) = solver.keep_query_files
solver_query_dir(solver::Z3Backend) = solver.query_dir
solver_query_dir(solver::BitwuzlaBackend) = solver.query_dir

function avoid_assignment_constraint(fault_vars::Vector{Symbol}, key::AbstractString)
    assignments = Dict{Symbol,Bool}()
    for part in split(String(key), ';')
        isempty(part) && continue
        pieces = split(part, '='; limit=2)
        length(pieces) == 2 || error("invalid avoided assignment key: $(key)")
        value = pieces[2]
        value in ("0", "1") || error("invalid avoided assignment value in: $(key)")
        assignments[Symbol(pieces[1])] = value == "1"
    end

    terms = BoolExpr[]
    for var in fault_vars
        haskey(assignments, var) || error("avoided assignment missing $(var): $(key)")
        push!(terms, assignments[var] ? bnot(boolvar(var)) : boolvar(var))
    end
    return bor(terms...)
end

function constraints_with_avoidance(fault_vars::Vector{Symbol},
    constraints::AbstractVector{<:BoolExpr},
    avoid)

    out = BoolExpr[constraint for constraint in constraints]
    for key in avoid
        push!(out, avoid_assignment_constraint(fault_vars, key))
    end
    return out
end

function backend_query_path(query_hash::AbstractString, query_dir)
    dir = query_dir === nothing ? tempdir() : String(query_dir)
    mkpath(dir)
    hash_text = String(query_hash)
    hash_prefix = hash_text[1:min(length(hash_text), 16)]
    return joinpath(dir, "conqec_" * hash_prefix * ".smt2")
end

function branch_query_constraint_count(trace::ConcolicTrace, branch_index::Integer;
    full_path=true)
    constraints = full_path ?
        full_flipped_path_constraint(trace, branch_index) :
        flipped_path_constraint(trace, branch_index)
    return length(constraints) + (max_fault_weight(trace) === nothing ? 0 : 1)
end

function build_query(path_constraint::AbstractVector{<:BoolExpr},
    flipped_branch,
    fault_model,
    options=Dict{String,Any}())

    fault_vars = if fault_model isa AbstractVector
        [bool_constraint_symbol(var) for var in fault_model]
    elseif fault_model isa AbstractDict
        vars = haskey(fault_model, "fault_vars") ? fault_model["fault_vars"] :
            get(fault_model, :fault_vars, nothing)
        vars === nothing && error("fault_model dictionary must contain fault_vars")
        [bool_constraint_symbol(var) for var in vars]
    else
        error("unsupported fault_model for build_query: $(typeof(fault_model))")
    end

    logic = String(get(options, "logic", get(options, :logic, "QF_BV")))
    include_get_model = Bool(get(options, "include_get_model",
        get(options, :include_get_model, true)))
    extra_lines = String.(get(options, "extra_lines", get(options, :extra_lines, String[])))
    query_text = constraints_to_smt2(
        path_constraint,
        fault_vars;
        logic=logic,
        include_get_model=include_get_model,
        extra_lines=extra_lines,
    )
    branch_id = flipped_branch isa BranchGuard ? flipped_branch.id : nothing
    return ConstraintQuery(
        query_text,
        fault_vars,
        fault_vars;
        selected_branch_id=branch_id,
        selected_branch_index=get(options, "selected_branch_index",
            get(options, :selected_branch_index, nothing)),
        branch_constraint_count=length(path_constraint),
        syndrome_variable_count=Int(get(options, "syndrome_variable_count",
            get(options, :syndrome_variable_count, 0))),
        metadata=Dict{String,Any}(string(key) => value for (key, value) in options),
    )
end

function build_query(trace::ConcolicTrace, branch_index::Integer;
    include_get_model=true,
    full_path=true,
    include_capacity=true,
    include_bv_annotations=true,
    logic="QF_BV",
    avoid=Set{String}(),
    extra_constraints=BoolExpr[])

    guard = require_path_constraint_branch(trace, branch_index)
    constraints = branch_query_constraints(
        trace,
        branch_index;
        full_path=full_path,
        include_capacity=false,
    )
    append!(constraints, extra_constraints)
    constraints = constraints_with_avoidance(trace.fault_vars, constraints, avoid)
    extra_lines = include_bv_annotations ? branch_bv_annotation_smt2(trace) : String[]
    if include_capacity
        constraints, extra_lines = add_capacity_or_smt2_lines(
            constraints,
            trace.fault_vars,
            max_fault_weight(trace),
            extra_lines,
        )
    end
    query_text = constraints_to_smt2(
        constraints,
        trace.fault_vars;
        logic=logic,
        include_get_model=include_get_model,
        extra_lines=extra_lines,
    )
    return ConstraintQuery(
        query_text,
        trace.fault_vars,
        trace.fault_vars;
        selected_branch_id=guard.id,
        selected_branch_index=branch_index,
        branch_constraint_count=branch_query_constraint_count(
            trace,
            branch_index;
            full_path=full_path,
        ),
        syndrome_variable_count=length(trace.syndrome_exprs),
        metadata=Dict{String,Any}(
            "subject" => trace.subject_name,
            "selected_branch_stage" => string(guard.stage),
            "max_fault_weight" => include_capacity ? max_fault_weight(trace) : nothing,
            "avoid_count" => length(avoid),
        ),
    )
end

function parse_model(solver_output::AbstractString, variable_map::Vector{Symbol})
    return parse_smt_bool_model(solver_output, variable_map)
end

const SOLVER_VERSION_CACHE = Dict{String,String}()

function solver_version(command::AbstractString)
    key = String(command)
    haskey(SOLVER_VERSION_CACHE, key) && return SOLVER_VERSION_CACHE[key]
    try
        SOLVER_VERSION_CACHE[key] = strip(read(Cmd([key, "--version"]), String))
    catch
        SOLVER_VERSION_CACHE[key] = "unknown"
    end
    return SOLVER_VERSION_CACHE[key]
end

function solver_status_text(status::Symbol)
    status == :sat && return "SAT"
    status == :unsat && return "UNSAT"
    status == :unknown && return "UNKNOWN"
    status == :timeout && return "TIMEOUT"
    status == :error && return "ERROR"
    status == :exported && return "EXPORTED"
    status == :unavailable && return "ERROR"
    return uppercase(String(status))
end

function query_stats(query::ConstraintQuery, solver_result::SolverResult)
    out = Dict{String,Any}(
        "backend" => solver_result.backend,
        "solver_status" => solver_status_text(solver_result.status),
        "query_hash" => query.query_hash,
        "query_bytes" => query_bytes(query),
        "fault_variable_count" => query.fault_variable_count,
        "syndrome_variable_count" => query.syndrome_variable_count,
        "branch_constraint_count" => query.branch_constraint_count,
        "selected_branch_id" => query.selected_branch_id,
        "selected_branch_index" => query.selected_branch_index,
    )
    for (key, value) in solver_result.metadata
        out[string(key)] = value
    end
    return out
end

function solve_query(backend::AbstractConstraintBackend, query::ConstraintQuery)
    error("backend $(solver_name(backend)) does not solve SMT-LIB queries directly")
end

function solve_query(backend::SMTLibExportBackend, query::ConstraintQuery)
    result = SolverResult(
        :exported,
        nothing,
        query.text,
        solver_name(backend),
        Dict{String,Any}(
            "backend" => solver_name(backend),
            "solver_status" => "EXPORTED",
            "solver_path" => nothing,
            "solver_version" => nothing,
            "query_file_path" => nothing,
            "query_hash" => query.query_hash,
            "query_bytes" => query_bytes(query),
            "fault_variable_count" => query.fault_variable_count,
            "syndrome_variable_count" => query.syndrome_variable_count,
            "branch_constraint_count" => query.branch_constraint_count,
            "selected_branch_id" => query.selected_branch_id,
            "selected_branch_index" => query.selected_branch_index,
            "solve_time_ms" => 0.0,
            "timed_out" => false,
            "timeout_ms" => nothing,
            "solver_args" => String[],
            "replay_success" => nothing,
        ),
    )
    return result
end

function external_command_output(command::AbstractString,
    args::Vector{String},
    query::ConstraintQuery;
    timeout_ms::Integer=30000,
    keep_query_file::Bool=false,
    query_dir=nothing)

    query_path = keep_query_file ?
        backend_query_path(query.query_hash, query_dir) :
        tempname() * ".smt2"
    write(query_path, query.text)
    stdout_path = tempname()
    stderr_path = tempname()
    start_ns = time_ns()
    timed_out = false
    exitcode = -1
    stdout_text = ""
    stderr_text = ""
    try
        stdout_io = open(stdout_path, "w")
        stderr_io = open(stderr_path, "w")
        proc = try
            run(
                pipeline(
                    ignorestatus(Cmd([String(command); args; query_path]));
                    stdout=stdout_io,
                    stderr=stderr_io,
                );
                wait=false,
            )
        finally
            close(stdout_io)
            close(stderr_io)
        end

        while process_running(proc)
            elapsed_ms = (time_ns() - start_ns) / 1_000_000
            if elapsed_ms > timeout_ms
                timed_out = true
                kill(proc)
                break
            end
            sleep(0.005)
        end
        try
            wait(proc)
        catch
        end
        exitcode = proc.exitcode
        stdout_text = isfile(stdout_path) ? read(stdout_path, String) : ""
        stderr_text = isfile(stderr_path) ? read(stderr_path, String) : ""
    finally
        rm(stdout_path; force=true)
        rm(stderr_path; force=true)
        keep_query_file || rm(query_path; force=true)
    end
    elapsed_ms = (time_ns() - start_ns) / 1_000_000
    return Dict{String,Any}(
        "stdout" => stdout_text,
        "stderr" => stderr_text,
        "exitcode" => exitcode,
        "timed_out" => timed_out,
        "elapsed_ms" => elapsed_ms,
        "query_file_path" => query_path,
    )
end

function solve_query(backend::Union{Z3Backend,BitwuzlaBackend}, query::ConstraintQuery)
    command = solver_command(backend)
    version = solver_version(command)
    output = try
        external_command_output(
            command,
            solver_args(backend),
            query;
            timeout_ms=solver_timeout_ms(backend),
            keep_query_file=solver_keep_query_files(backend),
            query_dir=solver_query_dir(backend),
        )
    catch err
        return SolverResult(
            :error,
            nothing,
            query.text,
            solver_name(backend),
            Dict{String,Any}(
                "backend" => solver_name(backend),
                "solver_path" => command,
                "solver_version" => version,
                "solver_status" => "ERROR",
                "solver_error" => sprint(showerror, err),
                "query_hash" => query.query_hash,
                "query_bytes" => query_bytes(query),
                "fault_variable_count" => query.fault_variable_count,
                "syndrome_variable_count" => query.syndrome_variable_count,
                "branch_constraint_count" => query.branch_constraint_count,
                "selected_branch_id" => query.selected_branch_id,
                "selected_branch_index" => query.selected_branch_index,
                "query_file_path" => nothing,
                "solve_time_ms" => 0.0,
                "timed_out" => false,
                "timeout_ms" => solver_timeout_ms(backend),
                "solver_args" => solver_args(backend),
            ),
        )
    end

    status = :error
    model = nothing
    if Bool(output["timed_out"])
        status = :timeout
    else
        try
            status, model = parse_model(String(output["stdout"]), query.variable_map)
        catch err
            status = :error
            output["parse_error"] = sprint(showerror, err)
        end
    end

    metadata = Dict{String,Any}(
        "backend" => solver_name(backend),
        "solver_path" => command,
        "solver_version" => version,
        "query_file_path" => output["query_file_path"],
        "query_hash" => query.query_hash,
        "query_bytes" => query_bytes(query),
        "fault_variable_count" => query.fault_variable_count,
        "syndrome_variable_count" => query.syndrome_variable_count,
        "branch_constraint_count" => query.branch_constraint_count,
        "selected_branch_id" => query.selected_branch_id,
        "selected_branch_index" => query.selected_branch_index,
        "solver_status" => solver_status_text(status),
        "solve_time_ms" => round(Float64(output["elapsed_ms"]); digits=3),
        "timed_out" => Bool(output["timed_out"]),
        "timeout_ms" => solver_timeout_ms(backend),
        "solver_args" => solver_args(backend),
        "stdout" => output["stdout"],
        "stderr" => output["stderr"],
        "exitcode" => output["exitcode"],
        "replay_success" => nothing,
    )
    haskey(output, "parse_error") && (metadata["parse_error"] = output["parse_error"])
    if model !== nothing
        metadata["parsed_model"] = Dict{String,Any}(
            string(var) => model_bool(model, var)
            for var in query.variable_map
        )
        metadata["generated_concrete_fault_pattern"] =
            model_to_fault_pattern(query.fault_vars, model)
    end
    return SolverResult(status, model, query.text, solver_name(backend), metadata)
end

function solve_query(query::ConstraintQuery, backend_options::AbstractDict)
    backend = get(backend_options, "backend", get(backend_options, :backend, nothing))
    backend isa AbstractConstraintBackend ||
        error("backend_options must contain an AbstractConstraintBackend under backend")
    return solve_query(backend, query)
end

function constraint_backend_from_name(fault_vars::Vector{Symbol};
    backend="z3",
    solver_path=nothing,
    solver_timeout_ms=30000,
    max_weight=1,
    keep_query_files=false,
    query_dir=nothing)

    name = lowercase(strip(String(backend)))
    max_weight_value = max_weight === nothing ? nothing : Int(max_weight)
    if name in ("enumerator", "local", "local-enumerator", "bruteforce", "bruteforce-bool")
        return LocalEnumeratorBackend(fault_vars; max_weight=max_weight_value)
    elseif name in ("smtlib", "smtlib-export")
        return SMTLibExportBackend(fault_vars)
    elseif name == "z3"
        return Z3Backend(
            fault_vars;
            solver_path=solver_path === nothing ? "z3" : solver_path,
            timeout_ms=solver_timeout_ms,
            max_weight=max_weight_value,
            keep_query_files=keep_query_files,
            query_dir=query_dir,
        )
    elseif name == "bitwuzla"
        return BitwuzlaBackend(
            fault_vars;
            solver_path=solver_path === nothing ? "bitwuzla" : solver_path,
            timeout_ms=solver_timeout_ms,
            max_weight=max_weight_value,
            keep_query_files=keep_query_files,
            query_dir=query_dir,
        )
    end
    error("--backend must be enumerator, z3, bitwuzla, or smtlib; got $(backend)")
end

function smt_regex_literal(text::AbstractString)
    return replace(String(text), r"([\\.^$|?*+()\[\]{}])" => s"\\\1")
end

function solver_query_text(
    solver::ExternalSmtSolver,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    return constraints_to_smt2(
        constraints_with_avoidance(solver.fault_vars, constraints, avoid),
        solver.fault_vars;
        logic=solver.logic,
        include_get_model=true,
    )
end

function solver_query_text(
    solver::Union{Z3Backend,BitwuzlaBackend},
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    constraints_with_capacity = add_fault_capacity_constraint(
        constraints,
        solver_fault_vars(solver);
        max_weight=solver_max_weight(solver),
    )
    query = build_query(
        constraints_with_avoidance(solver_fault_vars(solver), constraints_with_capacity, avoid),
        nothing,
        solver_fault_vars(solver),
        Dict{String,Any}("logic" => solver_logic(solver), "include_get_model" => true),
    )
    return query.text
end

function parse_smt_bool_model(output::AbstractString, fault_vars::Vector{Symbol})
    lines = split(strip(String(output)), '\n')
    first_line = isempty(lines) ? "" : first(lines)
    first_line == "unsat" && return :unsat, nothing
    first_line == "unknown" && return :unknown, nothing
    first_line == "sat" || error("unexpected SMT solver output: $(first_line)")
    !isempty(fault_vars) && occursin("(define-fun", output) ||
        isempty(fault_vars) ||
        error("SMT solver reported sat but did not return model assignments")

    model = Dict{Symbol,Bool}()
    for var in fault_vars
        name = smt_regex_literal(smt_symbol(var))
        pattern = Regex("\\(define-fun\\s+" * name * "\\s+\\(\\)\\s+Bool\\s+(true|false)\\s*\\)")
        matched = match(pattern, output)
        model[var] = matched !== nothing && matched.captures[1] == "true"
    end
    return :sat, model
end

function run_external_smt_command(solver::ExternalSmtSolver, query::AbstractString)
    path = tempname() * ".smt2"
    write(path, query)
    try
        out = Pipe()
        err = Pipe()
        proc = run(
            pipeline(ignorestatus(Cmd([solver.command; solver.args; path])); stdout=out, stderr=err);
            wait=false,
        )
        close(out.in)
        close(err.in)
        stdout_text = read(out, String)
        stderr_text = read(err, String)
        wait(proc)
        if proc.exitcode != 0 && isempty(strip(stdout_text))
            error(strip(stderr_text))
        end
        return stdout_text
    finally
        isfile(path) && rm(path)
    end
end

function solve_model(
    solver::ExternalSmtSolver,
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    query = solver_query_text(solver, constraints; avoid=avoid)
    output = try
        run_external_smt_command(solver, query)
    catch err
        err isa Base.IOError || rethrow()
        return SolverResult(:unavailable, nothing, query, solver_name(solver))
    end
    status, model = parse_smt_bool_model(output, solver.fault_vars)
    return SolverResult(status, model, query, solver_name(solver))
end

function solve_model(
    solver::Union{Z3Backend,BitwuzlaBackend},
    constraints::AbstractVector{<:BoolExpr};
    avoid=Set{String}())

    constraints_with_capacity = add_fault_capacity_constraint(
        constraints,
        solver_fault_vars(solver);
        max_weight=solver_max_weight(solver),
    )
    query = build_query(
        constraints_with_avoidance(solver_fault_vars(solver), constraints_with_capacity, avoid),
        nothing,
        solver_fault_vars(solver),
        Dict{String,Any}("logic" => solver_logic(solver), "include_get_model" => true),
    )
    return solve_query(solver, query)
end

function branch_query_smt2(trace::ConcolicTrace, branch_index::Integer;
    include_get_model=true,
    full_path=true,
    include_capacity=true,
    include_bv_annotations=true,
    logic="QF_BV",
    avoid=Set{String}())

    constraints = branch_query_constraints(
        trace,
        branch_index;
        full_path=full_path,
        include_capacity=false,
    )
    constraints = constraints_with_avoidance(trace.fault_vars, constraints, avoid)
    extra_lines = include_bv_annotations ? branch_bv_annotation_smt2(trace) : String[]
    if include_capacity
        constraints, extra_lines = add_capacity_or_smt2_lines(
            constraints,
            trace.fault_vars,
            max_fault_weight(trace),
            extra_lines,
        )
    end
    return constraints_to_smt2(
        constraints,
        trace.fault_vars;
        logic=logic,
        include_get_model=include_get_model,
        extra_lines=extra_lines,
    )
end

function branch_query_constraints(trace::ConcolicTrace, branch_index::Integer;
    full_path=true,
    include_capacity=true)

    constraints = full_path ?
        full_flipped_path_constraint(trace, branch_index) :
        flipped_path_constraint(trace, branch_index)
    include_capacity || return constraints
    return add_fault_capacity_constraint(
        constraints,
        trace.fault_vars;
        max_weight=max_fault_weight(trace),
    )
end

function ensure_branch_solver_fault_vars(solver::AbstractConcolicSolver,
    trace::ConcolicTrace)

    solver_fault_vars(solver) == trace.fault_vars ||
        error("solver fault variables do not match trace fault variables")
    return nothing
end

function solve_branch_query(solver::AbstractConcolicSolver,
    trace::ConcolicTrace,
    branch_index::Integer;
    avoid=Set{String}(),
    ordered_model=true)

    ensure_branch_solver_fault_vars(solver, trace)
    return solve_model(
        solver,
        branch_query_constraints(trace, branch_index);
        avoid=avoid,
    )
end

function solve_branch_query(solver::LocalEnumeratorBackend,
    trace::ConcolicTrace,
    branch_index::Integer;
    avoid=Set{String}(),
    ordered_model=true)

    ensure_branch_solver_fault_vars(solver, trace)
    return solve_model(
        solver,
        branch_query_constraints(trace, branch_index; include_capacity=false);
        avoid=avoid,
    )
end

function solve_branch_query(solver::SmtLibExportSolver,
    trace::ConcolicTrace,
    branch_index::Integer;
    avoid=Set{String}(),
    ordered_model=true)

    ensure_branch_solver_fault_vars(solver, trace)
    query = build_query(
        trace,
        branch_index;
        include_get_model=solver.include_get_model,
        logic=solver.logic,
        avoid=avoid,
    )
    return SolverResult(
        :exported,
        nothing,
        query.text,
        solver_name(solver),
        query_stats(query, SolverResult(:exported, nothing, query.text, solver_name(solver))),
    )
end

function solve_branch_query(solver::ExternalSmtSolver,
    trace::ConcolicTrace,
    branch_index::Integer;
    avoid=Set{String}(),
    ordered_model=true)

    ensure_branch_solver_fault_vars(solver, trace)
    query = branch_query_smt2(
        trace,
        branch_index;
        include_get_model=true,
        logic=solver.logic,
        avoid=avoid,
    )
    output = try
        run_external_smt_command(solver, query)
    catch err
        err isa Base.IOError || rethrow()
        return SolverResult(:unavailable, nothing, query, solver_name(solver))
    end
    status, model = parse_smt_bool_model(output, solver.fault_vars)
    return SolverResult(status, model, query, solver_name(solver))
end

function ordered_single_fault_model_result(
    solver::Union{Z3Backend,BitwuzlaBackend},
    trace::ConcolicTrace,
    branch_index::Integer,
    avoid,
    result::SolverResult)

    result.status == :sat || return result
    result.model === nothing && return result
    solver_max_weight(solver) == 1 || return result

    current_active = findfirst(var -> model_bool(result.model, var), trace.fault_vars)
    current_active === nothing && return result

    for idx in 1:(current_active - 1)
        extra_constraints = BoolExpr[boolvar(trace.fault_vars[idx])]
        for previous in 1:(idx - 1)
            push!(extra_constraints, bnot(boolvar(trace.fault_vars[previous])))
        end
        query = build_query(
            trace,
            branch_index;
            include_get_model=true,
            logic=solver_logic(solver),
            avoid=avoid,
            extra_constraints=extra_constraints,
        )
        candidate = solve_query(solver, query)
        candidate.status == :sat || continue
        candidate.metadata["model_selection"] = "ordered_single_fault_preference"
        candidate.metadata["model_selection_original_active_fault"] =
            string(trace.fault_vars[current_active])
        candidate.metadata["model_selection_selected_fault"] =
            string(trace.fault_vars[idx])
        return candidate
    end
    return result
end

function solve_branch_query(solver::Union{Z3Backend,BitwuzlaBackend},
    trace::ConcolicTrace,
    branch_index::Integer;
    avoid=Set{String}(),
    ordered_model=true)

    ensure_branch_solver_fault_vars(solver, trace)
    query = build_query(
        trace,
        branch_index;
        include_get_model=true,
        logic=solver_logic(solver),
        avoid=avoid,
    )
    result = solve_query(solver, query)
    ordered_model || return result
    return ordered_single_fault_model_result(solver, trace, branch_index, avoid, result)
end
