const CONQEC_BACKEND_KEYS = Set([
    "backend",
    "backend-preset",
    "solver-path",
    "solver-timeout-ms",
    "max-weight",
    "output-dir",
    "solver-chain",
    "solver-cache",
    "solver-chain-normalization",
    "construct-cache",
    "solver-chain-slicing",
    "dependency-slicing",
    "solver-chain-cache",
    "solver-chain-cache-mode",
    "solver-chain-presolve",
    "qec-presolver",
    "solver-chain-incremental",
    "persistent-z3",
    "validate-model",
    "solver-chain-log",
    "query-profile",
    "lazy-branch-priority",
    "first-new-successor",
    "metadata-guided-seeds",
])

const CONQEC_BACKEND_PRESETS = Dict{String,Dict{String,String}}(
    "paper_default" => Dict(
        "backend" => "z3",
        "solver-chain" => "off",
        "solver-chain-normalization" => "off",
        "solver-chain-slicing" => "off",
        "solver-chain-cache" => "off",
        "solver-chain-cache-mode" => "exact",
        "solver-chain-presolve" => "off",
        "solver-chain-incremental" => "off",
    ),
    "optimized_safe" => Dict(
        "backend" => "z3",
        "solver-chain" => "transparent",
        "solver-chain-normalization" => "on",
        "solver-chain-slicing" => "off",
        "solver-chain-cache" => "on",
        "solver-cache" => "on",
        "solver-chain-cache-mode" => "exact",
        "solver-chain-presolve" => "on",
        "qec-presolver" => "on",
        "construct-cache" => "on",
        "solver-chain-incremental" => "on",
        "persistent-z3" => "on",
        "validate-model" => "on",
        "lazy-branch-priority" => "on",
        "first-new-successor" => "on",
        "metadata-guided-seeds" => "off",
    ),
    "optimized_full" => Dict(
        "backend" => "z3",
        "solver-chain" => "transparent",
        "solver-chain-normalization" => "on",
        "solver-chain-slicing" => "on",
        "solver-chain-cache" => "on",
        "solver-cache" => "on",
        "solver-chain-cache-mode" => "validated",
        "solver-chain-presolve" => "on",
        "qec-presolver" => "on",
        "construct-cache" => "on",
        "solver-chain-incremental" => "on",
        "persistent-z3" => "on",
        "validate-model" => "on",
        "lazy-branch-priority" => "on",
        "first-new-successor" => "on",
        "metadata-guided-seeds" => "off",
    ),
    "metadata_guided_rescue" => Dict(
        "backend" => "z3",
        "solver-chain" => "transparent",
        "solver-chain-normalization" => "on",
        "solver-chain-slicing" => "off",
        "solver-chain-cache" => "on",
        "solver-cache" => "on",
        "solver-chain-cache-mode" => "exact",
        "solver-chain-presolve" => "on",
        "qec-presolver" => "on",
        "construct-cache" => "on",
        "solver-chain-incremental" => "on",
        "persistent-z3" => "on",
        "validate-model" => "on",
        "lazy-branch-priority" => "on",
        "first-new-successor" => "on",
        "metadata-guided-seeds" => "on",
    ),
)

function conqec_backend_option_keys()
    return CONQEC_BACKEND_KEYS
end

function conqec_is_backend_option_key(key::AbstractString)
    return key in CONQEC_BACKEND_KEYS
end

function conqec_merge_backend_defaults!(opts::Dict{String,String};
    backend::AbstractString="z3",
    solver_timeout_ms::Integer=30000,
    max_weight::Integer=1)

    get!(opts, "backend", String(backend))
    get!(opts, "solver-timeout-ms", string(solver_timeout_ms))
    get!(opts, "max-weight", string(max_weight))
    return opts
end

function conqec_parse_backend_positive_int(opts::AbstractDict, key::AbstractString)
    value = String(opts[key])
    parsed = tryparse(Int, value)
    parsed === nothing && error("--$(key) must be an integer, got $(value)")
    parsed > 0 || error("--$(key) must be positive, got $(value)")
    return parsed
end

function conqec_set_alias_if_missing!(opts::AbstractDict,
    key::AbstractString,
    alias::AbstractString)

    haskey(opts, alias) && !haskey(opts, key) && (opts[key] = opts[alias])
    return opts
end

