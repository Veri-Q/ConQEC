function dem_recovery_logical_bits(model::DemParityModel,
    entry::Union{Nothing,DemDecoderEntry})

    entry === nothing && return falses(model.observable_count) |> collect
    return copy(entry.logical_bits)
end

function dem_residual_logical_bits(model::DemParityModel,
    active_faults::AbstractVector{Int},
    recovery_entry::Union{Nothing,DemDecoderEntry})

    return dem_xor_bits(
        dem_logical_bits(model, active_faults),
        dem_recovery_logical_bits(model, recovery_entry),
    )
end

dem_logical_ok(bits::AbstractVector{Bool}) = !any(identity, bits)

function dem_recovery_action_record(entry::Union{Nothing,DemDecoderEntry};
    role::AbstractString="actual")

    record = dem_entry_record(entry)
    record["role"] = String(role)
    record["action"] = get(record, "correction", "missing")
    return record
end

function dem_recovery_mismatch(expected::Union{Nothing,DemDecoderEntry},
    actual::Union{Nothing,DemDecoderEntry})

    return dem_entry_signature(expected) != dem_entry_signature(actual)
end

function dem_logical_record(bits::AbstractVector{Bool})
    return Dict{String,Any}(
        "bits" => dem_parity_key(bits),
        "weight" => count(identity, bits),
        "ok" => dem_logical_ok(bits),
    )
end

function dem_stage_for_bug_class(bug_class::Symbol)
    bug_class == :syndrome_extraction_wiring && return "syndrome"
    bug_class == :measurement_result_misuse && return "measurement_result"
    bug_class == :decoder_decision_error && return "decoder"
    bug_class == :unhandled_syndrome && return "recovery"
    bug_class == :recovery_application_error && return "recovery"
    bug_class == :repeated_round_control_error && return "repeated_round_control"
    bug_class == :boundary_classification_error && return "boundary_classification"
    bug_class == :observable_mapping_error && return "observable_mapping"
    return "logical_check"
end
