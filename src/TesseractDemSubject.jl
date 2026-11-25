struct DemParitySubject
    name::String
    model::DemParityModel
    decoder_table::Dict{String,DemDecoderEntry}
    contract::DemSeededBugContract
    max_fault_weight::Int
    reference_max_weight::Int
    reference_pair_window::Int
    reference_pair_policy::String
    syndrome_record_limit::Int
    oracle_branch_path_constraint::Bool
    decoder_proxy_branch_limit::Int
    semantic_state_count::Int
    decoder_candidate_entries::Vector{DemDecoderEntry}
    syndrome_exprs::Vector{BoolExpr}
end

function DemParitySubject(model::DemParityModel;
    name::AbstractString="",
    bug_class=:decoder_decision_error,
    max_fault_weight::Integer=1,
    reference_max_weight::Integer=max_fault_weight,
    max_pair_faults::Integer=256,
    budget::Integer=16,
    public_prefix_count=nothing,
    syndrome_record_limit::Integer=128,
    oracle_branch_path_constraint::Bool=false,
    decoder_proxy_branch_limit::Integer=0,
    decoder_table=nothing,
    clean_control::Bool=false,
    salt::AbstractString="0",
    target_policy::AbstractString=DEM_SEMANTIC_TARGET_POLICY_VERSION,
    target_policy_version::AbstractString=String(target_policy),
    oracle_region_policy::AbstractString="syndrome_key",
    semantic_states=nothing,
    contract_override=nothing,
    decoder_candidate_entries=nothing,
    syndrome_exprs=nothing)

    isempty(model.faults) && error("DEM parity subject requires at least one error mechanism")
    table = decoder_table === nothing ?
        dem_reference_decoder_table(
            model;
            max_weight=reference_max_weight,
            max_pair_faults=max_pair_faults,
        ) :
        decoder_table
    pair_window = min(length(model.faults), max(Int(max_pair_faults), 0))
    pair_policy = dem_reference_pair_policy(model, reference_max_weight, max_pair_faults)
    states = semantic_states
    contract = contract_override !== nothing ?
        contract_override :
        clean_control ?
        dem_clean_contract(model, table; budget=budget, public_prefix_count=public_prefix_count) :
        begin
            states = states === nothing ?
                dem_weight1_semantic_states(model, table; policy_version=target_policy_version) :
                states
            dem_seeded_bug_contract(
                model,
                table,
                bug_class;
                budget=budget,
                public_prefix_count=public_prefix_count,
                salt=salt,
                target_policy=target_policy,
                target_policy_version=target_policy_version,
                decoder_proxy_branch_limit=decoder_proxy_branch_limit,
                oracle_region_policy=oracle_region_policy,
                semantic_states=states,
            )
        end
    semantic_state_count = states === nothing ? 0 : length(states)
    candidates = decoder_candidate_entries === nothing ?
        dem_reference_candidate_entries(
            model,
            table;
            public_prefix_count=contract.public_prefix_count,
        ) :
        decoder_candidate_entries
    exprs = syndrome_exprs === nothing ?
        (dem_use_sparse_syndrome_key(model) ?
            dem_projected_syndrome_exprs(model, Int(syndrome_record_limit)) :
            dem_syndrome_exprs(model)) :
        syndrome_exprs
    subject_name = isempty(name) ?
        "dem_parity_" * replace(basename(model.source_path), r"[^A-Za-z0-9_.-]" => "_") *
        "_" * String(contract.bug_class) :
        String(name)
    return DemParitySubject(
        subject_name,
        model,
        table,
        contract,
        Int(max_fault_weight),
        Int(reference_max_weight),
        Int(pair_window),
        pair_policy,
        Int(syndrome_record_limit),
        Bool(oracle_branch_path_constraint),
        Int(decoder_proxy_branch_limit),
        semantic_state_count,
        collect(DemDecoderEntry, candidates),
        collect(BoolExpr, exprs),
    )
end