function conqec_normalize_solver_chain_aliases!(opts::AbstractDict)
    conqec_set_alias_if_missing!(opts, "solver-chain-cache", "solver-cache")
    conqec_set_alias_if_missing!(opts, "solver-chain-slicing", "dependency-slicing")
    conqec_set_alias_if_missing!(opts, "solver-chain-presolve", "qec-presolver")
    conqec_set_alias_if_missing!(opts, "solver-chain-incremental", "persistent-z3")
    return opts
end

function conqec_parse_solver_chain_mode(opts::AbstractDict; default::AbstractString="off")
    haskey(opts, "solver-chain") || return Symbol(lowercase(strip(default)))
    mode = lowercase(strip(opts["solver-chain"]))
    mode == "on" && return :transparent
    mode in ("off", "transparent", "generational") ||
        error("--solver-chain must be off|transparent|generational|on, got $(opts["solver-chain"])")
    return Symbol(mode)
end

function conqec_apply_backend_preset!(opts::Dict{String,String})
    haskey(opts, "backend-preset") || return opts
    preset = lowercase(strip(String(opts["backend-preset"])))
    haskey(CONQEC_BACKEND_PRESETS, preset) ||
        error("--backend-preset must be one of: paper_default, optimized_safe, optimized_full, metadata_guided_rescue")
    opts["backend-preset"] = preset
    for (key, value) in CONQEC_BACKEND_PRESETS[preset]
        get!(opts, key, value)
    end
    return opts
end

function conqec_validate_backend_options!(opts::Dict{String,String})
    conqec_normalize_solver_chain_aliases!(opts)
    conqec_apply_backend_preset!(opts)
    backend = lowercase(strip(get(opts, "backend", "z3")))
    backend in ("enumerator", "z3", "bitwuzla", "smtlib") ||
        error("--backend must be one of: enumerator, z3, bitwuzla, smtlib")
    conqec_parse_backend_positive_int(opts, "solver-timeout-ms")
    conqec_parse_backend_positive_int(opts, "max-weight")
    haskey(opts, "solver-chain") &&
        conqec_parse_solver_chain_mode(opts; default="off")
    for key in (
        "solver-cache",
        "solver-chain-normalization",
        "construct-cache",
        "solver-chain-slicing",
        "dependency-slicing",
        "solver-chain-cache",
        "solver-chain-presolve",
        "qec-presolver",
        "solver-chain-incremental",
        "persistent-z3",
        "validate-model",
        "lazy-branch-priority",
        "first-new-successor",
        "metadata-guided-seeds",
    )
        haskey(opts, key) || continue
        lowercase(strip(opts[key])) in ("on", "off", "true", "false", "1", "0") ||
            error("--$(key) must be on or off, got $(opts[key])")
    end
    if haskey(opts, "solver-chain-cache-mode")
        lowercase(strip(opts["solver-chain-cache-mode"])) in ("exact", "validated") ||
            error("--solver-chain-cache-mode must be exact or validated, got $(opts["solver-chain-cache-mode"])")
    end
    return opts
end

function conqec_parse_on_off(opts::AbstractDict, key::AbstractString; default::Bool=false)
    haskey(opts, key) || return Bool(default)
    value = lowercase(strip(String(opts[key])))
    value in ("on", "true", "1") && return true
    value in ("off", "false", "0") && return false
    error("--$(key) must be on or off, got $(opts[key])")
end

function conqec_backend_max_weight(opts::AbstractDict; default::Integer=1)
    haskey(opts, "max-weight") || return Int(default)
    return conqec_parse_backend_positive_int(opts, "max-weight")
end

function conqec_backend_preset_name(opts::AbstractDict)
    haskey(opts, "backend-preset") && return String(opts["backend-preset"])
    backend = lowercase(strip(String(get(opts, "backend", "z3"))))
    conqec_normalize_solver_chain_aliases!(opts)
    chain = conqec_parse_solver_chain_mode(opts; default="off") != :off
    backend == "z3" && !chain && return "paper_default"
    return "custom"
end

