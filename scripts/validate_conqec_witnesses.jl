const REQUIRED_WITNESS_KEYS = [
    "schema_version",
    "generated_by",
    "solver_backend",
    "exploration_policy",
    "exploration_settings",
    "subject_name",
    "fault_pattern",
    "observed_syndrome",
    "decoder_output",
    "expected_decoder_output",
    "recovery_actually_applied",
    "expected_recovery",
    "logical_verdicts",
    "oracle_verdict",
    "primary_oracle",
    "triggered_oracles",
    "oracle_summary",
    "oracle_witnesses",
    "earliest_divergence_stage",
    "path",
    "metadata",
    "symbolic_stabilizer",
    "minimization",
]

const EXPECTED_SCHEMA_VERSION = "conqec-witness-v1"
const EXPECTED_GENERATED_BY = "ConQEC.jl AE prototype"
const LEGACY_ENUMERATOR_BACKEND = "bruteforce_boolean"
const KNOWN_SOLVER_BACKENDS = Set([
    LEGACY_ENUMERATOR_BACKEND,
    "bruteforce-bool",
    "counted-bruteforce-bool",
    "direct_concolic_trace",
    "smtlib-export",
    "z3",
    "bitwuzla",
])
const KNOWN_FAILURE_ORACLE_IDS = Set([
    "O1_LOGICAL_MISMATCH",
    "O2_DECODER_MISMATCH",
    "O3_RESIDUAL_CORRECTABLE_ERROR",
    "O4_DEAD_RECOVERY_BRANCH",
    "O5_INCONSISTENT_CONTROL",
])

function usage(io::IO=stdout)
    print(io, """
ConQEC witness schema/diagnostics validator

Usage:
  julia --project=. scripts/validate_conqec_witnesses.jl artifacts/witnesses/*.json
  julia --project=. scripts/validate_conqec_witnesses.jl PATH [PATH ...]

The validator intentionally uses only Base Julia. It does not parse JSON; it
checks for the paper-required ConQEC witness keys and a small set of
subject-specific diagnostic fields using regex/substring checks.
""")
end

function json_key_regex(key::AbstractString)
    return Regex("\"" * key * "\"\\s*:")
end

function regex_literal(text::AbstractString)
    return replace(String(text), r"([\\.^$|?*+()\[\]{}])" => s"\\\1")
end

function has_json_key(text::AbstractString, key::AbstractString)
    return occursin(json_key_regex(key), text)
end

function has_json_bool_key(text::AbstractString, key::AbstractString, value::Bool)
    literal = value ? "true" : "false"
    return occursin(Regex("\"" * key * "\"\\s*:\\s*" * literal), text)
end

function has_json_string_key(text::AbstractString, key::AbstractString, value::AbstractString)
    return occursin(Regex("\"" * key * "\"\\s*:\\s*\"" * regex_literal(value) * "\""), text)
end

function json_int_value(text::AbstractString, key::AbstractString)
    value_match = match(Regex("\"" * key * "\"\\s*:\\s*(\\d+)"), text)
    value_match === nothing && return nothing
    return parse(Int, value_match.captures[1])
end

function json_array_text(text::AbstractString, key::AbstractString)
    key_match = match(json_key_regex(key), text)
    key_match === nothing && return nothing

    start_index = findnext('[', text, key_match.offset + ncodeunits(key_match.match))
    start_index === nothing && return nothing

    depth = 0
    in_string = false
    escaped = false
    for index in start_index:lastindex(text)
        char = text[index]
        if in_string
            if escaped
                escaped = false
            elseif char == '\\'
                escaped = true
            elseif char == '"'
                in_string = false
            end
        elseif char == '"'
            in_string = true
        elseif char == '['
            depth += 1
        elseif char == ']'
            depth -= 1
            depth == 0 && return text[start_index:index]
        end
    end

    return nothing
end

function fault_pattern_active_count(text::AbstractString)
    pattern_text = json_array_text(text, "fault_pattern")
    pattern_text === nothing && return nothing
    return length(collect(eachmatch(r"\"active\"\s*:\s*true", pattern_text)))
end

function triggered_oracle_ids(text::AbstractString)
    oracle_text = json_array_text(text, "triggered_oracles")
    oracle_text === nothing && return nothing
    return [match.captures[1] for match in eachmatch(r"\"id\"\s*:\s*\"([^\"]+)\"", oracle_text)]
