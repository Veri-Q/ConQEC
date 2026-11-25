struct DemFaultMechanism
    id::Int
    var::Symbol
    probability::Float64
    detector_support::Vector{Int}
    logical_support::Vector{Int}
    source_line::Int
    source_text::String
end

struct DemParityModel
    source_path::String
    family::String
    qubits::Int
    distance::Int
    rounds::Int
    stim_num_qubits::Int
    stim_num_detectors::Int
    stim_num_observables::Int
    detector_count::Int
    observable_count::Int
    tick_count::Int
    faults::Vector{DemFaultMechanism}
    error_mechanisms_total::Int
    fault_cap::Int
    fault_cap_reached::Bool
    repeat_blocks::Int
    flatten_loops::Bool
    decompose_errors::Bool
    parse_mode::String
    source_format::String
    warnings::Vector{String}
end

const DEM_ERROR_RE = r"^error\(([^)]+)\)\s*(.*)$"i
const DEM_TARGET_RE = r"([DL])([0-9]+)"

function dem_stable_hash(text::AbstractString)
    value = UInt64(0xcbf29ce484222325)
    prime = UInt64(0x100000001b3)
    for byte in codeunits(String(text))
        value ⊻= UInt64(byte)
        value *= prime
    end
    return value
end

dem_stable_index(text::AbstractString, n::Integer) =
    n <= 0 ? error("cannot choose from an empty set") :
    Int(mod(dem_stable_hash(text), UInt64(n))) + 1

function dem_path_parameter(path::AbstractString, key::AbstractString; default=nothing)
    m = match(Regex("(?:^|[,/])" * key * "=([^,/]+)(?:,|/|\$)"), String(path))
    m === nothing && return default
    return m.captures[1]
end

function dem_path_int(path::AbstractString, key::AbstractString; default::Integer=0)
    value = dem_path_parameter(path, key; default=nothing)
    value === nothing && return Int(default)
    parsed = tryparse(Int, String(value))
    parsed === nothing && return Int(default)
    return parsed
end

function dem_family_from_path(path::AbstractString)
    parts = split(String(path), '/')
    length(parts) >= 2 && parts[1] == "testdata" && return String(parts[2])
    return "unknown"
end

function dem_toggle_support!(support::Vector{Int}, value::Integer)
    idx = findfirst(==(Int(value)), support)
    if idx === nothing
        push!(support, Int(value))
    else
        deleteat!(support, idx)
    end
    return support
end

function dem_parse_probability(text::AbstractString)
    parsed = tryparse(Float64, strip(String(text)))
    parsed === nothing && return 0.001
    return clamp(parsed, eps(Float64), 1.0 - eps(Float64))
end

function dem_parse_shift_amount(line::AbstractString)
    ints = collect(eachmatch(r"-?[0-9]+", String(line)))
    isempty(ints) && return 0
    parsed = tryparse(Int, ints[end].match)
    parsed === nothing && return 0
    return parsed
end

