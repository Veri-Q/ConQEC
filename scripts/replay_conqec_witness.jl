include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
using .ConQEC

const BITFLIP_MODE_NAMES = supported_subject_modes(:bitflip)
const REPETITION_MODE_NAMES = supported_subject_modes(:repetition)
const PHASEFLIP_MODE_NAMES = supported_subject_modes(:phaseflip)
const STEANE_MODE_NAMES = supported_subject_modes(:steane)
const SURFACE_MODE_NAMES = supported_subject_modes(:surface)
const ROUND_REPETITION_MODE_NAMES = supported_subject_modes(:round_repetition)
const LARGE_REPETITION_MODE_NAMES = Dict(
    "clean" => :clean,
    "decoder_boundary_bug" => :decoder_boundary_bug,
    "wrong_recovery_target" => :wrong_recovery_target,
    "recovery_boundary_bug" => :recovery_boundary_bug,
    "unhandled_syndrome_bug" => :unhandled_syndrome_bug,
)

const BITFLIP_SUBJECT_MODES = Dict(
    "bitflip_clean" => :clean,
    "bitflip_syndrome_wiring_bug" => :syndrome_wiring_bug,
    "bitflip_measurement_misuse" => :measurement_misuse,
    "bitflip_buggy_decoder_table" => :buggy_decoder,
    "bitflip_priority_decoder_bug" => :priority_decoder_bug,
    "bitflip_wrong_recovery_target" => :wrong_recovery_target,
    "bitflip_missing_recovery_branch" => :missing_recovery_branch,
)

const PHASEFLIP_SUBJECT_MODES = Dict(
    "phaseflip_clean" => :clean,
    "phaseflip_buggy_decoder_table" => :buggy_decoder,
    "phaseflip_wrong_recovery_target" => :wrong_recovery_target,
)

const STEANE_SUBJECT_MODES = Dict(
    "steane_css_clean" => :clean,
    "steane_css_buggy_decoder_table" => :buggy_decoder,
    "steane_css_z_decoder_bug_table" => :z_decoder_bug,
)

const SURFACE_SUBJECT_MODES = Dict(
    "surface_d3_x_memory_clean" => :clean,
    "surface_d3_x_memory_buggy_decoder_table" => :buggy_decoder,
    "surface_d3_z_memory_buggy_decoder_table" => :z_decoder_bug,
)

function usage(io::IO=stdout)
    print(io, """
ConQEC witness replay/diagnostics

Usage:
  julia --project=. scripts/replay_conqec_witness.jl --list-subjects
  julia --project=. scripts/replay_conqec_witness.jl --mode MODE --x1 0|1 --x2 0|1 --x3 0|1
  julia --project=. scripts/replay_conqec_witness.jl --subject phaseflip --mode MODE --z1 0|1 --z2 0|1 --z3 0|1
  julia --project=. scripts/replay_conqec_witness.jl --subject steane --mode MODE --x1 0|1 ... --z1 0|1 ... --y1 0|1 ...
  julia --project=. scripts/replay_conqec_witness.jl --subject surface --mode MODE --x1 0|1 ... --z1 0|1 ... --y1 0|1 ...
  julia --project=. scripts/replay_conqec_witness.jl --subject repetition --distance 5 --mode MODE --x1 0|1 ... --x5 0|1
  julia --project=. scripts/replay_conqec_witness.jl --subject round-repetition --distance 3 --rounds 2 --mode MODE --x_r1_q1 0|1 ...
  julia --project=. scripts/replay_conqec_witness.jl --subject large-repetition --qubits N --mode MODE --x1 0|1 ...
  julia --project=. scripts/replay_conqec_witness.jl --witness PATH [--witness PATH ...]
  julia --project=. scripts/replay_conqec_witness.jl PATH [PATH ...]

Bit-flip modes:
  clean
  syndrome_wiring_bug
  measurement_misuse
  buggy_decoder
  priority_decoder_bug
  wrong_recovery_target
  missing_recovery_branch

Repetition modes:
  clean
  decoder_neighbor_bug
  wrong_recovery_target

Phase-flip modes:
  clean
  buggy_decoder
  wrong_recovery_target

Steane CSS modes:
  clean
  buggy_decoder
  z_decoder_bug

Surface-code kernel modes:
  clean
  buggy_decoder
  z_decoder_bug

Round-repetition modes:
  clean
  history_drop_bug
  inconsistent_control_bug

Large-repetition modes:
  clean
  decoder_boundary_bug
  wrong_recovery_target

Notes:
  This script has no JSON.jl dependency. With --witness it extracts only the
  subject_name and fault-pattern variables from ConQEC's generated witness schema,
  then deterministically replays the witness-producing scenario.
  Multiple --witness arguments or positional witness paths replay each witness in
  sequence, so matrix-generated witness directories can be checked in one command.
""")
end