function dem_subject_metadata(subject::DemParitySubject)
    decoder_proxy_candidates = subject.decoder_proxy_branch_limit <= 0 ? 0 : min(
        subject.decoder_proxy_branch_limit,
        length(subject.decoder_candidate_entries),
    )
    target_visibility_metadata = subject.contract.target_selection === nothing ?
        Dict{String,Any}() :
        dem_semantic_target_metadata_from_entries(
            subject.contract.target_selection,
            subject.model,
            subject.decoder_candidate_entries;
            decoder_proxy_branch_limit=subject.decoder_proxy_branch_limit,
        )
    return merge(
        dem_model_summary(subject.model),
        dem_contract_public_metadata(subject.contract),
        target_visibility_metadata,
        Dict{String,Any}(
            "subject_family" => "tesseract_dem_parity",
            "encoding" => "dem_xor_parity",
            "oracle_source" => "pipeline_contract",
            "adapter_mapping" => "Stim detector error model error mechanisms to sparse DEM parity variables",
            "fault_model" => "bounded DEM error-mechanism faults",
            "physical_qubits" => subject.model.qubits,
            "num_detectors" => subject.model.detector_count,
            "num_observables" => subject.model.observable_count,
            "num_dem_error_mechanisms" => length(subject.model.faults),
            "num_valid_weight1_mechanisms" => length(subject.model.faults),
            "max_fault_weight" => subject.max_fault_weight,
            "reference_decoder" => "bounded exact likelihood decoder over DEM parity rows",
            "reference_decoder_max_weight" => subject.reference_max_weight,
            "reference_decoder_pair_policy" => subject.reference_pair_policy,
            "reference_decoder_pair_window" => subject.reference_pair_window,
            "decoder_table_syndromes" => length(subject.decoder_table),
            "num_unique_semantic_states" => subject.semantic_state_count,
            "syndrome_record_limit" => subject.syndrome_record_limit,
            "syndrome_key_encoding" => dem_syndrome_key_encoding(subject.model),
            "observable_key_encoding" => dem_observable_key_encoding(subject.model),
            "oracle_branch_path_constraint" => subject.oracle_branch_path_constraint,
            "oracle_branch_excluded" => !subject.oracle_branch_path_constraint,
            "oracle_region_policy" => subject.contract.oracle_region_policy,
            "oracle_region_kind" => subject.contract.oracle_region_kind,
            "scheduler_visible_oracle_region_metadata" => false,
            "decoder_proxy_branch_limit" => subject.decoder_proxy_branch_limit,
            "decoder_proxy_branch_count" => decoder_proxy_candidates,
            "public_prefix_count" => subject.contract.public_prefix_count,
            "or_index_encoding_used" => dem_encoding_uses_or(subject.model),
        ),
    )
end

function dem_record_syndromes!(trace::ConcolicTrace,
    subject::DemParitySubject,
    syndrome_bits::AbstractVector{Bool},
    syndrome_exprs::AbstractVector{<:BoolExpr})

    limit = min(length(syndrome_bits), length(syndrome_exprs), subject.syndrome_record_limit)
    for idx in 1:limit
        record_syndrome!(
            trace,
            "d" * string(idx - 1),
            syndrome_bits[idx],
            syndrome_exprs[idx],
        )
    end
    if length(syndrome_bits) > limit
        overflow_bits = syndrome_bits[(limit + 1):end]
        overflow_expr = length(syndrome_exprs) == limit + 1 ?
            syndrome_exprs[end] :
            dem_xor_expr(BoolExpr[syndrome_exprs[idx] for idx in (limit + 1):length(syndrome_exprs)])
        record_syndrome!(
            trace,
            "overflow_parity",
            isodd(count(identity, overflow_bits)),
            overflow_expr,
        )
        trace.metadata["syndrome_projection"] = "first_" * string(limit) * "_plus_overflow_parity"
        trace.metadata["active_detector_prefix"] = dem_active_detector_list(syndrome_bits; limit=64)
        trace.metadata["active_detector_count"] = count(identity, syndrome_bits)
    else
        trace.metadata["syndrome_projection"] = "full"
    end
    return trace
end

function dem_record_public_prefix_branches!(trace::ConcolicTrace,
    subject::DemParitySubject)

    vars = dem_fault_vars(subject.model)
    prefix = min(subject.contract.public_prefix_count, length(vars))
    for idx in 1:prefix
        var = vars[idx]
        taken = model_bool(trace.fault_assignments, var)
        record_branch!(
            trace,
            "fault:public_prefix_" * string(idx),
            :fault,
            boolvar(var),
            taken;
            description="public-ranked DEM mechanism prefix branch",
            path_constraint=true,
            source=:semantic,
        )
    end
    return trace
end

function dem_record_decoder_proxy_branches!(trace::ConcolicTrace,
    subject::DemParitySubject,
    syndrome_bits::AbstractVector{Bool},
    syndrome_exprs::AbstractVector{<:BoolExpr})

    limit = max(subject.decoder_proxy_branch_limit, 0)
    limit == 0 && return trace
    candidates = subject.decoder_candidate_entries
    isempty(candidates) && return trace
    recorded = 0
    observed_key = dem_syndrome_key(subject.model, syndrome_bits)
    for (idx, entry) in enumerate(candidates)
        recorded >= limit && break
        entry_syndrome_bits = dem_entry_syndrome_bits(subject.model, entry)
        if length(entry_syndrome_bits) != length(syndrome_exprs)
            entry_syndrome_bits = dem_projected_syndrome_bits(
                entry_syndrome_bits,
                subject.syndrome_record_limit,
            )
        end
        length(entry_syndrome_bits) == length(syndrome_exprs) || continue
        recorded += 1
        record_branch!(
            trace,
            "decoder_proxy:arm_" * string(idx),
            :decoder,
            dem_bits_equal_expr(syndrome_exprs, entry_syndrome_bits),
            entry.syndrome_key == observed_key;
            description="target-independent public decoder proxy arm",
            path_constraint=true,
            source=:semantic,
        )
    end
    trace.metadata["decoder_proxy_branch_count"] = recorded
    return trace