function parse_dem_text(text::AbstractString;
    source_path::AbstractString="inline.dem",
    family::AbstractString=dem_family_from_path(source_path),
    qubits::Integer=dem_path_int(source_path, "q"),
    distance::Integer=dem_path_int(source_path, "d"),
    rounds::Integer=dem_path_int(source_path, "r"),
    stim_num_qubits::Integer=0,
    stim_num_detectors::Integer=0,
    stim_num_observables::Integer=0,
    tick_count::Integer=0,
    max_faults::Integer=typemax(Int),
    flatten_loops::Bool=false,
    decompose_errors::Bool=false)

    faults = DemFaultMechanism[]
    warnings = String[]
    detector_shift = 0
    max_detector = -1
    max_logical = -1
    error_mechanisms_total = 0
    repeat_blocks = 0
    fault_cap_reached = false
    for (line_no, raw_line) in enumerate(split(String(text), '\n'))
        line = strip(replace(raw_line, r"#.*$" => ""))
        isempty(line) && continue
        lower = lowercase(line)
        if startswith(lower, "repeat ")
            repeat_blocks += 1
            continue
        end
        if startswith(lower, "shift_detectors")
            detector_shift += dem_parse_shift_amount(line)
            continue
        end
        if startswith(lower, "detector")
            for m in eachmatch(DEM_TARGET_RE, line)
                m.captures[1] == "D" || continue
                max_detector = max(max_detector, detector_shift + parse(Int, m.captures[2]))
            end
            continue
        end
        if startswith(lower, "logical_observable")
            for m in eachmatch(DEM_TARGET_RE, line)
                m.captures[1] == "L" || continue
                max_logical = max(max_logical, parse(Int, m.captures[2]))
            end
            continue
        end
        m = match(DEM_ERROR_RE, line)
        m === nothing && continue
        detectors = Int[]
        logicals = Int[]
        for target in eachmatch(DEM_TARGET_RE, m.captures[2])
            kind, idx_text = target.captures
            idx = parse(Int, idx_text)
            if kind == "D"
                shifted = detector_shift + idx
                dem_toggle_support!(detectors, shifted)
                max_detector = max(max_detector, shifted)
            elseif kind == "L"
                dem_toggle_support!(logicals, idx)
                max_logical = max(max_logical, idx)
            end
        end
        sort!(detectors)
        sort!(logicals)
        isempty(detectors) && isempty(logicals) && continue
        error_mechanisms_total += 1
        if length(faults) >= max_faults
            fault_cap_reached = true
            continue
        end
        id = length(faults) + 1
        push!(
            faults,
            DemFaultMechanism(
                id,
                Symbol("dem_f", id),
                dem_parse_probability(m.captures[1]),
                detectors,
                logicals,
                line_no,
                line,
            ),
        )
    end
    detector_count = max_detector + 1
    observable_count = max_logical + 1
    detector_count <= 0 && push!(warnings, "no_detector_targets")
    isempty(faults) && push!(warnings, "no_error_mechanisms")
    repeat_blocks > 0 && push!(warnings, "dem_repeat_block_not_expanded")
    fault_cap_reached && push!(warnings, "fault_cap_reached")
    return DemParityModel(
        String(source_path),
        String(family),
        Int(qubits),
        Int(distance),
        Int(rounds),
        Int(stim_num_qubits),
        Int(stim_num_detectors),
        Int(stim_num_observables),
        max(detector_count, 0),
        max(observable_count, 0),
        Int(tick_count),
        faults,
        Int(error_mechanisms_total),
        Int(max_faults),
        Bool(fault_cap_reached),
        Int(repeat_blocks),
        Bool(flatten_loops),
        Bool(decompose_errors),
        "stim_detector_error_model",
        "dem",
        warnings,
    )
end

function dem_text_and_metadata_from_stim_file(path::AbstractString;
    python::AbstractString="python3",
    pythonpath::AbstractString="",
    decompose_errors::Bool=false,
    flatten_loops::Bool=true)

    pycode = """
import pathlib
import sys
import stim
path = pathlib.Path(sys.argv[1])
circuit = stim.Circuit(path.read_text(encoding="utf-8"))
args = set(sys.argv[2:])
kwargs = {}
if "--decompose" in args:
    kwargs["decompose_errors"] = True
if "--flatten-loops" in args:
    kwargs["flatten_loops"] = True
dem = str(circuit.detector_error_model(**kwargs))
repeat_blocks = sum(1 for line in dem.splitlines() if line.lstrip().lower().startswith("repeat "))
meta = [
    ("stim_num_qubits", circuit.num_qubits),
    ("stim_num_detectors", circuit.num_detectors),
    ("stim_num_observables", circuit.num_observables),
    ("dem_flatten_loops", str("--flatten-loops" in args).lower()),
    ("dem_decompose_errors", str("--decompose" in args).lower()),
    ("dem_repeat_blocks", repeat_blocks),
]
sys.stdout.write("CONQEC_DEM_META\\t" + "\\t".join(f"{k}={v}" for k, v in meta))
sys.stdout.write("\\nCONQEC_DEM_TEXT\\n")
sys.stdout.write(dem)
"""
    args = String[python, "-c", pycode, String(path)]
    decompose_errors && push!(args, "--decompose")
    flatten_loops && push!(args, "--flatten-loops")
    cmd = Cmd(args)
    if !isempty(strip(String(pythonpath)))
        cmd = setenv(cmd, "PYTHONPATH" => String(pythonpath))
    end
    output = read(cmd, String)
    marker = "\nCONQEC_DEM_TEXT\n"
    parts = split(output, marker; limit=2)
    length(parts) == 2 || error("Stim DEM helper returned malformed output")
    meta_line = parts[1]
    startswith(meta_line, "CONQEC_DEM_META\t") ||
        error("Stim DEM helper returned malformed metadata")
    metadata = Dict{String,String}()
    for item in split(meta_line[length("CONQEC_DEM_META\t") + 1:end], '\t')
        key_value = split(item, '='; limit=2)
        length(key_value) == 2 && (metadata[key_value[1]] = key_value[2])
    end
    return parts[2], metadata