function add_witness_path!(opts::Dict{String,String}, path::AbstractString)
    if haskey(opts, "witness")
        opts["witness"] = opts["witness"] * "\0" * String(path)
    else
        opts["witness"] = String(path)
    end
    return opts
end

function parse_args(args::Vector{String})
    opts = Dict{String,String}()
    idx = 1
    while idx <= length(args)
        arg = args[idx]
        if arg == "--help" || arg == "-h"
            opts["help"] = "true"
        elseif arg == "--list-subjects"
            opts["list-subjects"] = "true"
        elseif startswith(arg, "--")
            body = arg[3:end]
            if occursin("=", body)
                parts = split(body, "="; limit=2)
                if parts[1] == "witness"
                    add_witness_path!(opts, parts[2])
                else
                    opts[parts[1]] = parts[2]
                end
            else
                idx == length(args) && error("missing value for $(arg)")
                next_arg = args[idx + 1]
                startswith(next_arg, "--") && error("missing value for $(arg)")
                if body == "witness"
                    add_witness_path!(opts, next_arg)
                else
                    opts[body] = next_arg
                end
                idx += 1
            end
        else
            add_witness_path!(opts, arg)
        end
        idx += 1
    end
    return opts
end

function witness_paths(opts::Dict{String,String})
    haskey(opts, "witness") || return String[]
    return split(opts["witness"], '\0')
end

function print_modes(io::IO, family::AbstractString, modes::AbstractDict)
    println(io, family, ": ", join(sort!(collect(keys(modes))), ", "))
end

function print_supported_subjects(io::IO=stdout)
    println(io, "ConQEC replay subjects")
    print_modes(io, "bitflip", BITFLIP_MODE_NAMES)
    print_modes(io, "phaseflip", PHASEFLIP_MODE_NAMES)
    print_modes(io, "steane", STEANE_MODE_NAMES)
    print_modes(io, "surface", SURFACE_MODE_NAMES)
    print_modes(io, "repetition", REPETITION_MODE_NAMES)
    print_modes(io, "round-repetition", ROUND_REPETITION_MODE_NAMES)
    print_modes(io, "large-repetition", LARGE_REPETITION_MODE_NAMES)
    println(io)
    println(io, "Paper subject registry")
    for config in paper_subject_configs()
        println(io, subject_name(config.subject), " max_tests=", config.max_tests)
    end
end

function normalized_key(value::AbstractString)
    key = replace(lowercase(strip(String(value))), "-" => "_")
    startswith(key, ":") && (key = key[2:end])
    return key
end

function parse_subject_family(value::AbstractString)
    key = normalized_key(value)
    key in ("bitflip", "bit_flip", "three_qubit_bitflip") && return :bitflip
    key in ("phaseflip", "phase_flip", "three_qubit_phaseflip") && return :phaseflip
    key in ("steane", "steane_css", "steane_css_code") && return :steane
    key in ("surface", "surface_code", "surface_code_kernel") && return :surface
    key in ("repetition", "repetition_code") && return :repetition
    key in ("round_repetition", "roundrepetition", "round_repetition_code") &&
        return :round_repetition
    key in ("large_repetition", "largerepetition", "large_repetition_code") &&
        return :large_repetition
    error("unsupported subject: $(value)")