end

function dem_flip_bit(bits::AbstractVector{Bool}, one_based_index::Integer)
    out = collect(bits)
    isempty(out) && return out
    idx = clamp(Int(one_based_index), 1, length(out))
    out[idx] = !out[idx]
    return out
end

function dem_contract_target_hit(subject::DemParitySubject,
    active_faults::AbstractVector{Int})

    subject.contract.bug_class == :clean && return false
    observed_key = dem_oracle_region_key_for_active(
        subject.model,
        subject.contract.oracle_region_kind,
        active_faults,
    )
    return observed_key == subject.contract.oracle_region_key
end

function dem_actual_pipeline(subject::DemParitySubject,
    active_faults::AbstractVector{Int},
    expected_syndrome::AbstractVector{Bool})

    contract = subject.contract
    bug_class = contract.bug_class
    target_hit = dem_contract_target_hit(subject, active_faults)
    decoder_input = collect(expected_syndrome)
    syndrome_mismatch = false
    measurement_misuse = false
    inconsistent_control = false
    boundary_misclassification = false
    observable_mapping_mismatch = false

    if target_hit && bug_class == :syndrome_extraction_wiring
        decoder_input = dem_flip_bit(decoder_input, contract.syndrome_flip_index)
        syndrome_mismatch = true
    elseif target_hit && bug_class == :measurement_result_misuse
        decoder_input = dem_flip_bit(decoder_input, contract.measurement_flip_index)
        measurement_misuse = true
    end

    expected_entry = dem_reference_entry(subject.model, subject.decoder_table, expected_syndrome)
    decoder_entry = dem_reference_entry(subject.model, subject.decoder_table, decoder_input)
    recovery_entry = decoder_entry

    if target_hit && bug_class == :decoder_decision_error
        decoder_entry = contract.wrong_entry
        recovery_entry = contract.wrong_entry
    elseif target_hit && bug_class == :unhandled_syndrome
        decoder_entry = expected_entry
        recovery_entry = nothing
    elseif target_hit && bug_class == :recovery_application_error
        decoder_entry = expected_entry
        recovery_entry = contract.wrong_entry
    elseif target_hit && bug_class == :repeated_round_control_error
        decoder_entry = expected_entry
        recovery_entry = contract.wrong_entry
        inconsistent_control = true
    elseif target_hit && bug_class == :boundary_classification_error
        decoder_entry = expected_entry
        recovery_entry = nothing
        boundary_misclassification = true
    elseif target_hit && bug_class == :observable_mapping_error
        decoder_entry = expected_entry
        recovery_entry = expected_entry
        observable_mapping_mismatch = true
    elseif target_hit && bug_class in (:syndrome_extraction_wiring, :measurement_result_misuse)
        recovery_entry = nothing
    end

    expected_residual = dem_residual_logical_bits(subject.model, active_faults, expected_entry)
    actual_residual = dem_residual_logical_bits(subject.model, active_faults, recovery_entry)
    if target_hit && observable_mapping_mismatch
        actual_residual = dem_flip_bit(actual_residual, contract.observable_flip_index)
    end
    decoder_mismatch = dem_entry_signature(decoder_entry) != dem_entry_signature(expected_entry)
    recovery_mismatch = dem_recovery_mismatch(expected_entry, recovery_entry)
    missing_recovery = recovery_entry === nothing
    logical_mismatch = !dem_logical_ok(actual_residual)
    oracle_fail = target_hit && (
        syndrome_mismatch ||
        measurement_misuse ||
        decoder_mismatch ||
        recovery_mismatch ||
        missing_recovery ||
        logical_mismatch ||
        inconsistent_control ||
        boundary_misclassification ||
        observable_mapping_mismatch
    )

    return Dict{String,Any}(
        "target_hit" => target_hit,
        "decoder_input" => decoder_input,
        "expected_entry" => expected_entry,
        "decoder_entry" => decoder_entry,
        "recovery_entry" => recovery_entry,
        "expected_residual" => expected_residual,
        "actual_residual" => actual_residual,
        "syndrome_mismatch" => target_hit && syndrome_mismatch,
        "measurement_misuse" => target_hit && measurement_misuse,
        "decoder_mismatch" => target_hit && decoder_mismatch,
        "recovery_mismatch" => target_hit && recovery_mismatch,
        "missing_recovery_branch" => target_hit && missing_recovery,
        "logical_mismatch" => target_hit && logical_mismatch,
        "inconsistent_control" => target_hit && inconsistent_control,
        "boundary_misclassification" => target_hit && boundary_misclassification,
        "observable_mapping_mismatch" => target_hit && observable_mapping_mismatch,
        "oracle_fail" => oracle_fail,
    )
