const BENCHMARK_CHARACTERIZATION_SCHEMA_VERSION =
    "conqec-benchmark-characterization-v1"

const CHARACTERIZATION_FIELD_ORDER = [
    "schema_version",
    "subject_id",
    "subject",
    "subject_family",
    "bug_id",
    "bug_class",
    "mutation_operator",
    "path_sensitive",
    "physical_qubits",
    "qubits",
    "fault_variables",
    "max_fault_weight",
    "admissible_fault_assignments",
    "admissible_assignments",
    "syndrome_bits",
    "reachable_syndrome_values",
    "reachable_syndromes",
    "decoder_arms",
    "recovery_actions",
    "rounds",
    "history_states",
    "seeded_failing_assignments",
    "failing_assignments",
    "estimated_bug_probability",
    "test_budget",
    "budget",
    "exhaustibility_ratio",
    "hardness_bin",
]

function _metadata_value(metadata::AbstractDict, keys::AbstractVector{<:AbstractString};
    default=nothing)

    for key in keys
        haskey(metadata, key) && return metadata[key]
    end
    return default
end

function _metadata_int(metadata::AbstractDict, keys::AbstractVector{<:AbstractString};
    default=nothing)

    value = _metadata_value(metadata, keys; default=nothing)
    value === nothing && return default
    value isa Integer && return Int(value)
    parsed = tryparse(Int, string(value))
    return parsed === nothing ? default : parsed
end

function _metadata_bool(metadata::AbstractDict, keys::AbstractVector{<:AbstractString};
    default=false)

    value = _metadata_value(metadata, keys; default=nothing)
    value === nothing && return default
    value isa Bool && return value
    text = lowercase(strip(string(value)))
    text in ("true", "1", "yes") && return true
    text in ("false", "0", "no") && return false
    return default
end

function _merged_metadata(subject, bug_metadata)
    merged = Dict{String,Any}(subject_metadata(subject))
    if bug_metadata !== nothing
        for (key, value) in bug_metadata
            merged[string(key)] = value
        end
    end
    return merged
end

function _field_value(subject, name::Symbol)
    current = subject
    seen = 0
    while seen < 8
        hasfield(typeof(current), name) && return getfield(current, name)
        if hasfield(typeof(current), :base_subject)
            current = getfield(current, :base_subject)
            seen += 1
        else
            break
        end
    end
    return nothing
end

function _zero_trace(subject, fault_vars::Vector{Symbol})
    try
        return run_subject(subject, zero_assignment(fault_vars))
    catch
        return nothing
    end
end

function _physical_indices_from_fault_vars(fault_vars::Vector{Symbol})
    indices = Set{Int}()
    for var in fault_vars
        text = string(var)
        match_q = match(r"q([0-9]+)", text)
        if match_q !== nothing
            push!(indices, parse(Int, match_q.captures[1]))
            continue
        end
        match_pauli = match(r"^[xyz]([0-9]+)$", text)
        match_pauli !== nothing && push!(indices, parse(Int, match_pauli.captures[1]))
    end
    return indices
end

function _infer_qubits(subject, metadata::AbstractDict, bug_metadata, zero_trace,
    fault_vars::Vector{Symbol})

    explicit = _metadata_int(metadata,
        ["qubits", "physical_qubits", "data_qubits", "code_qubits", "n"];
        default=nothing)
    explicit !== nothing && return explicit

    field_qubits = _field_value(subject, :qubits)
    field_qubits isa Integer && return Int(field_qubits)

    distance = _metadata_int(metadata, ["distance"]; default=nothing)
    distance !== nothing && return distance

    field_distance = _field_value(subject, :distance)
    field_distance isa Integer && return Int(field_distance)

    if zero_trace !== nothing && zero_trace.code_size !== nothing
        return Int(zero_trace.code_size)
    end

    bug_size = bug_metadata === nothing ? nothing :
        _metadata_int(bug_metadata, ["subject_size"]; default=nothing)
    bug_size !== nothing && return bug_size

    indices = _physical_indices_from_fault_vars(fault_vars)
    !isempty(indices) && return length(indices)

    return length(fault_vars)