end

function parse_bitflip_mode(value::AbstractString)
    key = normalized_key(value)
    haskey(BITFLIP_MODE_NAMES, key) && return BITFLIP_MODE_NAMES[key]
    haskey(BITFLIP_SUBJECT_MODES, key) && return BITFLIP_SUBJECT_MODES[key]
    error("unsupported bit-flip mode or subject: $(value)")
end

function parse_repetition_mode(value::AbstractString)
    key = normalized_key(value)
    haskey(REPETITION_MODE_NAMES, key) && return REPETITION_MODE_NAMES[key]
    error("unsupported repetition mode: $(value)")
end

function parse_phaseflip_mode(value::AbstractString)
    key = normalized_key(value)
    haskey(PHASEFLIP_MODE_NAMES, key) && return PHASEFLIP_MODE_NAMES[key]
    haskey(PHASEFLIP_SUBJECT_MODES, key) && return PHASEFLIP_SUBJECT_MODES[key]
    error("unsupported phase-flip mode or subject: $(value)")
end

function parse_steane_mode(value::AbstractString)
    key = normalized_key(value)
    haskey(STEANE_MODE_NAMES, key) && return STEANE_MODE_NAMES[key]
    haskey(STEANE_SUBJECT_MODES, key) && return STEANE_SUBJECT_MODES[key]
    error("unsupported Steane CSS mode or subject: $(value)")
end

function parse_surface_mode(value::AbstractString)
    key = normalized_key(value)
    haskey(SURFACE_MODE_NAMES, key) && return SURFACE_MODE_NAMES[key]
    haskey(SURFACE_SUBJECT_MODES, key) && return SURFACE_SUBJECT_MODES[key]
    error("unsupported surface-code kernel mode or subject: $(value)")
end

function parse_round_repetition_mode(value::AbstractString)
    key = normalized_key(value)
    haskey(ROUND_REPETITION_MODE_NAMES, key) && return ROUND_REPETITION_MODE_NAMES[key]
    error("unsupported round-repetition mode: $(value)")
end

function parse_large_repetition_mode(value::AbstractString)
    key = normalized_key(value)
    haskey(LARGE_REPETITION_MODE_NAMES, key) && return LARGE_REPETITION_MODE_NAMES[key]
    error("unsupported large-repetition mode: $(value)")
end

function parse_bit(name::AbstractString, value::AbstractString)
    bit = lowercase(strip(String(value)))
    bit in ("1", "true", "t", "yes") && return true
    bit in ("0", "false", "f", "no") && return false
    error("$(name) must be 0/1 or true/false, got $(value)")
end

function parse_distance(value::AbstractString)
    distance = parse(Int, strip(String(value)))
    distance >= 3 || error("--distance must be at least 3")
    isodd(distance) || error("--distance must be odd")
    return distance
end

function parse_rounds(value::AbstractString)
    rounds = parse(Int, strip(String(value)))
    rounds >= 1 || error("--rounds must be at least 1")
    return rounds
end

function parse_qubits(value::AbstractString)
    qubits = parse(Int, strip(String(value)))
    qubits >= 3 || error("--qubits must be at least 3")
    return qubits
end

function explicit_fault_assignment(opts::Dict{String,String}, fault_vars::AbstractVector{Symbol})
    model = Dict{Symbol,Bool}()
    for var in fault_vars
        name = string(var)
        model[var] = haskey(opts, name) ? parse_bit(name, opts[name]) : false
    end
    return model
end