end

function dem_text_from_stim_file(path::AbstractString;
    python::AbstractString="python3",
    pythonpath::AbstractString="",
    decompose_errors::Bool=false,
    flatten_loops::Bool=true)

    dem_text, _ = dem_text_and_metadata_from_stim_file(
        path;
        python=python,
        pythonpath=pythonpath,
        decompose_errors=decompose_errors,
        flatten_loops=flatten_loops,
    )
    return dem_text
end

function parse_stim_file_as_dem(path::AbstractString;
    python::AbstractString="python3",
    pythonpath::AbstractString="",
    decompose_errors::Bool=false,
    flatten_loops::Bool=true,
    max_faults::Integer=typemax(Int),
    source_path::AbstractString=path,
    family::AbstractString=dem_family_from_path(source_path),
    qubits::Integer=dem_path_int(source_path, "q"),
    distance::Integer=dem_path_int(source_path, "d"),
    rounds::Integer=dem_path_int(source_path, "r"),
    tick_count::Integer=0)

    dem_text, stim_metadata = dem_text_and_metadata_from_stim_file(
        path;
        python=python,
        pythonpath=pythonpath,
        decompose_errors=decompose_errors,
        flatten_loops=flatten_loops,
    )
    return parse_dem_text(
        dem_text;
        source_path=source_path,
        family=family,
        qubits=qubits,
        distance=distance,
        rounds=rounds,
        stim_num_qubits=parse(Int, get(stim_metadata, "stim_num_qubits", "0")),
        stim_num_detectors=parse(Int, get(stim_metadata, "stim_num_detectors", "0")),
        stim_num_observables=parse(Int, get(stim_metadata, "stim_num_observables", "0")),
        tick_count=tick_count,
        max_faults=max_faults,
        flatten_loops=flatten_loops,
        decompose_errors=decompose_errors,
    )
end

dem_fault_vars(model::DemParityModel) = [fault.var for fault in model.faults]

function dem_fault_by_var(model::DemParityModel)
    return Dict(fault.var => fault for fault in model.faults)
end

function dem_model_summary(model::DemParityModel)
    supports = [length(fault.detector_support) for fault in model.faults]
    logical_supports = [length(fault.logical_support) for fault in model.faults]
    return Dict{String,Any}(
        "dem_source_path" => model.source_path,
        "tesseract_family" => model.family,
        "qubits" => model.qubits,
        "distance" => model.distance,
        "rounds" => model.rounds,
        "stim_num_qubits" => model.stim_num_qubits,
        "stim_num_detectors" => model.stim_num_detectors,
        "stim_num_observables" => model.stim_num_observables,
        "dem_detector_count" => model.detector_count,
        "dem_observable_count" => model.observable_count,
        "stim_tick_count" => model.tick_count,
        "dem_error_mechanisms" => length(model.faults),
        "dem_error_mechanisms_total" => model.error_mechanisms_total,
        "dem_fault_cap" => model.fault_cap == typemax(Int) ? "none" : model.fault_cap,
        "dem_fault_cap_reached" => model.fault_cap_reached,
        "dem_repeat_blocks" => model.repeat_blocks,
        "dem_flatten_loops" => model.flatten_loops,
        "dem_decompose_errors" => model.decompose_errors,
        "dem_detector_count_matches_stim" =>
            model.stim_num_detectors == 0 ? "n/a" : model.detector_count == model.stim_num_detectors,
        "dem_observable_count_matches_stim" =>
            model.stim_num_observables == 0 ? "n/a" : model.observable_count == model.stim_num_observables,
        "dem_detector_support_min" => isempty(supports) ? 0 : minimum(supports),
        "dem_detector_support_max" => isempty(supports) ? 0 : maximum(supports),
        "dem_logical_support_max" => isempty(logical_supports) ? 0 : maximum(logical_supports),
        "dem_parse_mode" => model.parse_mode,
        "dem_source_format" => model.source_format,
        "dem_parse_warnings" => isempty(model.warnings) ? "none" : join(model.warnings, "+"),
    )
end
