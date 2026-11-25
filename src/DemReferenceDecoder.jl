struct DemDecoderEntry
    syndrome_key::String
    syndrome_bits::BitVector
    syndrome_support::Vector{Int}
    syndrome_weight::Int
    correction_indices::Vector{Int}
    logical_bits::BitVector
    weight::Int
    cost::Float64
end

function dem_fault_cost(fault::DemFaultMechanism)
    p = clamp(fault.probability, eps(Float64), 1.0 - eps(Float64))
    return -log(p / (1.0 - p))
end

function dem_assignment_cost(model::DemParityModel, active::AbstractVector{Int})
    total = 0.0
    for idx in active
        1 <= idx <= length(model.faults) || continue
        total += dem_fault_cost(model.faults[idx])
    end
    return total
end

function dem_decoder_entry(model::DemParityModel, active::AbstractVector{Int})
    if length(active) == 1
        idx = Int(active[begin])
        if 1 <= idx <= length(model.faults)
            fault = model.faults[idx]
            syndrome_support = fault.detector_support
            syndrome = dem_use_sparse_syndrome_key(model) ?
                BitVector() :
                dem_bits_from_support(model.detector_count, syndrome_support)
            logical = dem_bits_from_support(model.observable_count, fault.logical_support)
            return DemDecoderEntry(
                dem_syndrome_key_from_support(model, syndrome_support),
                syndrome,
                copy(syndrome_support),
                length(syndrome_support),
                Int[idx],
                logical,
                1,
                dem_fault_cost(fault),
            )
        end
    end
    active_sorted = sort!(collect(Int, active))
    syndrome_support = dem_syndrome_support(model, active_sorted)
    syndrome = dem_use_sparse_syndrome_key(model) ?
        BitVector() :
        dem_bits_from_support(model.detector_count, syndrome_support)
    logical = dem_logical_bits(model, active_sorted)
    return DemDecoderEntry(
        dem_syndrome_key_from_support(model, syndrome_support),
        syndrome,
        syndrome_support,
        length(syndrome_support),
        active_sorted,
        logical,
        length(active_sorted),
        dem_assignment_cost(model, active_sorted),
    )
end

function dem_entry_rank(entry::DemDecoderEntry)
    return (
        entry.weight,
        entry.cost,
        join(string.(entry.correction_indices), ","),
    )
end

function dem_entry_better(candidate::DemDecoderEntry, incumbent::DemDecoderEntry)
    return dem_entry_rank(candidate) < dem_entry_rank(incumbent)
end

function dem_reference_decoder_table(model::DemParityModel;
    max_weight::Integer=1,
    max_pair_faults::Integer=256)

    table = Dict{String,DemDecoderEntry}()
    function add_entry!(active)
        entry = dem_decoder_entry(model, active)
        old = get(table, entry.syndrome_key, nothing)
        if old === nothing || dem_entry_better(entry, old)
            table[entry.syndrome_key] = entry
        end
    end

    add_entry!(Int[])
    n = length(model.faults)
    if max_weight >= 1
        for idx in 1:n
            add_entry!(Int[idx])
        end
    end
    if max_weight >= 2
        pair_window = min(n, max(Int(max_pair_faults), 0))
        for left in 1:pair_window
            for right in (left + 1):pair_window
                add_entry!(Int[left, right])
            end
        end
    end
    return table
end

function dem_reference_pair_policy(model::DemParityModel,
    max_weight::Integer,
    max_pair_faults::Integer)

    max_weight < 2 && return "disabled"
    pair_window = min(length(model.faults), max(Int(max_pair_faults), 0))
    pair_window <= 1 && return "no-pairs"
    return pair_window == length(model.faults) ? "all-pairs" : "public-prefix-window-pairs"
end

function dem_reference_entry(table::AbstractDict, syndrome_bits::AbstractVector{Bool})
    return get(table, dem_parity_key(syndrome_bits), nothing)
end

function dem_reference_entry(model::DemParityModel,
    table::AbstractDict,
    syndrome_bits::AbstractVector{Bool})

    return get(table, dem_syndrome_key(model, syndrome_bits), nothing)
end

function dem_entry_syndrome_bits(model::DemParityModel, entry::DemDecoderEntry)
    if length(entry.syndrome_bits) == model.detector_count
        return entry.syndrome_bits
    end
    return dem_bits_from_support(model.detector_count, entry.syndrome_support)
end

function dem_entry_signature(entry::Union{Nothing,DemDecoderEntry})
    entry === nothing && return "missing"
    isempty(entry.correction_indices) && return "clean"
    return join(["f" * string(idx) for idx in entry.correction_indices], "+")
end

function dem_entry_record(entry::Union{Nothing,DemDecoderEntry})
    entry === nothing && return Dict{String,Any}(
        "status" => "missing",
        "correction" => "missing",
        "weight" => -1,
        "logical" => "missing",
    )
    return Dict{String,Any}(
        "status" => "ok",
        "correction" => dem_entry_signature(entry),
        "indices" => copy(entry.correction_indices),
        "weight" => entry.weight,
        "cost" => entry.cost,
        "syndrome_weight" => entry.syndrome_weight,
        "logical" => dem_parity_key(entry.logical_bits),
    )
end

function dem_reference_candidate_entries(model::DemParityModel,
    table::AbstractDict;
    public_prefix_count::Integer=0)

    prefix = Int(public_prefix_count)
    out = DemDecoderEntry[]
    prefix_syndromes = Set{String}()
    for idx in 1:min(prefix, length(model.faults))
        push!(prefix_syndromes, dem_decoder_entry(model, Int[idx]).syndrome_key)
    end
    for entry in values(table)
        isempty(entry.correction_indices) && continue
        all(idx -> idx > prefix, entry.correction_indices) || continue
        entry.syndrome_key in prefix_syndromes && continue
        push!(out, entry)
    end
    sort!(out, by=dem_entry_rank)
    return out
end

function dem_reference_candidate_count(model::DemParityModel,
    table::AbstractDict;
    public_prefix_count::Integer=0)

    prefix = Int(public_prefix_count)
    prefix_syndromes = Set{String}()
    for idx in 1:min(prefix, length(model.faults))
        push!(prefix_syndromes, dem_decoder_entry(model, Int[idx]).syndrome_key)
    end
    count = 0
    for entry in values(table)
        isempty(entry.correction_indices) && continue
        all(idx -> idx > prefix, entry.correction_indices) || continue
        entry.syndrome_key in prefix_syndromes && continue
        count += 1
    end
    return count
end

function dem_wrong_decoder_entry(model::DemParityModel,
    table::AbstractDict,
    target::DemDecoderEntry,
    salt::AbstractString)

    alternatives = [
        entry for entry in values(table)
        if entry.syndrome_key != target.syndrome_key &&
            dem_entry_signature(entry) != dem_entry_signature(target)
    ]
    isempty(alternatives) && return nothing
    sort!(alternatives, by=dem_entry_rank)
    logical_alternatives = [
        entry for entry in alternatives
        if dem_parity_key(entry.logical_bits) != dem_parity_key(target.logical_bits)
    ]
    if !isempty(logical_alternatives)
        return logical_alternatives[dem_stable_index(salt * "|logical", length(logical_alternatives))]
    end
    return alternatives[dem_stable_index(salt, length(alternatives))]
end