function parse_subject_name(subject_name::AbstractString)
    subject = String(subject_name)
    if haskey(BITFLIP_SUBJECT_MODES, subject)
        return BitFlipSubject(BITFLIP_SUBJECT_MODES[subject])
    end

    if haskey(PHASEFLIP_SUBJECT_MODES, subject)
        return PhaseFlipSubject(PHASEFLIP_SUBJECT_MODES[subject])
    end

    if haskey(STEANE_SUBJECT_MODES, subject)
        return SteaneSubject(STEANE_SUBJECT_MODES[subject])
    end

    if haskey(SURFACE_SUBJECT_MODES, subject)
        return SurfaceSubject(SURFACE_SUBJECT_MODES[subject])
    end

    repetition_match = match(r"^repetition_d([0-9]+)_(.+)$", subject)
    if repetition_match !== nothing
        distance = parse_distance(repetition_match.captures[1])
        mode = parse_repetition_mode(repetition_match.captures[2])
        return RepetitionSubject(distance, mode)
    end

    round_match = match(r"^round_repetition_d([0-9]+)_r([0-9]+)_(.+)$", subject)
    if round_match !== nothing
        distance = parse_distance(round_match.captures[1])
        rounds = parse_rounds(round_match.captures[2])
        mode = parse_round_repetition_mode(round_match.captures[3])
        return RoundRepetitionSubject(distance, rounds, mode)
    end

    large_match = match(r"^large_repetition_n([0-9]+)_(.+)$", subject)
    if large_match !== nothing
        qubits = parse_qubits(large_match.captures[1])
        mode = parse_large_repetition_mode(large_match.captures[2])
        return LargeRepetitionSubject(qubits, mode)
    end

    error("witness subject_name is not a known replay subject: $(subject_name)")
end

function witness_subject(text::AbstractString)
    m = match(r"\"subject_name\"\s*:\s*\"([^\"]+)\"", text)
    m === nothing && error("witness does not contain subject_name")
    return parse_subject_name(m.captures[1])
end

struct RelationalReplayContext
    prior_model::Dict{Symbol,Bool}
    prior_trace_index::Int
    current_trace_index::Int
end

function skip_json_whitespace(text::AbstractString, idx::Int)
    last = lastindex(text)
    while idx <= last && text[idx] in (' ', '\n', '\r', '\t')
        idx = nextind(text, idx)
    end
    return idx
end

function balanced_json_range(text::AbstractString, start_idx::Int)
    opener = text[start_idx]
    closer = opener == '{' ? '}' : opener == '[' ? ']' :
        error("expected JSON object or array")
    depth = 0
    in_string = false
    escaped = false
    idx = start_idx
    last = lastindex(text)
    while idx <= last
        c = text[idx]
        if in_string
            if escaped
                escaped = false
            elseif c == '\\'
                escaped = true
            elseif c == '"'
                in_string = false
            end
        else
            if c == '"'
                in_string = true
            elseif c == opener
                depth += 1
            elseif c == closer
                depth -= 1
                depth == 0 && return start_idx:idx
            end
        end
        idx = nextind(text, idx)
    end
    error("unterminated JSON value")
end

function json_key_value_text(text::AbstractString, key::AbstractString; start::Int=firstindex(text))
    key_range = findnext("\"$(key)\"", text, start)
    key_range === nothing && return nothing
    colon = findnext(':', text, last(key_range) + 1)
    colon === nothing && error("JSON key $(key) has no value")
    value_start = skip_json_whitespace(text, colon + 1)
    value_start > lastindex(text) && error("JSON key $(key) has empty value")
    first_char = text[value_start]
    if first_char == '{' || first_char == '['
        return text[balanced_json_range(text, value_start)]
    elseif first_char == '"'
        idx = nextind(text, value_start)
        escaped = false
        while idx <= lastindex(text)
            c = text[idx]
            if escaped
                escaped = false
            elseif c == '\\'
                escaped = true
            elseif c == '"'
                return text[value_start:idx]
            end
            idx = nextind(text, idx)
        end
        error("unterminated JSON string for $(key)")
    else
        idx = value_start
        while idx <= lastindex(text) && !(text[idx] in (',', '\n', '\r', '}', ']'))
            idx = nextind(text, idx)
        end
        return strip(text[value_start:prevind(text, idx)])
    end