end

function _infer_max_fault_weight(metadata::AbstractDict)
    max_weight = _metadata_int(metadata,
        ["max_fault_weight", "maximum_fault_weight", "fault_capacity"];
        default=1)
    return max(max_weight, 0)
end

function admissible_fault_assignments(fault_variables::Integer, max_fault_weight::Integer)
    n = max(Int(fault_variables), 0)
    w = max(Int(max_fault_weight), 0)
    w = min(w, n)
    total = big(0)
    for weight in 0:w
        total += binomial(big(n), weight)
    end
    return total
end

function _float_ratio(numerator, denominator)
    denominator == 0 && return 0.0
    return Float64(BigFloat(numerator) / BigFloat(denominator))
end

function hardness_bin(exhaustibility_ratio::Real)
    ratio = Float64(exhaustibility_ratio)
    ratio > 0.5 && return "Easy"
    ratio < 0.01 && return "Hard"
    return "Medium"
end

function _enumerate_characterization(subject, fault_vars::Vector{Symbol},
    max_fault_weight::Integer; enum_limit::Integer)

    admissible = admissible_fault_assignments(length(fault_vars), max_fault_weight)
    admissible > enum_limit && return nothing

    syndromes = Set{String}()
    decoder_branch_ids = Set{String}()
    decoder_outputs = Set{String}()
    recoveries = Set{String}()
    histories = Set{String}()
    failing = 0
    syndrome_bits = 0

    seeds = generate_fault_seeds(fault_vars; max_fault_weight=max_fault_weight,
        include_zero=true)
    for model in seeds
        trace = run_subject(subject, model)
        syndrome_bits = max(syndrome_bits, length(trace.syndrome_values))
        push!(syndromes, syndrome_key(trace))
        push!(decoder_outputs, decoder_output_key(trace))
        push!(recoveries, recovery_action_key(trace))
        for guard in trace.branch_guards
            guard.stage == :decoder && push!(decoder_branch_ids, guard.id)
        end
        if haskey(trace.metadata, "syndrome_history_key")
            push!(histories, string(trace.metadata["syndrome_history_key"]))
        end
        if haskey(trace.decoder_decisions, "observed_history")
            push!(histories, string(trace.decoder_decisions["observed_history"]))
        end
        fault_weight(model, fault_vars) > 0 && trace_has_bug(trace) && (failing += 1)
    end

    decoder_arm_count = isempty(decoder_branch_ids) ?
        length(decoder_outputs) : length(decoder_branch_ids)
    return Dict{String,Any}(
        "syndrome_bits" => syndrome_bits,
        "reachable_syndromes" => length(syndromes),
        "decoder_arms" => decoder_arm_count,
        "recovery_actions" => length(recoveries),
        "history_states" => length(histories),
        "seeded_failing_assignments" => failing,
    )
end

function _inferred_upper_reachable_syndromes(syndrome_bits::Integer, admissible)
    syndrome_bits <= 0 && return 0
    cap = big(2)^Int(syndrome_bits)
    return Int(min(cap, big(admissible) + 1))
end

function _fallback_int(metadata::AbstractDict, aliases::Vector{String}, exact,
    exact_key::AbstractString, fallback::Integer)

    explicit = _metadata_int(metadata, aliases; default=nothing)
    explicit !== nothing && return explicit
    if exact !== nothing && haskey(exact, exact_key)
        return Int(exact[exact_key])
    end
    return Int(fallback)
end

