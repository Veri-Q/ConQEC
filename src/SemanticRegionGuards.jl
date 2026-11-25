abstract type SemanticRegionGuard end

struct ObservableRegionGuard <: SemanticRegionGuard
    key::String
end

struct NewObservableGuard <: SemanticRegionGuard
    seen_keys::Vector{String}
end

struct SyndromeWeightGuard <: SemanticRegionGuard
    lower::Int
    upper::Union{Nothing,Int}
end

struct RoundWeightGuard <: SemanticRegionGuard
    round_selector::Union{Symbol,Int}
    lower::Int
    upper::Union{Nothing,Int}
end

struct BoundaryGuard <: SemanticRegionGuard
    detector_indices::Vector{Int}
    touches_boundary::Bool
end

struct CompoundGuard <: SemanticRegionGuard
    guards::Vector{SemanticRegionGuard}
end

const SEMANTIC_REGION_CARDINALITY_EXPANSION_LIMIT = 48
const SEMANTIC_REGION_CARDINALITY_COMBO_LIMIT = 100_000

function semantic_region_observable_key_text(key::AbstractString)
    text = strip(String(key))
    prefix = "observable_key:"
    startswith(text, prefix) && return text[(lastindex(prefix) + 1):end]
    return text
end

function semantic_region_bits_from_key(width::Integer, key::AbstractString)
    text = semantic_region_observable_key_text(key)
    length(text) == Int(width) ||
        error("observable key length $(length(text)) does not match observable count $(width)")
    all(ch -> ch == '0' || ch == '1', text) ||
        error("observable key must contain only 0/1 bits: $(key)")
    return Bool[ch == '1' for ch in text]
end

function semantic_region_canonical_observable_key(model::DemParityModel, key::AbstractString)
    bits = semantic_region_bits_from_key(model.observable_count, key)
    return dem_parity_key(bits)
end

function canonical_region_id(model::DemParityModel, guard::ObservableRegionGuard)
    return "observable_key:" * semantic_region_canonical_observable_key(model, guard.key)
end

function canonical_region_id(model::DemParityModel, guard::NewObservableGuard)
    keys = sort!([semantic_region_canonical_observable_key(model, key) for key in guard.seen_keys])
    return "new_observable_excluding:" * dem_sha256_hex(join(keys, "\n"))
end

function canonical_region_id(::DemParityModel, guard::SyndromeWeightGuard)
    upper = guard.upper === nothing ? "inf" : string(guard.upper)
    return "syndrome_weight:" * string(guard.lower) * ".." * upper
end

function canonical_region_id(model::DemParityModel, guard::RoundWeightGuard)
    round_id = semantic_region_round_index(model, guard.round_selector)
    upper = guard.upper === nothing ? "inf" : string(guard.upper)
    return "round_weight:" * string(round_id) * ":" * string(guard.lower) * ".." * upper
end

function canonical_region_id(::DemParityModel, guard::BoundaryGuard)
    kind = guard.touches_boundary ? "boundary_touch" : "bulk_no_boundary_touch"
    return kind * ":" * dem_sha256_hex(join(string.(sort(guard.detector_indices)), ","))
end

function canonical_region_id(model::DemParityModel, guard::CompoundGuard)
    child_ids = sort!([canonical_region_id(model, child) for child in guard.guards])
    return "compound:" * dem_sha256_hex(join(child_ids, "\n"))
end

guard_kind(::ObservableRegionGuard) = :observable_exact
guard_kind(::NewObservableGuard) = :observable_unseen
guard_kind(::SyndromeWeightGuard) = :syndrome_weight
guard_kind(::RoundWeightGuard) = :round_weight
guard_kind(::BoundaryGuard) = :boundary
guard_kind(::CompoundGuard) = :compound

function guard_description(model::DemParityModel, guard::ObservableRegionGuard)
    return "logical observable parity equals " * canonical_region_id(model, guard)
end

function guard_description(model::DemParityModel, guard::NewObservableGuard)
    return "logical observable parity is outside " * string(length(guard.seen_keys)) * " seen keys"
end

function guard_description(model::DemParityModel, guard::SemanticRegionGuard)
    return canonical_region_id(model, guard)
end

function guard_expr(model::DemParityModel, guard::ObservableRegionGuard)
    bits = semantic_region_bits_from_key(model.observable_count, guard.key)
    return dem_bits_equal_expr(dem_logical_exprs(model), bits)
end

function guard_expr(model::DemParityModel, guard::NewObservableGuard)
    exprs = dem_logical_exprs(model)
    terms = BoolExpr[]
    for key in guard.seen_keys
        bits = semantic_region_bits_from_key(model.observable_count, key)
        push!(terms, bnot(dem_bits_equal_expr(exprs, bits)))
    end
    return band(terms...)
end