end

function json_string_value(value_text::AbstractString)
    text = strip(String(value_text))
    text == "null" && return "null"
    startswith(text, "\"") && endswith(text, "\"") ||
        error("expected JSON string value, got $(text)")
    body = text[nextind(text, firstindex(text)):prevind(text, lastindex(text))]
    out = IOBuffer()
    escaped = false
    for c in body
        if escaped
            if c == '"'
                print(out, '"')
            elseif c == '\\'
                print(out, '\\')
            elseif c == '/'
                print(out, '/')
            elseif c == 'n'
                print(out, '\n')
            elseif c == 'r'
                print(out, '\r')
            elseif c == 't'
                print(out, '\t')
            else
                print(out, c)
            end
            escaped = false
        elseif c == '\\'
            escaped = true
        else
            print(out, c)
        end
    end
    escaped && print(out, '\\')
    return String(take!(out))
end

function required_json_string(text::AbstractString, key::AbstractString)
    value_text = json_key_value_text(text, key)
    value_text === nothing && error("witness does not contain $(key)")
    return json_string_value(value_text)
end

function json_object_string_field(object_text::AbstractString, key::AbstractString)
    value_text = json_key_value_text(object_text, key)
    value_text === nothing && error("witness recovery object does not contain $(key)")
    return json_string_value(value_text)
end

function json_object_int_or_null(object_text::AbstractString, key::AbstractString)
    value_text = json_key_value_text(object_text, key)
    value_text === nothing && return nothing
    text = strip(String(value_text))
    text == "null" && return nothing
    return parse(Int, text)
end

function first_json_object_text(array_text::AbstractString, key::AbstractString)
    start_idx = findfirst('{', array_text)
    start_idx === nothing && error("witness $(key) does not contain a recovery action")
    return array_text[balanced_json_range(array_text, start_idx)]
end

function recovery_summary_from_object_text(object_text::AbstractString)
    text = strip(String(object_text))
    text == "null" && return "null"
    summary = string(
        json_object_string_field(text, "pauli"),
        "@",
        json_object_string_field(text, "target"),
    )
    round = json_object_int_or_null(text, "inferred_round")
    round === nothing && return summary
    return string(summary, "[r", round, "]")
end

function witness_recovery_summary(text::AbstractString, key::AbstractString)
    value_text = json_key_value_text(text, key)
    value_text === nothing && error("witness does not contain $(key)")
    if startswith(strip(String(value_text)), "[")
        value_text = first_json_object_text(value_text, key)
    end
    return recovery_summary_from_object_text(value_text)
end

function fault_assignment_from_pattern_text(pattern_text::AbstractString)
    model = Dict{Symbol,Bool}()
    for m in eachmatch(r"\{[^{}]*\}", pattern_text)
        object_text = m.match
        var_match = match(r"\"variable\"\s*:\s*\"([A-Za-z][A-Za-z0-9_]*)\"", object_text)
        active_match = match(r"\"active\"\s*:\s*(true|false)", object_text)
        if var_match !== nothing && active_match !== nothing
            model[Symbol(var_match.captures[1])] = active_match.captures[1] == "true"
        end
    end
    isempty(model) && error("witness fault_pattern does not contain replayable variables")
    return model
end

function witness_fault_assignment(text::AbstractString)
    pattern_text = json_key_value_text(text, "fault_pattern")
    pattern_text === nothing && error("witness does not contain fault_pattern")
    return fault_assignment_from_pattern_text(pattern_text)
end

function fault_assignment_from_object_text(assignments_text::AbstractString)
    model = Dict{Symbol,Bool}()
    for m in eachmatch(r"\"([A-Za-z][A-Za-z0-9_]*)\"\s*:\s*(true|false)", assignments_text)
        model[Symbol(m.captures[1])] = m.captures[2] == "true"
    end
    isempty(model) && error("relational snapshot fault_assignments contains no variables")
    return model
