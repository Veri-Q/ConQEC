mutable struct SymbolicStabilizerState
    code_name::String
    pauli::String
    qubit_count::Int
    generator_names::Vector{String}
    generator_supports::Vector{Vector{Int}}
    generator_paulis::Vector{String}
    frame::Vector{BoolExpr}
end

function SymbolicStabilizerState(code_name::AbstractString,
    qubit_count::Integer,
    generator_names::AbstractVector,
    generator_supports::AbstractVector;
    pauli="X",
    generator_paulis=nothing)

    qubit_count >= 1 || error("qubit_count must be positive, got $(qubit_count)")
    length(generator_names) == length(generator_supports) ||
        error("generator names/supports must have the same length")
    normalized_supports = Vector{Int}[]
    for support in generator_supports
        ints = Int[idx for idx in support]
        all(idx -> 1 <= idx <= qubit_count, ints) ||
            error("generator support $(ints) is outside 1:$(qubit_count)")
        push!(normalized_supports, ints)
    end
    paulis = generator_paulis === nothing ?
        [String(pauli) for _ in generator_names] :
        String.(generator_paulis)
    length(paulis) == length(generator_names) ||
        error("generator pauli list must match generator names")

    return SymbolicStabilizerState(
        String(code_name),
        String(pauli),
        Int(qubit_count),
        String.(generator_names),
        normalized_supports,
        paulis,
        BoolExpr[bconst(false) for _ in 1:Int(qubit_count)],
    )
end

function copy_symbolic_stabilizer_state(state::SymbolicStabilizerState)
    return SymbolicStabilizerState(
        state.code_name,
        state.pauli,
        state.qubit_count,
        copy(state.generator_names),
        [copy(support) for support in state.generator_supports],
        copy(state.generator_paulis),
        copy(state.frame),
    )
end

function absorb!(state::SymbolicStabilizerState, guard::BoolExpr, target::Integer;
    pauli=state.pauli)

    1 <= target <= state.qubit_count ||
        error("target qubit $(target) is outside 1:$(state.qubit_count)")
    String(pauli) == state.pauli ||
        error("state $(state.code_name) tracks $(state.pauli) errors, got $(pauli)")
    state.frame[Int(target)] = bxor(state.frame[Int(target)], guard)
    return state
end

function parse_recovery_target(action::AbstractDict)
    target = string(get(action, "target", "none"))
    startswith(target, "q") || return nothing
    matched = match(r"^q([0-9]+)$", target)
    matched === nothing && return nothing
    return parse(Int, matched.captures[1])
end

function absorb_recovery!(state::SymbolicStabilizerState, action::AbstractDict;
    guard=bconst(true))

    pauli = string(get(action, "pauli", "I"))
    pauli == "I" && return state
    pauli == "missing" && return state
    target = parse_recovery_target(action)
    target === nothing && return state
    return absorb!(state, guard, target; pauli=pauli)
end

function xor_bool_exprs(terms::AbstractVector{<:BoolExpr})
    isempty(terms) && return bconst(false)
    expr = terms[1]
    for idx in 2:length(terms)
        expr = bxor(expr, terms[idx])
    end
    return expr
end

function stabilizer_generator_phase_exprs(state::SymbolicStabilizerState)
    return BoolExpr[
        xor_bool_exprs(BoolExpr[state.frame[idx] for idx in support])
        for support in state.generator_supports
    ]
end

function stabilizer_generator_phase_values(state::SymbolicStabilizerState,
    model::AbstractDict)

    return [evaluate(expr, model) for expr in stabilizer_generator_phase_exprs(state)]
end

function symbolic_residual_vector(state::SymbolicStabilizerState, model::AbstractDict)
    return [evaluate(expr, model) for expr in state.frame]
end

function symbolic_residual_error_dict(state::SymbolicStabilizerState, model::AbstractDict)
    residual = symbolic_residual_vector(state, model)
    return Dict{String,Any}(
        "q$(idx)" => residual[idx]
        for idx in eachindex(residual)
    )
end

symbolic_residual_weight(state::SymbolicStabilizerState, model::AbstractDict) =
    count(identity, symbolic_residual_vector(state, model))

symbolic_logical_ok(state::SymbolicStabilizerState, model::AbstractDict) =
    symbolic_residual_weight(state, model) == 0

function stabilizer_generator_summary(state::SymbolicStabilizerState)
    phases = stabilizer_generator_phase_exprs(state)
    return [
        Dict{String,Any}(
            "name" => state.generator_names[idx],
            "pauli" => state.generator_paulis[idx],
            "support" => ["q$(qubit)" for qubit in state.generator_supports[idx]],
            "phase_expr" => expr_to_string(phases[idx]),
        )
        for idx in eachindex(state.generator_names)
    ]
end