end

function oracle_witness_record_count(text::AbstractString)
    oracle_witness_text = json_array_text(text, "oracle_witnesses")
    oracle_witness_text === nothing && return nothing
    return length(collect(eachmatch(r"\"oracle_id\"\s*:", oracle_witness_text)))
end

function primary_oracle_id(text::AbstractString)
    primary_match = match(
        r"\"primary_oracle\"\s*:\s*\{[^{}]*\"id\"\s*:\s*\"([^\"]+)\"",
        text,
    )
    primary_match === nothing && return nothing
    return primary_match.captures[1]
end

function check_expected_string!(errors::Vector{String},
        text::AbstractString,
        key::AbstractString,
        expected::AbstractString,
        label::AbstractString=key)
    if !has_json_key(text, key)
        push!(errors, "missing $(label): expected $(expected)")
    elseif !has_json_string_key(text, key, expected)
        push!(errors, "invalid $(label): expected $(expected)")
    end
end

function json_string_value(text::AbstractString, key::AbstractString)
    value_match = match(Regex("\"" * key * "\"\\s*:\\s*\"([^\"]+)\""), text)
    value_match === nothing && return nothing
    return value_match.captures[1]
end

function check_solver_backend!(errors::Vector{String}, text::AbstractString)
    backend = json_string_value(text, "solver_backend")
    if backend === nothing
        push!(errors, "missing solver_backend: expected known ConQEC backend")
    elseif backend in KNOWN_SOLVER_BACKENDS || startswith(backend, "external-smt:")
        return nothing
    else
        push!(errors, "invalid solver_backend: expected known ConQEC backend")
    end
end

function check_fault_weight_consistency!(errors::Vector{String}, text::AbstractString)
    active_count = fault_pattern_active_count(text)
    if active_count === nothing
        push!(errors, "fault_pattern is not a JSON array with active fields")
        return
    end

    minimized_weight = json_int_value(text, "minimized_fault_weight")
    original_weight = json_int_value(text, "original_fault_weight")

    if minimized_weight === nothing
        push!(errors, "missing minimization.minimized_fault_weight")
    elseif active_count != minimized_weight
        push!(
            errors,
            "fault_pattern active count $(active_count) disagrees with minimized_fault_weight $(minimized_weight)",
        )
    end

    if original_weight === nothing
        push!(errors, "missing minimization.original_fault_weight")
    elseif original_weight < active_count
        push!(
            errors,
            "original_fault_weight $(original_weight) is smaller than fault_pattern active count $(active_count)",
        )
    end

    if original_weight !== nothing && minimized_weight !== nothing && original_weight < minimized_weight
        push!(
            errors,
            "original_fault_weight $(original_weight) is smaller than minimized_fault_weight $(minimized_weight)",
        )
    end
end