end

function json_int_field(object_text::AbstractString, key::AbstractString, default::Int)
    m = match(Regex("\"$(key)\"\\s*:\\s*([0-9]+)"), object_text)
    m === nothing && return default
    return parse(Int, m.captures[1])
end

function relational_replay_context(text::AbstractString)
    relational_text = json_key_value_text(text, "relational_counterexample")
    (relational_text === nothing || relational_text == "null") && return nothing
    prior_text = json_key_value_text(relational_text, "prior")
    prior_text === nothing && error("relational witness is missing prior snapshot")
    current_text = json_key_value_text(relational_text, "current")
    current_text === nothing && error("relational witness is missing current snapshot")
    assignments_text = json_key_value_text(prior_text, "fault_assignments")
    assignments_text === nothing &&
        error("relational prior snapshot is missing fault_assignments")
    return RelationalReplayContext(
        fault_assignment_from_object_text(assignments_text),
        json_int_field(prior_text, "trace_index", 1),
        json_int_field(current_text, "trace_index", 2),
    )
end

diagnostic_value(value) = value === nothing ? "null" : string(value)

function witness_diagnostics(text::AbstractString)
    return Dict{String,String}(
        "earliest_divergence_stage" => required_json_string(text, "earliest_divergence_stage"),
        "decoder_output" => required_json_string(text, "decoder_output"),
        "expected_decoder_output" => required_json_string(text, "expected_decoder_output"),
        "recovery_actually_applied" =>
            witness_recovery_summary(text, "recovery_actually_applied"),
        "expected_recovery" => witness_recovery_summary(text, "expected_recovery"),
    )
end

function replay_diagnostics(trace::ConcolicTrace)
    actual_recovery = trace.recovery_actions[1]
    expected_recovery = trace.metadata["expected_recovery"]
    return Dict{String,String}(
        "earliest_divergence_stage" => earliest_divergence(trace),
        "decoder_output" => diagnostic_value(get(trace.decoder_decisions, "actual", nothing)),
        "expected_decoder_output" =>
            diagnostic_value(get(trace.decoder_decisions, "expected", nothing)),
        "recovery_actually_applied" => recovery_summary(actual_recovery),
        "expected_recovery" => recovery_summary(expected_recovery),
    )
end

function validate_witness_diagnostics!(text::AbstractString, trace::ConcolicTrace)
    expected = witness_diagnostics(text)
    actual = replay_diagnostics(trace)
    mismatches = String[]
    for key in sort!(collect(keys(expected)))
        expected[key] == actual[key] && continue
        push!(mismatches, string(key, " expected ", expected[key], " replayed ", actual[key]))
    end
    isempty(mismatches) && return nothing
    error("witness diagnosis drift: " * join(mismatches, "; "))
end

function require_fault_assignment(model::Dict{Symbol,Bool}, fault_vars::AbstractVector{Symbol})
    for name in fault_vars
        haskey(model, name) || error("witness fault_pattern does not contain $(name)")
    end
    return model
end

function scenario_from_witness(path::AbstractString, opts::Dict{String,String})
    text = read(path, String)
    subject = witness_subject(text)
    if haskey(opts, "subject") || haskey(opts, "mode") || haskey(opts, "distance")
        subject = subject_from_args(opts; default_subject=subject)
    end
    model = require_fault_assignment(witness_fault_assignment(text), subject_fault_vars(subject))
    relational = relational_replay_context(text)
    return subject, model, "witness-producing scenario from $(path)", relational
end

