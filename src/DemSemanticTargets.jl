const DEM_SEMANTIC_TARGET_POLICY_VERSION = "plausible_public_dem_v2"
const DEM_UNIFORM_TARGET_POLICY_VERSION = "uniform_full_semantic_v1"
const DEM_RENDEZVOUS_TARGET_POLICY_VERSION = "rendezvous_full_semantic_v1"

dem_bitstring_weight(bits::AbstractString) = count(==('1'), bits)

struct DemSemanticState
    semantic_hash::String
    syndrome_key::String
    observable_key::String
    syndrome_weight::Int
    observable_weight::Int
    reference_decoder_id::String
    reference_recovery_id::String
    public_features::String
    representative_faults::Vector{Int}
    reference_entry::Union{Nothing,DemDecoderEntry}
end

struct DemSemanticTargetSelection
    policy::String
    policy_version::String
    salt::String
    pool_size::Int
    target_index::Int
    state::DemSemanticState
end

dem_sha256_hex(text::AbstractString) = bytes2hex(sha256(String(text)))

function dem_semantic_public_features(model::DemParityModel,
    active::AbstractVector{Int},
    syndrome_weight::Integer,
    observable_bits::AbstractVector{Bool},
    reference_entry::Union{Nothing,DemDecoderEntry})

    return join(
        [
            "fault_weight=" * string(length(active)),
            "syndrome_weight=" * string(Int(syndrome_weight)),
            "observable_weight=" * string(count(identity, observable_bits)),
            "reference_weight=" * string(reference_entry === nothing ? -1 : reference_entry.weight),
            "rounds=" * string(model.rounds),
            "distance=" * string(model.distance),
        ],
        ";",
    )
end

function dem_semantic_state_serialization(policy_version::AbstractString,
    syndrome_key::AbstractString,
    observable_key::AbstractString,
    reference_decoder_id::AbstractString,
    reference_recovery_id::AbstractString,
    public_features::AbstractString)

    return join(
        [
            "version=" * String(policy_version),
            "syndrome=" * String(syndrome_key),
            "observable=" * String(observable_key),
            "decoder=" * String(reference_decoder_id),
            "recovery=" * String(reference_recovery_id),
            "features=" * String(public_features),
        ],
        "\n",
    )
end

function dem_canonical_candidate_id(state::DemSemanticState)
    # The semantic hash is computed from the public syndrome/observable/decoder
    # semantics and is already the deduplicated key for the target universe.
    return state.semantic_hash
end

function dem_semantic_state_for_active(model::DemParityModel,
    table::AbstractDict,
    active::AbstractVector{Int};
    policy_version::AbstractString=DEM_SEMANTIC_TARGET_POLICY_VERSION)

    if length(active) == 1
        idx = Int(active[begin])
        if 1 <= idx <= length(model.faults)
            fault = model.faults[idx]
            syndrome_support = fault.detector_support
            observable_bits = dem_bits_from_support(model.observable_count, fault.logical_support)
            syndrome_key = dem_syndrome_key_from_support(model, syndrome_support)
            reference_entry = get(table, syndrome_key, nothing)
            reference_id = dem_entry_signature(reference_entry)
            public_features = dem_semantic_public_features(
                model,
                Int[idx],
                length(syndrome_support),
                observable_bits,
                reference_entry,
            )
            observable_key = dem_parity_key(observable_bits)
            serialization = dem_semantic_state_serialization(
                policy_version,
                syndrome_key,
                observable_key,
                reference_id,
                reference_id,
                public_features,
            )
            return DemSemanticState(
                dem_sha256_hex(serialization),
                syndrome_key,
                observable_key,
                length(syndrome_support),
                count(identity, observable_bits),
                reference_id,
                reference_id,
                public_features,
                Int[idx],
                reference_entry,
            )
        end
    end
    active_sorted = sort!(collect(Int, active))
    syndrome_support = dem_syndrome_support(model, active_sorted)
    observable_bits = dem_logical_bits(model, active_sorted)
    syndrome_key = dem_syndrome_key_from_support(model, syndrome_support)
    reference_entry = get(table, syndrome_key, nothing)
    reference_id = dem_entry_signature(reference_entry)
    public_features = dem_semantic_public_features(
        model,
        active_sorted,
        length(syndrome_support),
        observable_bits,
        reference_entry,
    )
    observable_key = dem_parity_key(observable_bits)
    serialization = dem_semantic_state_serialization(
        policy_version,
        syndrome_key,
        observable_key,
        reference_id,
        reference_id,
        public_features,
    )
    return DemSemanticState(
        dem_sha256_hex(serialization),
        syndrome_key,
        observable_key,
        length(syndrome_support),
        count(identity, observable_bits),
        reference_id,
        reference_id,
        public_features,
        active_sorted,
        reference_entry,
    )
end