function conqec_enabled_optimization_layers(opts::AbstractDict)
    layers = String[]
    conqec_normalize_solver_chain_aliases!(opts)
    chain_mode = conqec_parse_solver_chain_mode(opts; default="off")
    if chain_mode == :off
        push!(layers, "solver_chain=off")
        return layers
    end
    push!(layers, "solver_chain=on")
    push!(layers, "solver_chain_mode=$(chain_mode)")
    if conqec_parse_on_off(opts, "solver-chain-normalization"; default=true)
        push!(layers, "normalization_hash=on")
        push!(layers, "expression_simplification=on")
    end
    if conqec_parse_on_off(opts, "construct-cache"; default=true)
        push!(layers, "construct_cache=on")
    else
        push!(layers, "construct_cache=off")
    end
    conqec_parse_on_off(opts, "solver-chain-slicing"; default=true) &&
        push!(layers, "dependency_slicing=on")
    if conqec_parse_on_off(opts, "solver-chain-cache"; default=true)
        cache_mode = lowercase(strip(String(get(opts, "solver-chain-cache-mode", "validated"))))
        push!(layers, cache_mode == "exact" ? "solver_cache_exact=on" :
            "solver_cache_validated=on")
    end
    conqec_parse_on_off(opts, "solver-chain-presolve"; default=true) &&
        push!(layers, "xor_cardinality_presolve=on")
    conqec_parse_on_off(opts, "solver-chain-incremental"; default=true) &&
        push!(layers, "persistent_z3=on")
    validate_model = conqec_parse_on_off(opts, "validate-model"; default=true)
    push!(layers, "validate_model=" * (validate_model ? "on" : "off"))
    push!(layers, "full_query_validation=" * (validate_model ? "on" : "off"))
    if conqec_parse_on_off(opts, "lazy-branch-priority"; default=false)
        push!(layers, "lazy_branch_priority=on")
    end
    if conqec_parse_on_off(opts, "first-new-successor"; default=false)
        push!(layers, "first_new_successor=on")
    end
    if conqec_parse_on_off(opts, "metadata-guided-seeds"; default=false)
        push!(layers, "metadata_guided_seeds=on")
    end
    return layers
end

function conqec_lazy_branch_priority(opts::AbstractDict)
    return conqec_parse_on_off(opts, "lazy-branch-priority"; default=false)
end

function conqec_first_new_successor(opts::AbstractDict)
    return conqec_parse_on_off(opts, "first-new-successor"; default=false)
end

function conqec_metadata_guided_seeds(opts::AbstractDict)
    return conqec_parse_on_off(opts, "metadata-guided-seeds"; default=false)
end

conqec_enabled_optimization_layers_text(opts::AbstractDict) =
    join(conqec_enabled_optimization_layers(opts), ";")

function conqec_backend_startup_summary(opts::AbstractDict)
    return string(
        "backend_preset=", conqec_backend_preset_name(opts),
        " backend=", get(opts, "backend", "z3"),
        " layers=", conqec_enabled_optimization_layers_text(opts),
    )
end

function conqec_output_dir(opts::AbstractDict)
    return get(opts, "output-dir", nothing)
end

function conqec_query_dir(opts::AbstractDict)
    output_dir = conqec_output_dir(opts)
    output_dir === nothing && return nothing
    return joinpath(String(output_dir), "queries")
end

function conqec_witness_dir(opts::AbstractDict, default_dir::AbstractString)
    haskey(opts, "witness-dir") && return String(opts["witness-dir"])
    output_dir = conqec_output_dir(opts)
    output_dir === nothing && return String(default_dir)
    return joinpath(String(output_dir), "witnesses")
end

function conqec_solver_from_options(fault_vars::Vector{Symbol}, opts::AbstractDict;
    max_weight=conqec_backend_max_weight(opts))

    conqec_normalize_solver_chain_aliases!(opts)
    base_backend = constraint_backend_from_name(
        fault_vars;
        backend=get(opts, "backend", "z3"),
        solver_path=get(opts, "solver-path", nothing),
        solver_timeout_ms=conqec_parse_backend_positive_int(opts, "solver-timeout-ms"),
        max_weight=max_weight,
        keep_query_files=haskey(opts, "output-dir"),
        query_dir=conqec_query_dir(opts),
    )
    chain_mode = conqec_parse_solver_chain_mode(opts; default="off")
    chain_mode == :off && return base_backend
    return SolverChainBackend(
        base_backend;
        mode=chain_mode,
        normalization=conqec_parse_on_off(opts, "solver-chain-normalization"; default=true),
        slicing=conqec_parse_on_off(opts, "solver-chain-slicing"; default=true),
        cache=conqec_parse_on_off(opts, "solver-chain-cache"; default=true),
        cache_mode=Symbol(lowercase(strip(String(get(opts, "solver-chain-cache-mode", "validated"))))),
        presolve=conqec_parse_on_off(opts, "solver-chain-presolve"; default=true),
        incremental=conqec_parse_on_off(opts, "solver-chain-incremental"; default=true),
        validate_model=conqec_parse_on_off(opts, "validate-model"; default=true),
        construct_cache=conqec_parse_on_off(opts, "construct-cache"; default=true),
        solver_chain_log=haskey(opts, "solver-chain-log") ? String(opts["solver-chain-log"]) : nothing,
        query_profile=haskey(opts, "query-profile") ? String(opts["query-profile"]) : nothing
    )
