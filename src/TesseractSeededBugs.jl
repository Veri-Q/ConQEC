const DEM_SEEDED_BUG_CLASSES = (
    :syndrome_extraction_wiring,
    :measurement_result_misuse,
    :decoder_decision_error,
    :unhandled_syndrome,
    :recovery_application_error,
    :repeated_round_control_error,
    :boundary_classification_error,
    :observable_mapping_error,
)

struct DemSeededBugContract
    bug_id::String
    bug_class::Symbol
    target_entry::DemDecoderEntry
    wrong_entry::Union{Nothing,DemDecoderEntry}
    syndrome_flip_index::Int
    measurement_flip_index::Int
    observable_flip_index::Int
    public_prefix_count::Int
    selection_policy::String
    target_selection::Union{Nothing,DemSemanticTargetSelection}
    oracle_region_policy::String
    oracle_region_kind::String
    oracle_region_key::String
end

function dem_bug_class_symbol(value)
    value isa Symbol && return value
    return Symbol(String(value))
end

function dem_public_prefix_count(model::DemParityModel;
    requested=nothing,
    budget::Integer=16)

    requested !== nothing && return min(Int(requested), max(length(model.faults) - 1, 0))
    n = length(model.faults)
    n <= 1 && return 0
    return min(64, max(n - 1, 0), max(fld(n, 2), 1))
end

function dem_select_target_entry(model::DemParityModel,
    table::AbstractDict,
    bug_class::Symbol;
    public_prefix_count::Integer=0,
    salt::AbstractString="")

    candidates = dem_reference_candidate_entries(
        model,
        table;
        public_prefix_count=public_prefix_count,
    )
    if isempty(candidates)
        candidates = [
            entry for entry in values(table)
            if !isempty(entry.correction_indices)
        ]
        sort!(candidates, by=dem_entry_rank)
    end
    isempty(candidates) && error("DEM subject has no non-clean decoder candidates")
    key = string(model.source_path, "|", bug_class, "|", salt)
    return candidates[dem_stable_index(key, length(candidates))]
end

function dem_select_target_entry(model::DemParityModel,
    table::AbstractDict,
    bug_class::Symbol,
    selection::DemSemanticTargetSelection)

    entry = selection.state.reference_entry
    entry === nothing && error("semantic target has no reference decoder entry")
    return entry
end

function dem_support_flip_index(bits::AbstractVector{Bool},
    salt::AbstractString;
    detector_count::Integer=length(bits))

    true_indices = [idx for (idx, bit) in enumerate(bits) if bit]
    if !isempty(true_indices)
        return true_indices[dem_stable_index(salt * "|true", length(true_indices))]
    end
    detector_count <= 0 && return 1
    return dem_stable_index(salt * "|any", detector_count)
end

function dem_round_bucket_key(model::DemParityModel, syndrome_support::AbstractVector{Int})
    isempty(syndrome_support) && return "round_bucket:none"
    model.detector_count <= 0 && return "round_bucket:none"
    buckets = max(model.rounds, 1)
    detector = clamp(minimum(syndrome_support), 0, max(model.detector_count - 1, 0))
    bucket = clamp(fld(detector * buckets, model.detector_count), 0, buckets - 1)
    return "round_bucket:" * string(bucket) * "/" * string(buckets)
end

function dem_round_weight_bucket_key(model::DemParityModel, syndrome_support::AbstractVector{Int})
    return dem_round_bucket_key(model, syndrome_support) *
        "|syndrome_weight:" * string(length(syndrome_support))
end

function dem_oracle_region_kind(policy::AbstractString,
    bug_class::Symbol,
    state::DemSemanticState)

    normalized = lowercase(strip(String(policy)))
    normalized in ("", "syndrome_key", "exact_syndrome", "exact_syndrome_v1") &&
        return "syndrome_key"
    normalized in ("observable_key", "observable_class") && return "observable_key"
    normalized in ("syndrome_weight", "syndrome_weight_class") && return "syndrome_weight"
    normalized in ("round_bucket", "round_bucket_class") && return "round_bucket"
    normalized in ("round_weight_bucket", "round_weight_bucket_class") && return "round_weight_bucket"
    if normalized == "bugclass_public_region_v1"
        bug_class in (
            :syndrome_extraction_wiring,
            :measurement_result_misuse,
            :repeated_round_control_error,
        ) && return "round_bucket"
        state.observable_weight > 0 && return "observable_key"
        return "syndrome_weight"
    end
    if normalized == "bugclass_public_region_v2"
        bug_class in (
            :syndrome_extraction_wiring,
            :measurement_result_misuse,
            :repeated_round_control_error,
            :unhandled_syndrome,
            :boundary_classification_error,
        ) && return "round_weight_bucket"
        bug_class == :observable_mapping_error && return "observable_key"
        state.observable_weight > 0 && return "observable_key"
        return "round_weight_bucket"
    end
    error("unsupported DEM oracle region policy: $(policy)")
end

function dem_oracle_region_key_for_state(model::DemParityModel,
    state::DemSemanticState,
    kind::AbstractString)

    normalized = String(kind)
    normalized == "syndrome_key" && return "syndrome_key:" * state.syndrome_key
    normalized == "observable_key" && return "observable_key:" * state.observable_key
    normalized == "syndrome_weight" && return "syndrome_weight:" * string(state.syndrome_weight)
    normalized == "round_bucket" && return dem_round_bucket_key(
        model,
        state.reference_entry === nothing ? Int[] : state.reference_entry.syndrome_support,
    )
    normalized == "round_weight_bucket" && return dem_round_weight_bucket_key(
        model,
        state.reference_entry === nothing ? Int[] : state.reference_entry.syndrome_support,
    )
    error("unsupported DEM oracle region kind: $(kind)")