function dem_weight1_semantic_states(model::DemParityModel,
    table::AbstractDict;
    policy_version::AbstractString=DEM_SEMANTIC_TARGET_POLICY_VERSION)

    by_hash = Dict{String,DemSemanticState}()
    for idx in eachindex(model.faults)
        state = dem_semantic_state_for_active(
            model,
            table,
            Int[idx];
            policy_version=policy_version,
        )
        isempty(state.syndrome_key) && isempty(state.observable_key) && continue
        if !haskey(by_hash, state.semantic_hash)
            by_hash[state.semantic_hash] = state
        else
            old = by_hash[state.semantic_hash]
            by_hash[state.semantic_hash] = DemSemanticState(
                old.semantic_hash,
                old.syndrome_key,
                old.observable_key,
                old.syndrome_weight,
                old.observable_weight,
                old.reference_decoder_id,
                old.reference_recovery_id,
                old.public_features,
                sort!(unique(vcat(old.representative_faults, state.representative_faults))),
                old.reference_entry,
            )
        end
    end
    states = collect(values(by_hash))
    sort!(states, by=state -> state.semantic_hash)
    return states
end

function dem_semantic_state_supported_for_bug_class(state::DemSemanticState,
    bug_class::Symbol,
    model::DemParityModel,
    table::AbstractDict,
    salt::AbstractString;
    wrong_decoder_available::Bool=true)

    bug_class == :syndrome_extraction_wiring &&
        return state.syndrome_weight > 0
    bug_class == :measurement_result_misuse &&
        return model.detector_count > 0 && state.syndrome_weight > 0
    bug_class == :decoder_decision_error &&
        return state.reference_entry !== nothing &&
            wrong_decoder_available &&
            state.observable_weight > 0
    bug_class == :unhandled_syndrome &&
        return state.reference_entry !== nothing &&
            !isempty(state.reference_entry.correction_indices)
    bug_class == :recovery_application_error &&
        return state.reference_entry !== nothing &&
            !isempty(state.reference_entry.correction_indices) &&
            wrong_decoder_available &&
            state.observable_weight > 0
    bug_class == :repeated_round_control_error &&
        return model.rounds > 1 &&
            state.reference_entry !== nothing &&
            !isempty(state.reference_entry.correction_indices) &&
            wrong_decoder_available &&
            state.observable_weight > 0
    bug_class == :boundary_classification_error &&
        return state.reference_entry !== nothing &&
            !isempty(state.reference_entry.correction_indices) &&
            state.syndrome_weight == 1
    bug_class == :observable_mapping_error &&
        return model.observable_count > 0 &&
            state.reference_entry !== nothing &&
            state.observable_weight > 0
    return false
end

function dem_table_has_alternative_decoder_signature(table::AbstractDict)
    signatures = Set{String}()
    for entry in values(table)
        push!(signatures, dem_entry_signature(entry))
        length(signatures) > 1 && return true
    end
    return false
end

function dem_semantic_target_pool(model::DemParityModel,
    table::AbstractDict,
    bug_class::Symbol;
    policy_version::AbstractString=DEM_SEMANTIC_TARGET_POLICY_VERSION,
    target_policy::AbstractString=DEM_SEMANTIC_TARGET_POLICY_VERSION,
    salt::AbstractString="",
    semantic_states=nothing)

    states = semantic_states === nothing ?
        dem_weight1_semantic_states(model, table; policy_version=policy_version) :
        semantic_states
    if String(target_policy) == DEM_UNIFORM_TARGET_POLICY_VERSION
        return states
    end
    wrong_decoder_available = dem_table_has_alternative_decoder_signature(table)
    return [
        state for state in states
        if dem_semantic_state_supported_for_bug_class(
            state,
            bug_class,
            model,
            table,
            salt;
            wrong_decoder_available=wrong_decoder_available,
        )
    ]
end

function dem_select_semantic_target(model::DemParityModel,
    table::AbstractDict,
    bug_class::Symbol;
    target_policy::AbstractString=DEM_SEMANTIC_TARGET_POLICY_VERSION,
    policy_version::AbstractString=String(target_policy),
    salt::AbstractString="",
    semantic_states=nothing)

    pool = dem_semantic_target_pool(
        model,
        table,
        bug_class;
        policy_version=policy_version,
        target_policy=target_policy,
        salt=salt,
        semantic_states=semantic_states,
    )
    isempty(pool) && error("DEM subject has no eligible semantic target states for $(bug_class)")
    key = join(
        [
            model.source_path,
            String(bug_class),
            String(salt),
            String(policy_version),
        ],
        "|",
    )
    digest = sha256(key)
    value = foldl((acc, byte) -> (acc << 8) + UInt128(byte), digest[1:16]; init=UInt128(0))
    idx = Int(mod(value, UInt128(length(pool)))) + 1
    return DemSemanticTargetSelection(
        String(target_policy),
        String(policy_version),
        String(salt),
        length(pool),
        idx,
        pool[idx],
    )
end

function dem_rendezvous_target_key(model::DemParityModel,
    bug_class::Symbol,
    salt::AbstractString,
    policy_version::AbstractString,
    state::DemSemanticState)

    return dem_sha256_hex(join(
        [
            "policy=" * String(policy_version),
            "subject=" * model.source_path,
            "bug_class=" * String(bug_class),
            "salt=" * String(salt),
            "candidate=" * dem_canonical_candidate_id(state),
        ],
        "\n",
    ))