end

function conqec_solver_for_subject(subject, opts::AbstractDict;
    max_weight=conqec_backend_max_weight(opts))

    return conqec_solver_from_options(subject_fault_vars(subject), opts; max_weight=max_weight)
end

function conqec_backend_usage()
    return """
  --backend enumerator|z3|bitwuzla|smtlib
                      Constraint backend for ConQEC branch queries. Default: z3.
  --backend-preset paper_default|optimized_safe|optimized_full|metadata_guided_rescue
                      Named backend mode. paper_default is command-line Z3 with solver-chain off;
                      optimized_safe enables validated solver-chain layers without metadata
                      seeds; optimized_full enables all implemented solver-chain layers;
                      metadata_guided_rescue is artifact-only diagnostic rescue.
  --solver-path PATH  External solver path. Default: z3 for --backend z3 and bitwuzla for --backend bitwuzla.
  --solver-timeout-ms N
                      Per-query solver timeout in milliseconds. Default: 30000.
  --max-weight N      Fault-capacity bound encoded in branch queries. Default: 1.
  --output-dir DIR    Directory for generated witnesses and retained SMT query files.
  --solver-chain off|transparent|generational|on
                      Enable the optimized solver chain. Default: off.
  --solver-cache on|off
                      Alias for --solver-chain-cache. Default: on.
  --solver-chain-normalization on|off
                      Canonicalize and hash branch queries when solver-chain is on. Default: on.
  --solver-chain-slicing on|off
                      Slice branch queries by Boolean dependency when solver-chain is on. Default: on.
  --solver-chain-cache on|off
                      Reuse solver results when solver-chain is on. Default: on.
  --solver-chain-cache-mode exact|validated
                      exact reuses only identical full queries; validated also enables
                      branch/model/UNSAT-subsumption cache hits. Default: validated.
  --solver-chain-presolve on|off
                      Try the QECC XOR/cardinality pre-solver before SMT. Default: on.
  --solver-chain-incremental on|off
                      Mark persistent/incremental-compatible execution metadata. Default: on.
  --dependency-slicing on|off
                      Alias for --solver-chain-slicing. Default: on.
  --qec-presolver on|off
                      Alias for --solver-chain-presolve. Default: on.
  --persistent-z3 on|off
                      Alias for --solver-chain-incremental. Default: on.
  --construct-cache on|off
                      Enable SMT-construction caching inside solver normalization. Default: on.
  --validate-model on|off
                      Re-validate optimized solver/presolve outputs against query before return. Default: on.
  --solver-chain-log PATH
                      Optional solver-chain lifecycle log target.
  --query-profile PATH
                      Optional query profile output target.
  --lazy-branch-priority on|off
                      In bugfinding mode, rank branches by cheap QECC stage/trace
                      order and stop after the first feasible successor. Default: off;
                      optimized presets enable it.
  --first-new-successor on|off
                      In bugfinding mode, scan branches in the selected order and
                      stop after the first feasible not-yet-seen successor is enqueued.
                      This shared search-system optimization preserves the chosen branch
                      ordering while avoiding unnecessary full-frontier SMT expansion.
                      Default: off; optimized presets enable it.
  --metadata-guided-seeds on|off
                      In bugfinding mode, seed runs from subject trigger/interesting
                      fault metadata when available. Default: off. This is for
                      artifact diagnostics/rescue only; main evidence should use
                      paper_default, optimized_safe, or optimized_full with this off.
"""
end