end

function dem_oracle_region_key_for_active(model::DemParityModel,
    kind::AbstractString,
    active_faults::AbstractVector{Int})

    normalized = String(kind)
    syndrome_support = dem_syndrome_support(model, active_faults)
    normalized == "syndrome_key" &&
        return "syndrome_key:" * dem_syndrome_key_from_support(model, syndrome_support)
    normalized == "observable_key" &&
        return "observable_key:" * dem_parity_key(dem_logical_bits(model, active_faults))
    normalized == "syndrome_weight" &&
        return "syndrome_weight:" * string(length(syndrome_support))
    normalized == "round_bucket" && return dem_round_bucket_key(model, syndrome_support)
    normalized == "round_weight_bucket" && return dem_round_weight_bucket_key(model, syndrome_support)
    error("unsupported DEM oracle region kind: $(kind)")
end

function dem_seeded_bug_contract(model::DemParityModel,
    table::AbstractDict,
    bug_class_value;
    budget::Integer=16,
    public_prefix_count=nothing,
    salt::AbstractString="0",
    target_policy::AbstractString=DEM_SEMANTIC_TARGET_POLICY_VERSION,
    target_policy_version::AbstractString=String(target_policy),
    decoder_proxy_branch_limit::Integer=0,
    oracle_region_policy::AbstractString="syndrome_key",
    semantic_states=nothing)

    bug_class = dem_bug_class_symbol(bug_class_value)
    bug_class in DEM_SEEDED_BUG_CLASSES ||
        error("unsupported DEM seeded bug class: $(bug_class)")
    prefix = dem_public_prefix_count(model; requested=public_prefix_count, budget=budget)
    selection = dem_select_semantic_target(
        model,
        table,
        bug_class;
        target_policy=target_policy,
        policy_version=target_policy_version,
        salt=salt,
        semantic_states=semantic_states,
    )
    target = dem_select_target_entry(model, table, bug_class, selection)
    needs_wrong_entry = bug_class in (
        :decoder_decision_error,
        :recovery_application_error,
        :repeated_round_control_error,
    )
    wrong = needs_wrong_entry ?
        dem_wrong_decoder_entry(
            model,
            table,
            target,
            string(model.source_path, "|", bug_class, "|wrong|", salt),
        ) :
        nothing
    flip = dem_support_flip_index(
        dem_entry_syndrome_bits(model, target),
        string(model.source_path, "|", bug_class, "|flip|", salt);
        detector_count=max(model.detector_count, 1),
    )
    observable_flip = dem_support_flip_index(
        dem_logical_bits(model, selection.state.representative_faults),
        string(model.source_path, "|", bug_class, "|observable|", salt);
        detector_count=max(model.observable_count, 1),
    )
    region_kind = dem_oracle_region_kind(oracle_region_policy, bug_class, selection.state)
    region_key = dem_oracle_region_key_for_state(model, selection.state, region_kind)
    bug_id = "DEM-" * replace(String(bug_class), "_" => "-") *
        "-" * string(abs(Int(mod(dem_stable_hash(model.source_path * string(bug_class)), UInt64(10_000_000)))))
    return DemSeededBugContract(
        bug_id,
        bug_class,
        target,
        wrong,
        flip,
        flip,
        observable_flip,
        prefix,
        "blind SHA256 over full canonical semantic target universe",
        selection,
        String(oracle_region_policy),
        region_kind,
        region_key,
    )
end

function dem_contract_public_metadata(contract::DemSeededBugContract)
    base = Dict{String,Any}(
        "bug_id" => contract.bug_id,
        "bug_class" => String(contract.bug_class),
        "bug_selection_policy" => contract.selection_policy,
        "public_decoy_prefix_count" => contract.public_prefix_count,
        "target_metadata_used" => false,
        "scheduler_visible_target_metadata" => false,
        "metadata_guided_seeds" => "off",
        "oracle_region_policy" => contract.oracle_region_policy,
        "oracle_region_kind" => contract.oracle_region_kind,
        "oracle_region_key" => contract.oracle_region_key,
        "scheduler_visible_oracle_region_metadata" => false,
    )
    contract.target_selection === nothing && return base
    selection = contract.target_selection
    return merge(
        base,
        Dict{String,Any}(
            "target_policy" => selection.policy,
            "target_policy_version" => selection.policy_version,
            "target_salt" => selection.salt,
            "target_selection_pool_size" => selection.pool_size,
            "target_selection_index" => selection.target_index,
            "target_semantic_hash" => selection.state.semantic_hash,
            "target_semantic_syndrome_key" => selection.state.syndrome_key,
            "target_semantic_observable_key" => selection.state.observable_key,
            "target_reference_decoder" => selection.state.reference_decoder_id,
            "target_reference_recovery" => selection.state.reference_recovery_id,
            "target_representative_fault_count" => length(selection.state.representative_faults),
        ),
    )
end

function dem_clean_contract(model::DemParityModel,
    table::AbstractDict;
    budget::Integer=16,
    public_prefix_count=nothing)

    prefix = dem_public_prefix_count(model; requested=public_prefix_count, budget=budget)
    target = first(values(table))
    return DemSeededBugContract(
        "DEM-clean-control",
        :clean,
        target,
        nothing,
        1,
        1,
        1,
        prefix,
        "clean-control-no-seeded-divergence",
        nothing,
        "clean_control",
        "none",
        "none",
    )
end