function check_oracle_taxonomy!(errors::Vector{String},
        text::AbstractString,
        path::AbstractString)

    ids = triggered_oracle_ids(text)
    if ids === nothing
        push!(errors, "triggered_oracles is not a JSON array")
        return
    end

    for id in ids
        id in KNOWN_FAILURE_ORACLE_IDS ||
            push!(errors, "unknown failure oracle id: $(id)")
    end

    if length(ids) != length(unique(ids))
        push!(errors, "triggered_oracles contains duplicate ids")
    end

    if has_json_bool_key(text, "oracle_verdict", false) && isempty(ids)
        push!(errors, "failing witness has no triggered_oracles")
    end

    primary_id = primary_oracle_id(text)
    if has_json_bool_key(text, "oracle_verdict", false)
        if primary_id === nothing
            push!(errors, "failing witness missing primary_oracle.id")
        elseif !(primary_id in ids)
            push!(
                errors,
                "primary_oracle $(primary_id) is not listed in triggered_oracles",
            )
        elseif !(primary_id in KNOWN_FAILURE_ORACLE_IDS)
            push!(errors, "unknown primary failure oracle id: $(primary_id)")
        end
    end

    has_json_key(text, "triggered_ids") ||
        push!(errors, "oracle_summary missing triggered_ids")
    has_json_key(text, "triggered_count") ||
        push!(errors, "oracle_summary missing triggered_count")
    has_json_key(text, "summary") ||
        push!(errors, "oracle_summary missing summary")

    triggered_count = json_int_value(text, "triggered_count")
    if triggered_count !== nothing && triggered_count != length(ids)
        push!(
            errors,
            "oracle_summary.triggered_count $(triggered_count) disagrees with triggered_oracles length $(length(ids))",
        )
    end

    oracle_witness_count = oracle_witness_record_count(text)
    if oracle_witness_count === nothing
        push!(errors, "oracle_witnesses is not a JSON array")
    elseif oracle_witness_count != length(ids)
        push!(
            errors,
            "oracle_witnesses count $(oracle_witness_count) disagrees with triggered_oracles length $(length(ids))",
        )
    end

    if (subject_mentions(text, path, "syndrome_wiring") ||
            subject_mentions(text, path, "measurement_misuse")) &&
            "O2_DECODER_MISMATCH" in ids
        push!(errors, "syndrome/measurement witness must not classify cascaded decoder_mismatch as O2")
    end

    if (subject_mentions(text, path, "buggy_decoder_table") ||
            subject_mentions(text, path, "priority_decoder_bug") ||
            subject_mentions(text, path, "decoder_neighbor_bug")) &&
            !("O2_DECODER_MISMATCH" in ids)
        push!(errors, "decoder-table witness missing O2_DECODER_MISMATCH")
    end

    if (subject_mentions(text, path, "wrong_recovery_target") ||
            subject_mentions(text, path, "recovery_boundary_bug")) &&
            "O2_DECODER_MISMATCH" in ids
        push!(errors, "wrong-recovery witness must not trigger O2_DECODER_MISMATCH")
    end

    if subject_mentions(text, path, "missing_recovery_branch") &&
            !("O4_DEAD_RECOVERY_BRANCH" in ids)
        push!(errors, "missing-recovery witness missing O4_DEAD_RECOVERY_BRANCH")
    end

    if subject_mentions(text, path, "history_drop_bug")
        "O2_DECODER_MISMATCH" in ids ||
            push!(errors, "history-drop witness missing O2_DECODER_MISMATCH")
    end

    if subject_mentions(text, path, "inconsistent_control_bug")
        "O5_INCONSISTENT_CONTROL" in ids ||
            push!(errors, "inconsistent-control witness missing O5_INCONSISTENT_CONTROL")
        "O2_DECODER_MISMATCH" in ids &&
            push!(errors, "inconsistent-control witness must classify relational mismatch as O5, not O2")
    end
end

function subject_mentions(text::AbstractString, path::AbstractString, marker::AbstractString)
    if occursin(marker, basename(path))
        return true
    end

    subject_match = match(r"\"subject_name\"\s*:\s*\"([^\"]+)\"", text)
    return subject_match !== nothing && occursin(marker, subject_match.captures[1])
end

function subject_name_value(text::AbstractString)
    subject_match = match(r"\"subject_name\"\s*:\s*\"([^\"]+)\"", text)
    subject_match === nothing && return nothing
    return subject_match.captures[1]
end

function large_repetition_qubits(text::AbstractString, path::AbstractString)
    subject = subject_name_value(text)
    subject === nothing && (subject = basename(path))
    matched = match(r"large_repetition_n([0-9]+)_", subject)
    matched === nothing && return nothing
    return parse(Int, matched.captures[1])
end