function subject_from_args(opts::Dict{String,String}; default_subject=nothing)
    family = haskey(opts, "subject") ?
        parse_subject_family(opts["subject"]) :
        (default_subject isa PhaseFlipSubject ? :phaseflip :
         default_subject isa SteaneSubject ? :steane :
         default_subject isa SurfaceSubject ? :surface :
         default_subject isa RepetitionSubject ? :repetition :
         default_subject isa RoundRepetitionSubject ? :round_repetition :
         default_subject isa LargeRepetitionSubject ? :large_repetition :
         :bitflip)

    if family == :bitflip
        mode = haskey(opts, "mode") ? parse_bitflip_mode(opts["mode"]) :
            (default_subject isa BitFlipSubject ? default_subject.mode :
             error("missing --mode"))
        return BitFlipSubject(mode)
    elseif family == :phaseflip
        mode = haskey(opts, "mode") ? parse_phaseflip_mode(opts["mode"]) :
            (default_subject isa PhaseFlipSubject ? default_subject.mode :
             error("missing --mode"))
        return PhaseFlipSubject(mode)
    elseif family == :steane
        mode = haskey(opts, "mode") ? parse_steane_mode(opts["mode"]) :
            (default_subject isa SteaneSubject ? default_subject.mode :
             error("missing --mode"))
        return SteaneSubject(mode)
    elseif family == :surface
        mode = haskey(opts, "mode") ? parse_surface_mode(opts["mode"]) :
            (default_subject isa SurfaceSubject ? default_subject.mode :
             error("missing --mode"))
        return SurfaceSubject(mode)
    elseif family == :repetition
        distance = haskey(opts, "distance") ? parse_distance(opts["distance"]) :
            (default_subject isa RepetitionSubject ? default_subject.distance :
             error("missing --distance for repetition replay"))
        mode = haskey(opts, "mode") ? parse_repetition_mode(opts["mode"]) :
            (default_subject isa RepetitionSubject ? default_subject.mode :
             error("missing --mode"))
        return RepetitionSubject(distance, mode)
    elseif family == :round_repetition
        distance = haskey(opts, "distance") ? parse_distance(opts["distance"]) :
            (default_subject isa RoundRepetitionSubject ? default_subject.distance :
             error("missing --distance for round-repetition replay"))
        rounds = haskey(opts, "rounds") ? parse_rounds(opts["rounds"]) :
            (default_subject isa RoundRepetitionSubject ? default_subject.rounds :
             error("missing --rounds for round-repetition replay"))
        mode = haskey(opts, "mode") ? parse_round_repetition_mode(opts["mode"]) :
            (default_subject isa RoundRepetitionSubject ? default_subject.mode :
             error("missing --mode"))
        return RoundRepetitionSubject(distance, rounds, mode)
    elseif family == :large_repetition
        qubits = haskey(opts, "qubits") ? parse_qubits(opts["qubits"]) :
            (default_subject isa LargeRepetitionSubject ? default_subject.qubits :
             error("missing --qubits for large-repetition replay"))
        mode = haskey(opts, "mode") ? parse_large_repetition_mode(opts["mode"]) :
            (default_subject isa LargeRepetitionSubject ? default_subject.mode :
             error("missing --mode"))
        return LargeRepetitionSubject(qubits, mode)
    end

    error("unsupported subject family: $(family)")
end

function scenario_from_args(opts::Dict{String,String})
    subject = subject_from_args(opts)
    model = explicit_fault_assignment(opts, subject_fault_vars(subject))
    return subject, model, "explicit subject mode", nothing
end

function replay_trace(subject, model::Dict{Symbol,Bool}, relational)
    if relational isa RelationalReplayContext
        state = RelationalOracleState()
        prior_trace = run_subject(subject, relational.prior_model)
        apply_relational_oracles!(state, prior_trace, relational.prior_trace_index)
        trace = run_subject(subject, model)
        apply_relational_oracles!(state, trace, relational.current_trace_index)
        return trace
    end
    return run_subject(subject, model)
end

function active_fault_labels(trace)
    labels = String[]
    for item in fault_pattern(trace)
        get(item, "active", false) || continue
        push!(labels, String(item["label"]))
    end
    return isempty(labels) ? "none" : join(labels, ",")
end