function semantic_region_cardinality_at_most(exprs::Vector{BoolExpr}, upper::Integer)
    n = length(exprs)
    upper >= n && return bconst(true)
    upper < 0 && return bconst(false)
    n <= SEMANTIC_REGION_CARDINALITY_EXPANSION_LIMIT ||
        error("cardinality BoolExpr expansion unsupported for $(n) bits; use SMT/PB backend")
    clauses = BoolExpr[]
    combo_count = Ref(0)
    function collect_combos!(active::Vector{Int}, start::Int, remaining::Int)
        if remaining == 0
            combo_count[] += 1
            combo_count[] <= SEMANTIC_REGION_CARDINALITY_COMBO_LIMIT ||
                error("cardinality BoolExpr expansion exceeds $(SEMANTIC_REGION_CARDINALITY_COMBO_LIMIT) clauses; use SMT/PB backend")
            push!(clauses, bor((bnot(exprs[idx]) for idx in active)...))
            return nothing
        end
        stop = n - remaining + 1
        for idx in start:stop
            push!(active, idx)
            collect_combos!(active, idx + 1, remaining - 1)
            pop!(active)
        end
        return nothing
    end
    collect_combos!(Int[], 1, Int(upper) + 1)
    return band(clauses...)
end

function semantic_region_cardinality_range(exprs::Vector{BoolExpr}, lower::Integer, upper)
    n = length(exprs)
    lo = max(Int(lower), 0)
    hi = upper === nothing ? n : min(Int(upper), n)
    lo > hi && return bconst(false)
    at_most = semantic_region_cardinality_at_most(exprs, hi)
    at_least = lo <= 0 ? bconst(true) :
        semantic_region_cardinality_at_most(BoolExpr[bnot(expr) for expr in exprs], n - lo)
    return band(at_most, at_least)
end

function guard_expr(model::DemParityModel, guard::SyndromeWeightGuard)
    return semantic_region_cardinality_range(
        BoolExpr[expr for expr in dem_syndrome_exprs(model)],
        guard.lower,
        guard.upper,
    )
end

function semantic_region_round_index(model::DemParityModel, selector::Int)
    rounds = max(model.rounds, 1)
    return clamp(selector, 0, rounds - 1)
end

function semantic_region_round_index(model::DemParityModel, selector::Symbol)
    rounds = max(model.rounds, 1)
    selector == :initial && return 0
    selector == :final && return rounds - 1
    selector == :middle && return fld(rounds - 1, 2)
    error("unsupported round selector: $(selector)")
end

function semantic_region_round_detector_indices(model::DemParityModel, selector)
    model.detector_count > 0 || return Int[]
    rounds = max(model.rounds, 1)
    round_idx = semantic_region_round_index(model, selector)
    return Int[
        detector for detector in 0:(model.detector_count - 1)
        if clamp(fld(detector * rounds, model.detector_count), 0, rounds - 1) == round_idx
    ]
end

function guard_expr(model::DemParityModel, guard::RoundWeightGuard)
    detector_indices = semantic_region_round_detector_indices(model, guard.round_selector)
    all_exprs = dem_syndrome_exprs(model)
    exprs = BoolExpr[all_exprs[idx + 1] for idx in detector_indices if 0 <= idx < length(all_exprs)]
    return semantic_region_cardinality_range(exprs, guard.lower, guard.upper)
end

function guard_expr(model::DemParityModel, guard::BoundaryGuard)
    isempty(guard.detector_indices) &&
        error("boundary guard requires explicit public boundary detector metadata")
    all_exprs = dem_syndrome_exprs(model)
    terms = BoolExpr[
        all_exprs[idx + 1] for idx in sort(guard.detector_indices)
        if 0 <= idx < length(all_exprs)
    ]
    touch_expr = bor(terms...)
    return guard.touches_boundary ? touch_expr : bnot(touch_expr)
end

function guard_expr(model::DemParityModel, guard::CompoundGuard)
    return band((guard_expr(model, child) for child in guard.guards)...)
end

function guard_dependencies(model::DemParityModel, guard::SemanticRegionGuard)
    return expr_vars(guard_expr(model, guard))
end

function scheduler_visible_metadata(model::DemParityModel, guard::SemanticRegionGuard)
    return Dict{String,Any}(
        "semantic_region_guard_kind" => String(guard_kind(guard)),
        "semantic_region_guard_id" => canonical_region_id(model, guard),
        "semantic_region_guard_description" => guard_description(model, guard),
        "scheduler_visible_target_metadata" => false,
        "scheduler_visible_oracle_metadata" => false,
        "scheduler_visible_oracle_region_metadata" => false,
        "metadata_guided" => false,
    )
end

function audit_only_metadata(model::DemParityModel, guard::SemanticRegionGuard)
    return Dict{String,Any}(
        "semantic_region_dependency_count" => length(guard_dependencies(model, guard)),
        "semantic_region_guard_kind" => String(guard_kind(guard)),
        "semantic_region_guard_id" => canonical_region_id(model, guard),
    )
end