function record_symbolic_stabilizer_summary!(trace::ConcolicTrace,
    pre_recovery::SymbolicStabilizerState,
    post_recovery::SymbolicStabilizerState,
    model::AbstractDict)

    trace.metadata["symbolic_stabilizer"] = Dict{String,Any}(
        "code" => pre_recovery.code_name,
        "tracked_pauli" => pre_recovery.pauli,
        "representation" => "symbolic Pauli frame with stabilizer generator phases",
        "pre_recovery_generators" => stabilizer_generator_summary(pre_recovery),
        "post_recovery_generators" => stabilizer_generator_summary(post_recovery),
        "post_recovery_residual" => symbolic_residual_error_dict(post_recovery, model),
        "post_recovery_residual_weight" =>
            symbolic_residual_weight(post_recovery, model),
    )
    return trace
end

function css_decoder_label(x_decoder::AbstractString, z_decoder::AbstractString)
    x_text = String(x_decoder)
    z_text = String(z_decoder)
    if z_text == "none"
        return x_text
    elseif x_text == "none"
        return "Z:" * z_text
    end
    return string("X:", x_text, "|Z:", z_text)
end

function css_recovery_from_decoder_outputs(x_decoder::AbstractString,
    z_decoder::AbstractString;
    source="css_decoder")

    components = Dict{String,Any}[]
    x_text = String(x_decoder)
    z_text = String(z_decoder)
    if x_text == "uncorrectable" || z_text == "uncorrectable"
        return Dict{String,Any}(
            "pauli" => "missing",
            "target" => "uncorrectable",
            "source" => source,
            "components" => components,
        )
    end

    startswith(x_text, "q") && push!(
        components,
        Dict{String,Any}("pauli" => "X", "target" => x_text, "source" => source),
    )
    startswith(z_text, "q") && push!(
        components,
        Dict{String,Any}("pauli" => "Z", "target" => z_text, "source" => source),
    )
    return css_recovery_from_components(components; source=source)
end

function css_recovery_from_components(components::AbstractVector; source="css_decoder")
    normalized = Dict{String,Any}[
        Dict{String,Any}(string(key) => value for (key, value) in component)
        for component in components
    ]
    if isempty(normalized)
        return Dict{String,Any}(
            "pauli" => "I",
            "target" => "none",
            "source" => source,
            "components" => normalized,
        )
    end

    if length(normalized) == 1
        component = normalized[1]
        return Dict{String,Any}(
            "pauli" => String(component["pauli"]),
            "target" => String(component["target"]),
            "source" => source,
            "components" => normalized,
        )
    end

    paulis = [String(component["pauli"]) for component in normalized]
    targets = [String(component["target"]) for component in normalized]
    if sort(paulis) == ["X", "Z"] && length(unique(targets)) == 1
        return Dict{String,Any}(
            "pauli" => "Y",
            "target" => first(targets),
            "source" => source,
            "components" => normalized,
        )
    end

    return Dict{String,Any}(
        "pauli" => join(paulis, "+"),
        "target" => join(targets, "/"),
        "source" => source,
        "components" => normalized,
    )
end

function css_recovery_components(recovery::AbstractDict)
    components = get(recovery, "components", nothing)
    if components isa AbstractVector
        return Dict{String,Any}[
            Dict{String,Any}(string(key) => value for (key, value) in component)
            for component in components
        ]
    end

    pauli = String(get(recovery, "pauli", "I"))
    target = String(get(recovery, "target", "none"))
    pauli in ("I", "missing") && return Dict{String,Any}[]
    target == "none" && return Dict{String,Any}[]
    if pauli == "Y"
        return Dict{String,Any}[
            Dict{String,Any}("pauli" => "X", "target" => target),
            Dict{String,Any}("pauli" => "Z", "target" => target),
        ]
    elseif pauli in ("X", "Z")
        return Dict{String,Any}[Dict{String,Any}("pauli" => pauli, "target" => target)]
    end
    return Dict{String,Any}[]
end

function css_recovery_signature(recovery::AbstractDict)
    components = css_recovery_components(recovery)
    if isempty(components)
        return "I@none"
    end
    entries = sort!([
        string(component["pauli"], "@", component["target"])
        for component in components
    ])
    return join(entries, "+")
end

function apply_css_recovery!(x_state::SymbolicStabilizerState,
    z_state::SymbolicStabilizerState,
    recovery::AbstractDict)

    for component in css_recovery_components(recovery)
        target = parse_recovery_target(component)
        target === nothing && continue
        pauli = String(component["pauli"])
        pauli == "X" && absorb!(x_state, bconst(true), target; pauli="X")
        pauli == "Z" && absorb!(z_state, bconst(true), target; pauli="Z")
    end
    return x_state, z_state
end