function recovery_summary(action::AbstractDict)
    summary = string(action["pauli"], "@", action["target"])
    round = get(action, "inferred_round", nothing)
    round === nothing && return summary
    return string(summary, "[r", round, "]")
end

function syndrome_diagnostics(trace::ConcolicTrace)
    diagnostics = get(trace.metadata, "syndrome_diagnostics", Dict{String,Any}())
    observed = get(diagnostics, "observed", trace.decoder_decisions["syndrome"])
    expected = get(diagnostics, "expected", observed)
    return observed, expected
end

decoder_diagnostics(trace::ConcolicTrace) =
    get(trace.metadata, "decoder_diagnostics", Dict{String,Any}())

function print_diagnostics(trace::ConcolicTrace, source::AbstractString)
    actual_recovery = trace.recovery_actions[1]
    expected_recovery = trace.metadata["expected_recovery"]
    observed_syndrome, expected_syndrome = syndrome_diagnostics(trace)

    println("ConQEC witness replay/diagnostics")
    println("replay source: ", source)
    println("subject: ", trace.subject_name)
    println("fault pattern: ",
        assignment_key(trace.fault_vars, trace.fault_assignments),
        " (active: ", active_fault_labels(trace), ")")
    println("syndrome observed/expected: ",
        observed_syndrome, " / ", expected_syndrome, " (", syndrome_key(trace), ")")
    println("syndrome mismatch: ",
        get(trace.logical_verdicts, "syndrome_mismatch", false))
    if haskey(trace.metadata, "syndrome_wiring")
        wiring = trace.metadata["syndrome_wiring"]
        println("syndrome wiring: observed s12=",
            wiring["observed_s12_expr"], ", expected s12=", wiring["expected_s12_expr"])
    end
    if haskey(trace.metadata, "measurement_misuse")
        misuse = trace.metadata["measurement_misuse"]
        println("measurement misuse: observed s23=",
            misuse["observed_s23_expr"], ", expected s23=", misuse["expected_s23_expr"])
    end
    decoder_info = decoder_diagnostics(trace)
    if haskey(decoder_info, "observed_history")
        println("observed history: ", decoder_info["observed_history"])
        println("decoder history used: ", decoder_info["decoder_history_used"])
        println("history mismatch: ", decoder_info["history_mismatch"])
    end
    println("decoder actual/expected: ",
        trace.decoder_decisions["actual"], " / ", trace.decoder_decisions["expected"])
    println("recovery actual/expected: ",
        recovery_summary(actual_recovery), " / ", recovery_summary(expected_recovery))
    println("missing recovery branch: ", trace.logical_verdicts["missing_recovery_branch"])
    println("oracle verdict: ", trace.logical_verdicts["oracle_verdict"])
    println("earliest divergence: ", earliest_divergence(trace))
end

function main(args::Vector{String})
    opts = parse_args(args)
    if haskey(opts, "help")
        usage()
        return 0
    end
    if haskey(opts, "list-subjects")
        print_supported_subjects()
        return 0
    end

    paths = witness_paths(opts)
    if !isempty(paths)
        failed = 0
        for (idx, path) in enumerate(paths)
            idx == 1 || println()
            try
                text = read(path, String)
                subject, model, source, relational = scenario_from_witness(path, opts)
                trace = replay_trace(subject, model, relational)
                validate_witness_diagnostics!(text, trace)
                print_diagnostics(trace, source)
            catch err
                failed += 1
                println(stderr, "error replaying witness $(path): ", sprint(showerror, err))
            end
        end
        length(paths) > 1 && println("summary: ", length(paths) - failed, " replayed, ", failed, " failed")
        return failed == 0 ? 0 : 1
    end

    subject, model, source, relational = scenario_from_args(opts)
    trace = replay_trace(subject, model, relational)
    print_diagnostics(trace, source)
    return 0
end

try
    exit(main(ARGS))
catch err
    println(stderr, "error: ", sprint(showerror, err))
    println(stderr)
    usage(stderr)
    exit(1)
end