end

function dem_select_semantic_target_rendezvous(model::DemParityModel,
    table::AbstractDict,
    bug_class::Symbol;
    target_policy::AbstractString=DEM_RENDEZVOUS_TARGET_POLICY_VERSION,
    policy_version::AbstractString=String(target_policy),
    salt::AbstractString="",
    semantic_states=nothing)

    pool = dem_semantic_target_pool(
        model,
        table,
        bug_class;
        policy_version=policy_version,
        target_policy=target_policy,
        salt=salt,
        semantic_states=semantic_states,
    )
    isempty(pool) && error("DEM subject has no eligible semantic target states for $(bug_class)")

    best_state = pool[1]
    best_candidate_id = dem_canonical_candidate_id(best_state)
    best_key = dem_rendezvous_target_key(model, bug_class, salt, policy_version, best_state)
    for idx in 2:length(pool)
        state = pool[idx]
        candidate_id = dem_canonical_candidate_id(state)
        key = dem_rendezvous_target_key(model, bug_class, salt, policy_version, state)
        if key < best_key ||
                (key == best_key && candidate_id < best_candidate_id)
            best_state = state
            best_candidate_id = candidate_id
            best_key = key
        end
    end

    canonical_index = 1
    for state in pool
        dem_canonical_candidate_id(state) < best_candidate_id && (canonical_index += 1)
    end
    return DemSemanticTargetSelection(
        String(target_policy),
        String(policy_version),
        String(salt),
        length(pool),
        Int(canonical_index),
        best_state,
    )
end

function dem_visible_proxy_entries(model::DemParityModel,
    table::AbstractDict;
    public_prefix_count::Integer=0,
    decoder_proxy_branch_limit::Integer=0)

    candidates = dem_reference_candidate_entries(
        model,
        table;
        public_prefix_count=public_prefix_count,
    )
    limit = max(Int(decoder_proxy_branch_limit), 0)
    limit == 0 && return DemDecoderEntry[]
    return candidates[1:min(limit, length(candidates))]
end

function dem_visible_proxy_entries(public_entries::AbstractVector;
    decoder_proxy_branch_limit::Integer=0)

    limit = max(Int(decoder_proxy_branch_limit), 0)
    limit == 0 && return eltype(public_entries)[]
    return public_entries[1:min(limit, length(public_entries))]
end

function dem_semantic_target_rank_in_entries(selection::DemSemanticTargetSelection,
    entries::AbstractVector{DemDecoderEntry})

    target_key = selection.state.syndrome_key
    for (idx, entry) in enumerate(entries)
        entry.syndrome_key == target_key && return idx
    end
    return 0
end

function dem_semantic_target_metadata(selection::DemSemanticTargetSelection,
    model::DemParityModel,
    table::AbstractDict;
    public_prefix_count::Integer=0,
    decoder_proxy_branch_limit::Integer=0)

    public_entries = dem_reference_candidate_entries(
        model,
        table;
        public_prefix_count=public_prefix_count,
    )
    return dem_semantic_target_metadata_from_entries(
        selection,
        model,
        public_entries;
        decoder_proxy_branch_limit=decoder_proxy_branch_limit,
    )
end

function dem_semantic_target_metadata_from_entries(selection::DemSemanticTargetSelection,
    model::DemParityModel,
    public_entries::AbstractVector;
    decoder_proxy_branch_limit::Integer=0)

    visible_entries = dem_visible_proxy_entries(
        public_entries;
        decoder_proxy_branch_limit=decoder_proxy_branch_limit,
    )
    public_rank = dem_semantic_target_rank_in_entries(selection, public_entries)
    visible_rank = dem_semantic_target_rank_in_entries(selection, visible_entries)
    return Dict{String,Any}(
        "target_policy" => selection.policy,
        "target_policy_version" => selection.policy_version,
        "target_salt" => selection.salt,
        "target_selection_pool_size" => selection.pool_size,
        "target_selection_index" => selection.target_index,
        "target_semantic_hash" => selection.state.semantic_hash,
        "target_semantic_syndrome_key" => selection.state.syndrome_key,
        "target_semantic_observable_key" => selection.state.observable_key,
        "target_semantic_syndrome_key_encoding" => dem_syndrome_key_encoding(model),
        "target_semantic_observable_key_encoding" => dem_observable_key_encoding(model),
        "target_semantic_syndrome_weight" => selection.state.syndrome_weight,
        "target_semantic_observable_weight" => selection.state.observable_weight,
        "target_reference_decoder" => selection.state.reference_decoder_id,
        "target_reference_recovery" => selection.state.reference_recovery_id,
        "target_representative_fault_count" => length(selection.state.representative_faults),
        "target_decoder_candidate_rank_public" => public_rank,
        "target_visible_in_proxy_limit" => visible_rank > 0,
        "target_rank_within_budget" => visible_rank,
        "eligible_decoder_candidate_count" => selection.pool_size,
        "visible_decoder_proxy_count" => length(visible_entries),
    )
end