end

function run_dem_parity_subject(subject::DemParitySubject, input::AbstractDict)
    vars = dem_fault_vars(subject.model)
    model = normalize_assignment(vars, input)
    active_faults = dem_active_indices(subject.model, model)
    syndrome_bits = dem_syndrome_bits(subject.model, active_faults)
    syndrome_exprs = subject.syndrome_exprs
    target_expr = subject.contract.bug_class == :clean ?
        bconst(false) :
        subject.contract.oracle_region_kind == "syndrome_key" ?
            dem_bits_equal_expr(
                syndrome_exprs,
                length(dem_entry_syndrome_bits(subject.model, subject.contract.target_entry)) == length(syndrome_exprs) ?
                    dem_entry_syndrome_bits(subject.model, subject.contract.target_entry) :
                    dem_projected_syndrome_bits(
                        dem_entry_syndrome_bits(subject.model, subject.contract.target_entry),
                        subject.syndrome_record_limit,
                    ),
            ) :
            bconst(dem_contract_target_hit(subject, active_faults))
    target_hit = dem_contract_target_hit(subject, active_faults)
    pipeline = dem_actual_pipeline(subject, active_faults, syndrome_bits)
    oracle_ok = !Bool(pipeline["oracle_fail"])
    oracle_ok_expr = subject.contract.bug_class == :clean ? bconst(true) : bnot(target_expr)

    trace = ConcolicTrace(
        subject.name;
        code_size=subject.model.qubits == 0 ? nothing : subject.model.qubits,
        distance=subject.model.distance == 0 ? nothing : subject.model.distance,
        fault_vars=vars,
        fault_assignments=model,
        metadata=dem_subject_metadata(subject),
    )
    trace.metadata["fault_weight"] = length(active_faults)
    trace.metadata["active_dem_error_count"] = length(active_faults)
    trace.metadata["target_condition_observed"] = target_hit ? "true" : "false"
    trace.metadata["target_condition_visible_to_scheduler"] = false

    dem_record_public_prefix_branches!(trace, subject)
    dem_record_syndromes!(trace, subject, syndrome_bits, syndrome_exprs)
    dem_record_decoder_proxy_branches!(trace, subject, syndrome_bits, syndrome_exprs)
    if subject.oracle_branch_path_constraint
        record_branch!(
            trace,
            "logical:dem_pipeline_oracle",
            :logical_check,
            oracle_ok_expr,
            oracle_ok;
            description="QECC pipeline oracle accepts iff reference and actual DEM recovery semantics agree",
            path_constraint=true,
            source=:oracle,
        )
    else
        record_oracle_check!(
            trace,
            "logical:dem_pipeline_oracle",
            oracle_ok_expr,
            oracle_ok;
            description="QECC pipeline oracle accepts iff reference and actual DEM recovery semantics agree",
        )
    end

    record_decoder_decision!(trace, "expected", dem_entry_record(pipeline["expected_entry"]))
    record_decoder_decision!(trace, "actual", dem_entry_record(pipeline["decoder_entry"]))
    record_recovery_action!(trace, dem_recovery_action_record(pipeline["recovery_entry"]))
    trace.metadata["expected_recovery"] = dem_recovery_action_record(pipeline["expected_entry"]; role="expected")
    trace.metadata["decoder_input_active_detectors"] =
        dem_active_detector_list(pipeline["decoder_input"]; limit=64)
    trace.metadata["expected_logical_residual"] = dem_logical_record(pipeline["expected_residual"])
    trace.metadata["actual_logical_residual"] = dem_logical_record(pipeline["actual_residual"])

    for key in (
        "syndrome_mismatch",
        "measurement_misuse",
        "decoder_mismatch",
        "recovery_mismatch",
        "missing_recovery_branch",
        "logical_mismatch",
        "inconsistent_control",
        "boundary_misclassification",
        "observable_mapping_mismatch",
    )
        record_logical_verdict!(trace, key, Bool(pipeline[key]))
    end
    record_logical_verdict!(
        trace,
        "residual_weight",
        count(identity, pipeline["actual_residual"]),
    )
    record_logical_verdict!(trace, "oracle_verdict", oracle_ok)
    if Bool(pipeline["oracle_fail"])
        trace.metadata["earliest_divergence_stage"] =
            dem_stage_for_bug_class(subject.contract.bug_class)
    end
    return trace
end