function benchmark_characterization_row(config; budget_override=nothing,
    enum_limit::Integer=50000)

    subject = config.subject
    fault_vars = subject_fault_vars(subject)
    bug_metadata = config_bug_metadata(config)
    metadata = _merged_metadata(subject, bug_metadata)
    zero = _zero_trace(subject, fault_vars)
    max_weight = _infer_max_fault_weight(metadata)
    admissible = _metadata_value(metadata,
        ["admissible_assignments", "admissible_fault_assignments",
            "fault_assignment_count", "search_space"],
        default=nothing)
    admissible = admissible === nothing ?
        admissible_fault_assignments(length(fault_vars), max_weight) :
        parse(BigInt, string(admissible))
    exact = _enumerate_characterization(subject, fault_vars, max_weight;
        enum_limit=enum_limit)

    budget = budget_override === nothing ? Int(config.max_tests) : Int(budget_override)
    subject_family = String(_metadata_value(metadata,
        ["subject_family", "benchmark_family"]; default="unknown"))
    bug_id = bug_metadata === nothing ? "none" : String(bug_metadata["bug_id"])
    bug_class = bug_metadata === nothing ? "clean" : String(bug_metadata["bug_class"])
    mutation_operator = bug_metadata === nothing ? "none" :
        String(bug_metadata["mutation_operator"])
    path_sensitive = _metadata_bool(metadata, ["path_sensitive"]; default=false)
    qubits = _infer_qubits(subject, metadata, bug_metadata, zero, fault_vars)
    syndrome_bits = _fallback_int(metadata,
        ["syndrome_bits", "num_syndrome_bits", "check_bits"], exact, "syndrome_bits",
        zero === nothing ? 0 : length(zero.syndrome_values))
    reachable = _fallback_int(metadata,
        ["reachable_syndromes", "reachable_syndrome_values",
            "num_reachable_syndromes"],
        exact, "reachable_syndromes",
        _inferred_upper_reachable_syndromes(syndrome_bits, admissible))
    decoder_arms = _fallback_int(metadata,
        ["decoder_arms", "decoder_arm_count", "num_decoder_arms"],
        exact, "decoder_arms", max(reachable, 1))
    recovery_actions = _fallback_int(metadata,
        ["recovery_actions", "recovery_action_count", "num_recovery_actions"],
        exact, "recovery_actions", max(decoder_arms, 1))
    rounds = _metadata_int(metadata, ["rounds", "repeated_rounds"]; default=nothing)
    rounds === nothing && (rounds = _field_value(subject, :rounds))
    rounds = rounds isa Integer ? Int(rounds) : 1
    history_states = _fallback_int(metadata,
        ["history_states", "round_history_states", "num_history_states"],
        exact, "history_states", rounds > 1 ? reachable : 0)
    failing_assignments = _fallback_int(metadata,
        ["seeded_failing_assignments", "failing_assignments",
            "bug_failing_assignments"],
        exact, "seeded_failing_assignments", bug_metadata === nothing ? 0 : 1)
    bug_probability = _float_ratio(failing_assignments, admissible)
    exhaustibility = _float_ratio(budget, admissible)

    return Dict{String,Any}(
        "schema_version" => BENCHMARK_CHARACTERIZATION_SCHEMA_VERSION,
        "subject_id" => String(config.label),
        "subject" => String(config.label),
        "subject_family" => subject_family,
        "bug_id" => bug_id,
        "bug_class" => bug_class,
        "mutation_operator" => mutation_operator,
        "path_sensitive" => path_sensitive,
        "physical_qubits" => qubits,
        "qubits" => qubits,
        "fault_variables" => length(fault_vars),
        "max_fault_weight" => max_weight,
        "admissible_fault_assignments" => admissible,
        "admissible_assignments" => admissible,
        "syndrome_bits" => syndrome_bits,
        "reachable_syndrome_values" => reachable,
        "reachable_syndromes" => reachable,
        "decoder_arms" => decoder_arms,
        "recovery_actions" => recovery_actions,
        "rounds" => rounds,
        "history_states" => history_states,
        "seeded_failing_assignments" => failing_assignments,
        "failing_assignments" => failing_assignments,
        "estimated_bug_probability" => bug_probability,
        "test_budget" => budget,
        "budget" => budget,
        "exhaustibility_ratio" => exhaustibility,
        "hardness_bin" => hardness_bin(exhaustibility),
    )