function validation_errors(path::AbstractString)
    errors = String[]

    if !isfile(path)
        push!(errors, "not a file")
        return errors
    end

    text = read(path, String)
    isempty(strip(text)) && push!(errors, "empty file")

    for key in REQUIRED_WITNESS_KEYS
        has_json_key(text, key) || push!(errors, "missing required key: $(key)")
    end

    check_expected_string!(errors, text, "schema_version", EXPECTED_SCHEMA_VERSION)
    check_expected_string!(errors, text, "generated_by", EXPECTED_GENERATED_BY)
    check_solver_backend!(errors, text)
    has_json_key(text, "branch_flip_order") ||
        push!(errors, "missing exploration_policy.branch_flip_order")
    has_json_key(text, "fault_pattern") && check_fault_weight_consistency!(errors, text)
    check_oracle_taxonomy!(errors, text, path)

    if subject_mentions(text, path, "syndrome_wiring")
        has_json_key(text, "syndrome_diagnostics") ||
            push!(errors, "syndrome-wiring witness missing syndrome_diagnostics")
    end

    if subject_mentions(text, path, "measurement_misuse")
        has_json_key(text, "measurement_misuse") ||
            push!(errors, "measurement-misuse witness missing measurement_misuse diagnostics")
        has_json_key(text, "misused_observable") ||
            push!(errors, "measurement-misuse witness missing misused_observable")
        has_json_bool_key(text, "measurement_misuse", true) ||
            push!(errors, "measurement-misuse witness missing measurement_misuse: true")
    end

    if subject_mentions(text, path, "missing_recovery_branch")
        has_json_bool_key(text, "missing_recovery_branch", true) ||
            push!(errors, "missing-recovery witness missing missing_recovery_branch: true")
    end

    if subject_mentions(text, path, "phaseflip")
        has_json_string_key(text, "subject_family", "three_qubit_phaseflip") ||
            push!(errors, "phase-flip witness missing subject_family: three_qubit_phaseflip")
        has_json_key(text, "syndrome_diagnostics") ||
            push!(errors, "phase-flip witness missing syndrome_diagnostics")
        has_json_key(text, "css_orientation") ||
            push!(errors, "phase-flip witness missing css_orientation")
    end

    if subject_mentions(text, path, "steane_css")
        has_json_string_key(text, "subject_family", "steane_css_code") ||
            push!(errors, "Steane witness missing subject_family: steane_css_code")
        has_json_key(text, "parity_check_columns") ||
            push!(errors, "Steane witness missing parity_check_columns")
        has_json_key(text, "css_orientation") ||
            push!(errors, "Steane witness missing css_orientation")
        has_json_key(text, "stabilizer_checks") ||
            push!(errors, "Steane witness missing stabilizer_checks")
        has_json_key(text, "logical_operators") ||
            push!(errors, "Steane witness missing logical_operators")
        has_json_key(text, "residual_logical_class") ||
            push!(errors, "Steane witness missing residual_logical_class")
        syndrome_space_size = json_int_value(text, "syndrome_space_size")
        syndrome_space_size == 64 ||
            push!(errors, "Steane witness missing syndrome_space_size: 64")
        has_json_bool_key(text, "decoder_table_total", true) ||
            push!(errors, "Steane witness missing decoder_table_total: true")
    end

    if subject_mentions(text, path, "steane_css_buggy_decoder")
        has_json_bool_key(text, "decoder_mismatch", true) ||
            push!(errors, "Steane decoder witness missing decoder_mismatch: true")
        has_json_string_key(text, "decoder_output", "q2") ||
            push!(errors, "Steane decoder witness missing decoder_output: q2")
        has_json_string_key(text, "expected_decoder_output", "q1") ||
            push!(errors, "Steane decoder witness missing expected_decoder_output: q1")
    end

    if subject_mentions(text, path, "surface_d3_x_memory")
        has_json_string_key(text, "subject_family", "surface_code_kernel") ||
            push!(errors, "surface-code witness missing subject_family: surface_code_kernel")
        has_json_key(text, "plaquette_syndromes") ||
            push!(errors, "surface-code witness missing plaquette_syndromes")
        has_json_key(text, "single_fault_syndromes") ||
            push!(errors, "surface-code witness missing single_fault_syndromes")
        has_json_key(text, "data_qubit_layout") ||
            push!(errors, "surface-code witness missing data_qubit_layout")
        has_json_key(text, "surface_stabilizers") ||
            push!(errors, "surface-code witness missing surface_stabilizers")
        has_json_key(text, "logical_operators") ||
            push!(errors, "surface-code witness missing logical_operators")
        has_json_key(text, "residual_logical_class") ||
            push!(errors, "surface-code witness missing residual_logical_class")
        json_int_value(text, "axis_syndrome_space_size") == 16 ||
            push!(errors, "surface-code witness missing axis_syndrome_space_size: 16")
        json_int_value(text, "syndrome_space_size") == 256 ||
            push!(errors, "surface-code witness missing syndrome_space_size: 256")
        has_json_bool_key(text, "decoder_table_total", true) ||
            push!(errors, "surface-code witness missing decoder_table_total: true")
    end

    if subject_mentions(text, path, "surface_d3_x_memory_buggy_decoder")
        has_json_bool_key(text, "decoder_mismatch", true) ||
            push!(errors, "surface-code decoder witness missing decoder_mismatch: true")
        has_json_string_key(text, "decoder_output", "q2") ||
            push!(errors, "surface-code decoder witness missing decoder_output: q2")
        has_json_string_key(text, "expected_decoder_output", "q1") ||
            push!(errors, "surface-code decoder witness missing expected_decoder_output: q1")
    end

    if subject_mentions(text, path, "large_repetition")
        has_json_string_key(text, "subject_family", "large_repetition_code") ||
            push!(errors, "large-repetition witness missing subject_family: large_repetition_code")
        has_json_key(text, "large_scale_summary") ||
            push!(errors, "large-repetition witness missing large_scale_summary")
        has_json_bool_key(text, "compact_large_repetition", true) ||
            push!(errors, "large-repetition witness missing compact_large_repetition: true")

        n = large_repetition_qubits(text, path)
        if n !== nothing
            qubits = json_int_value(text, "qubits")
            syndrome_bits = json_int_value(text, "syndrome_bits")
            generator_count = json_int_value(text, "generator_count")
            qubits == n ||
                push!(errors, "large-repetition witness qubits mismatch: expected $(n)")
            syndrome_bits == n - 1 ||
                push!(errors, "large-repetition witness syndrome_bits mismatch: expected $(n - 1)")
            generator_count == n - 1 ||
                push!(errors, "large-repetition witness generator_count mismatch: expected $(n - 1)")
        end

        ids = triggered_oracle_ids(text)
        if subject_mentions(text, path, "decoder_boundary_bug")
            has_json_bool_key(text, "decoder_mismatch", true) ||
                push!(errors, "large decoder-boundary witness missing decoder_mismatch: true")
            has_json_string_key(text, "decoder_output", "q2") ||
                push!(errors, "large decoder-boundary witness missing decoder_output: q2")
            has_json_string_key(text, "expected_decoder_output", "q1") ||
                push!(errors, "large decoder-boundary witness missing expected_decoder_output: q1")
            ids !== nothing && ("O2_DECODER_MISMATCH" in ids) ||
                push!(errors, "large decoder-boundary witness missing O2_DECODER_MISMATCH")
        elseif subject_mentions(text, path, "wrong_recovery_target") ||
                subject_mentions(text, path, "recovery_boundary_bug")
            has_json_bool_key(text, "decoder_mismatch", false) ||
                push!(errors, "large wrong-recovery witness must preserve decoder_mismatch: false")
            has_json_bool_key(text, "recovery_mismatch", true) ||
                push!(errors, "large wrong-recovery witness missing recovery_mismatch: true")
            has_json_string_key(text, "decoder_output", "q1") ||
                push!(errors, "large wrong-recovery witness missing decoder_output: q1")
            has_json_string_key(text, "expected_decoder_output", "q1") ||
                push!(errors, "large wrong-recovery witness missing expected_decoder_output: q1")
            ids !== nothing && ("O3_RESIDUAL_CORRECTABLE_ERROR" in ids) ||
                push!(errors, "large wrong-recovery witness missing O3_RESIDUAL_CORRECTABLE_ERROR")
            ids !== nothing && !("O2_DECODER_MISMATCH" in ids) ||
                push!(errors, "large wrong-recovery witness must not trigger O2_DECODER_MISMATCH")
        elseif subject_mentions(text, path, "unhandled_syndrome_bug")
            has_json_bool_key(text, "decoder_mismatch", true) ||
                push!(errors, "large unhandled-syndrome witness missing decoder_mismatch: true")
            has_json_bool_key(text, "missing_recovery_branch", true) ||
                push!(errors, "large unhandled-syndrome witness missing missing_recovery_branch: true")
            has_json_string_key(text, "decoder_output", "uncorrectable") ||
                push!(errors, "large unhandled-syndrome witness missing decoder_output: uncorrectable")
            has_json_string_key(text, "expected_decoder_output", "q1") ||
                push!(errors, "large unhandled-syndrome witness missing expected_decoder_output: q1")
            ids !== nothing && ("O4_DEAD_RECOVERY_BRANCH" in ids) ||
                push!(errors, "large unhandled-syndrome witness missing O4_DEAD_RECOVERY_BRANCH")
        end
    end

    if subject_mentions(text, path, "repetition_d") &&
            subject_mentions(text, path, "decoder_neighbor_bug")
        has_json_bool_key(text, "decoder_mismatch", true) ||
            push!(errors, "repetition decoder-neighbor witness missing decoder_mismatch: true")
        has_json_bool_key(text, "recovery_mismatch", true) ||
            push!(errors, "repetition decoder-neighbor witness missing recovery_mismatch: true")
    end

    if subject_mentions(text, path, "round_repetition")
        has_json_string_key(text, "subject_family", "round_repetition_code") ||
            push!(errors, "round-repetition witness missing subject_family: round_repetition_code")
        has_json_key(text, "syndrome_history") ||
            push!(errors, "round-repetition witness missing syndrome_history")
        has_json_key(text, "syndrome_history_key") ||
            push!(errors, "round-repetition witness missing syndrome_history_key")
        has_json_key(text, "decoder_diagnostics") ||
            push!(errors, "round-repetition witness missing decoder_diagnostics")
        has_json_key(text, "observed_history") ||
            push!(errors, "round-repetition witness missing observed_history")
        has_json_key(text, "decoder_history_used") ||
            push!(errors, "round-repetition witness missing decoder_history_used")
    end

    if subject_mentions(text, path, "history_drop_bug")
        has_json_key(text, "history_drop_bug") ||
            push!(errors, "history-drop witness missing history_drop_bug diagnostics")
        has_json_key(text, "dropped_round") ||
            push!(errors, "history-drop witness missing dropped_round")
        has_json_bool_key(text, "history_mismatch", true) ||
            push!(errors, "history-drop witness missing history_mismatch: true")
        has_json_string_key(text, "syndrome_history_key", "10|10") ||
            push!(errors, "history-drop witness missing syndrome_history_key: 10|10")
        has_json_string_key(text, "observed_history", "10|10") ||
            push!(errors, "history-drop witness missing observed_history: 10|10")
        has_json_string_key(text, "decoder_history_used", "00|10") ||
            push!(errors, "history-drop witness missing decoder_history_used: 00|10")
        has_json_string_key(text, "decoder_output", "r2_q1") ||
            push!(errors, "history-drop witness missing decoder_output: r2_q1")
        has_json_string_key(text, "expected_decoder_output", "r1_q1") ||
            push!(errors, "history-drop witness missing expected_decoder_output: r1_q1")
    end

    if subject_mentions(text, path, "inconsistent_control_bug")
        has_json_bool_key(text, "inconsistent_control", true) ||
            push!(errors, "inconsistent-control witness missing inconsistent_control: true")
        has_json_key(text, "relational_counterexample") ||
            push!(errors, "inconsistent-control witness missing relational_counterexample")
        has_json_string_key(text, "control_state", "latest_syndrome=10;decoder_target=q1") ||
            push!(errors, "inconsistent-control witness missing relational control_state")
        has_json_string_key(text, "strategy", "relational_oracle_noop") ||
            push!(errors, "inconsistent-control witness missing relational minimization strategy")
    end

    return errors
end

function print_result(io::IO, path::AbstractString, errors::Vector{String})
    if isempty(errors)
        println(io, "OK   ", path)
    else
        println(io, "FAIL ", path)
        for err in errors
            println(io, "  - ", err)
        end
    end
end

function main(args::Vector{String}=ARGS)
    if isempty(args) || any(arg -> arg == "--help" || arg == "-h", args)
        usage()
        return isempty(args) ? 1 : 0
    end

    total = 0
    failed = 0
    for path in args
        total += 1
        errors = validation_errors(path)
        isempty(errors) || (failed += 1)
        print_result(stdout, path, errors)
    end

    passed = total - failed
    println(stdout, "summary: ", passed, " OK, ", failed, " FAIL, ", total, " total")
    return failed == 0 ? 0 : 1
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    try
        exit(main(ARGS))
    catch err
        println(stderr, "error: ", sprint(showerror, err))
        println(stderr)
        usage(stderr)
        exit(1)
    end
end