function css_residual_error_dict(x_state::SymbolicStabilizerState,
    z_state::SymbolicStabilizerState,
    model::AbstractDict)

    x_residual = symbolic_residual_vector(x_state, model)
    z_residual = symbolic_residual_vector(z_state, model)
    return Dict{String,Any}(
        "q$(idx)" => (
            x_residual[idx] && z_residual[idx] ? "Y" :
            x_residual[idx] ? "X" :
            z_residual[idx] ? "Z" :
            "I"
        )
        for idx in eachindex(x_residual)
    )
end

function css_residual_weight(x_state::SymbolicStabilizerState,
    z_state::SymbolicStabilizerState,
    model::AbstractDict)

    x_residual = symbolic_residual_vector(x_state, model)
    z_residual = symbolic_residual_vector(z_state, model)
    return count(idx -> x_residual[idx] || z_residual[idx], eachindex(x_residual))
end

function css_stabilizer_layer_summary(pre_recovery::SymbolicStabilizerState,
    post_recovery::SymbolicStabilizerState,
    model::AbstractDict)

    return Dict{String,Any}(
        "tracked_pauli" => pre_recovery.pauli,
        "pre_recovery_generators" => stabilizer_generator_summary(pre_recovery),
        "post_recovery_generators" => stabilizer_generator_summary(post_recovery),
        "post_recovery_residual" =>
            symbolic_residual_error_dict(post_recovery, model),
        "post_recovery_residual_weight" =>
            symbolic_residual_weight(post_recovery, model),
    )
end

function support_to_mask(support::AbstractVector{<:Integer})
    mask = UInt128(0)
    for idx in support
        idx >= 1 || error("support indices are one-based, got $(idx)")
        mask ⊻= UInt128(1) << (Int(idx) - 1)
    end
    return mask
end

function bool_vector_to_mask(values::AbstractVector{Bool})
    mask = UInt128(0)
    for (idx, value) in enumerate(values)
        value && (mask ⊻= UInt128(1) << (idx - 1))
    end
    return mask
end

function rowspace_masks(supports::AbstractVector)
    basis = UInt128[support_to_mask(support) for support in supports]
    space = Set{UInt128}([UInt128(0)])
    for basis_mask in basis
        snapshot = collect(space)
        for mask in snapshot
            push!(space, mask ⊻ basis_mask)
        end
    end
    return space
end

function residual_logical_class(values::AbstractVector{Bool},
    stabilizer_supports::AbstractVector,
    logical_support::AbstractVector{<:Integer};
    logical_name::AbstractString="logical")

    mask = bool_vector_to_mask(values)
    mask == 0 && return "identity"

    space = rowspace_masks(stabilizer_supports)
    mask in space && return "stabilizer"

    logical_mask = support_to_mask(logical_support)
    (mask ⊻ logical_mask) in space && return String(logical_name)
    return "detectable_residual"
end

function css_logical_ok(x_class::AbstractString, z_class::AbstractString)
    return String(x_class) in ("identity", "stabilizer") &&
        String(z_class) in ("identity", "stabilizer")
end

function record_css_symbolic_stabilizer_summary!(trace::ConcolicTrace,
    x_pre_recovery::SymbolicStabilizerState,
    x_post_recovery::SymbolicStabilizerState,
    z_pre_recovery::SymbolicStabilizerState,
    z_post_recovery::SymbolicStabilizerState,
    model::AbstractDict)

    trace.metadata["symbolic_stabilizer"] = Dict{String,Any}(
        "code" => x_pre_recovery.code_name,
        "representation" =>
            "dual CSS symbolic Pauli frames with stabilizer generator phases",
        "tracked_paulis" => ["X", "Z"],
        "layers" => Dict{String,Any}(
            "x_error_frame" => css_stabilizer_layer_summary(
                x_pre_recovery,
                x_post_recovery,
                model,
            ),
            "z_error_frame" => css_stabilizer_layer_summary(
                z_pre_recovery,
                z_post_recovery,
                model,
            ),
        ),
        "post_recovery_residual" => css_residual_error_dict(
            x_post_recovery,
            z_post_recovery,
            model,
        ),
        "post_recovery_residual_weight" => css_residual_weight(
            x_post_recovery,
            z_post_recovery,
            model,
        ),
    )
    return trace
end

function symbolic_stabilizer_from_faults(code_name::AbstractString,
    qubit_count::Integer,
    generator_names::AbstractVector,
    generator_supports::AbstractVector,
    fault_exprs::AbstractVector{<:BoolExpr};
    pauli="X",
    generator_paulis=nothing)

    length(fault_exprs) == qubit_count ||
        error("fault expression count $(length(fault_exprs)) does not match $(qubit_count)")
    state = SymbolicStabilizerState(
        code_name,
        qubit_count,
        generator_names,
        generator_supports;
        pauli=pauli,
        generator_paulis=generator_paulis,
    )
    for (idx, expr) in enumerate(fault_exprs)
        absorb!(state, expr, idx; pauli=pauli)
    end
    return state
end