end

function benchmark_characterization_rows(configs=paper_subject_configs();
    budget_override=nothing, enum_limit::Integer=50000)

    return Dict{String,Any}[
        benchmark_characterization_row(config; budget_override=budget_override,
            enum_limit=enum_limit)
        for config in configs
    ]
end

function _characterization_table_rows(rows)
    sorted_rows = sort!(copy(rows), by=row -> (
        string(get(row, "bug_class", "")),
        string(get(row, "subject", "")),
    ))
    return Vector{String}[
        [
            string(row["subject"]),
            string(row["bug_id"]),
            string(row["bug_class"]),
            string(row["qubits"]),
            string(row["fault_variables"]),
            string(row["max_fault_weight"]),
            string(row["admissible_assignments"]),
            string(row["syndrome_bits"]),
            string(row["reachable_syndromes"]),
            string(row["decoder_arms"]),
            string(row["recovery_actions"]),
            string(row["rounds"]),
            string(row["history_states"]),
            string(row["seeded_failing_assignments"]),
            string(round(Float64(row["estimated_bug_probability"]); sigdigits=4)),
            string(row["budget"]),
            string(round(Float64(row["exhaustibility_ratio"]); sigdigits=4)),
            string(row["hardness_bin"]),
        ]
        for row in sorted_rows
    ]
end

function write_benchmark_characterization_table(path::AbstractString, rows)
    headers = [
        "Subject",
        "Bug",
        "Class",
        "Qubits",
        "Fault vars",
        "Max w",
        "Assignments",
        "S bits",
        "Reach S",
        "Decoder arms",
        "Recovery actions",
        "Rounds",
        "History states",
        "Failing",
        "Bug prob.",
        "Budget",
        "Exhaust.",
        "Bin",
    ]
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "% Generated from benchmark_characterization.jsonl; do not edit by hand.")
        println(io, "\\begin{table*}[t]")
        println(io, "\\centering")
        println(io, "\\caption{ConQEC benchmark characterization. Assignments use subject-provided admissible search-space metadata when present; otherwise they count assignments within the modeled fault-capacity bound.}")
        println(io, "\\label{tab:conqec-subject-characterization}")
        println(io, "\\scriptsize")
        println(io, "\\resizebox{\\textwidth}{!}{%")
        println(io, "\\begin{tabular}{", repeat("l", length(headers)), "}")
        println(io, "\\toprule")
        println(io, join(latex_escape.(headers), " & "), " \\\\")
        println(io, "\\midrule")
        for row in _characterization_table_rows(rows)
            println(io, join(latex_escape.(row), " & "), " \\\\")
        end
        println(io, "\\bottomrule")
        println(io, "\\end{tabular}")
        println(io, "}%")
        println(io, "\\end{table*}")
    end
    return path
end

function write_benchmark_characterization_outputs(output_dir::AbstractString, rows)
    raw_dir = joinpath(output_dir, "raw")
    table_dir = joinpath(output_dir, "tables")
    raw_path = joinpath(raw_dir, "benchmark_characterization.jsonl")
    table_path = joinpath(table_dir, "table_subject_characterization.tex")
    csv_path = joinpath(table_dir, "table_subject_characterization.csv")
    write_jsonl(raw_path, rows)
    write_benchmark_characterization_table(table_path, rows)
    write_csv_table(csv_path, CHARACTERIZATION_FIELD_ORDER,
        Vector{String}[
            [string(get(row, field, "")) for field in CHARACTERIZATION_FIELD_ORDER]
            for row in rows
        ])
    return Dict{String,String}(
        "raw" => raw_path,
        "table" => table_path,
        "csv" => csv_path,
    )
end
