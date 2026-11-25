include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
using .ConQEC

const EXPECTED = Dict(
    :clean => (
        bug_found=false,
        divergence="none",
        decoder_output=nothing,
        expected_decoder_output=nothing,
        recovery_target=nothing,
        expected_recovery_target=nothing,
        missing_recovery_branch=nothing,
        syndrome_mismatch=nothing,
        observed_syndrome=nothing,
        expected_syndrome=nothing,
    ),
    :syndrome_wiring_bug => (
        bug_found=true,
        divergence="syndrome",
        decoder_output="q3",
        expected_decoder_output="q2",
        recovery_target="q3",
        expected_recovery_target="q2",
        missing_recovery_branch=false,
        syndrome_mismatch=true,
        observed_syndrome="01",
        expected_syndrome="11",
    ),
    :buggy_decoder => (
        bug_found=true,
        divergence="decoder",
        decoder_output="q2",
        expected_decoder_output="q1",
        recovery_target="q2",
        expected_recovery_target="q1",
        missing_recovery_branch=false,
        syndrome_mismatch=false,
        observed_syndrome="10",
        expected_syndrome="10",
    ),
    :wrong_recovery_target => (
        bug_found=true,
        divergence="recovery",
        decoder_output="q1",
        expected_decoder_output="q1",
        recovery_target="q2",
        expected_recovery_target="q1",
        missing_recovery_branch=false,
        syndrome_mismatch=false,
        observed_syndrome="10",
        expected_syndrome="10",
    ),
    :missing_recovery_branch => (
        bug_found=true,
        divergence="recovery",
        decoder_output="q1",
        expected_decoder_output="q1",
        recovery_target="missing",
        expected_recovery_target="q1",
        missing_recovery_branch=true,
        syndrome_mismatch=false,
        observed_syndrome="10",
        expected_syndrome="10",
    ),
)

function smoke_witness_dir()
    return get(ENV, "CONQEC_WITNESS_DIR", joinpath(@__DIR__, "..", "artifacts", "witnesses"))
end

function usage(io::IO=stdout)
    print(io, """
ConQEC legacy bit-flip smoke tests

Usage:
  julia --project=. scripts/run_conqec_smoke_tests.jl [--backend z3] [--solver-path z3] [--witness-dir DIR]

Options:
  --backend enumerator|z3|bitwuzla|smtlib
                     Constraint backend. Default: z3.
  --solver-path PATH External solver path. Default: z3 for --backend z3.
  --solver-timeout-ms INT
                     External solver timeout. Default: 30000.
  --max-weight INT   Fault capacity. Default: 1.
  --seed INT         Accepted for CLI consistency; smoke tests are deterministic.
  --subject NAME     Restrict to one bit-flip smoke mode/subject.
  --bug-id ID        Alias for --subject when ID names a smoke bug.
  --budget INT       Concolic test budget. Default: 8.
  --output-dir DIR   Alias for --witness-dir.
  --witness-dir DIR  Directory for generated witness JSON files. Overrides CONQEC_WITNESS_DIR.
  -h, --help         Show this help text.

Without --witness-dir, the script uses CONQEC_WITNESS_DIR when set; otherwise
it preserves the legacy default artifacts/witnesses.
""")
end

function parse_smoke_args(args::Vector{String})
    opts = Dict{String,String}(
        "backend" => "z3",
        "solver-timeout-ms" => "30000",
        "max-weight" => "1",
        "seed" => "1",
        "budget" => "8",
    )
    idx = 1
    while idx <= length(args)
        arg = args[idx]
        if arg == "-h" || arg == "--help"
            opts["help"] = "true"
            idx += 1
        elseif arg in (
            "--witness-dir",
            "--output-dir",
            "--backend",
            "--solver-path",
            "--solver-timeout-ms",
            "--max-weight",
            "--seed",
            "--subject",
            "--bug-id",
            "--budget",
        )
            idx == length(args) && error("$(arg) requires a value")
            key = arg[3:end]
            opts[key] = args[idx + 1]
            idx += 2
        elseif startswith(arg, "--")
            key_value = split(arg[3:end], "="; limit=2)
            length(key_value) == 2 || error("unknown option $(arg)")
            key = key_value[1]
            key in (
                "witness-dir",
                "output-dir",
                "backend",
                "solver-path",
                "solver-timeout-ms",
                "max-weight",
                "seed",
                "subject",
                "bug-id",
                "budget",
            ) || error("unknown option --$(key)")
            opts[key] = key_value[2]
            isempty(opts[key]) && error("--$(key) requires a value")
            idx += 1
        else
            error("unknown option $(arg)")
        end
    end
    return opts
end

function resolve_smoke_witness_dir(opts::AbstractDict)
    return get(opts, "witness-dir", get(opts, "output-dir", smoke_witness_dir()))
end

function parse_positive_int(value::AbstractString, option::AbstractString)
    parsed = tryparse(Int, strip(String(value)))
    parsed === nothing && error("$(option) must be an integer, got $(value)")
    parsed > 0 || error("$(option) must be positive, got $(value)")
    return parsed
end

function smoke_mode_key(value::AbstractString)
    text = lowercase(strip(String(value)))
    text = replace(text, "-" => "_")
    text = replace(text, "bitflip_" => "")
    text = replace(text, "three_qubit_bitflip_" => "")
    return Symbol(text)
end

function smoke_modes_from_options(opts)
    requested = get(opts, "subject", get(opts, "bug-id", nothing))
    requested === nothing &&
        return [:clean, :syndrome_wiring_bug, :buggy_decoder,
            :wrong_recovery_target, :missing_recovery_branch]
    mode = smoke_mode_key(requested)
    haskey(EXPECTED, mode) || error("unknown smoke subject/bug-id: $(requested)")
    return [mode]
end

function smoke_solver(fault_vars::Vector{Symbol}, opts)
    return constraint_backend_from_name(
        fault_vars;
        backend=opts["backend"],
        solver_path=get(opts, "solver-path", nothing),
        solver_timeout_ms=parse_positive_int(opts["solver-timeout-ms"], "--solver-timeout-ms"),
        max_weight=parse_positive_int(opts["max-weight"], "--max-weight"),
    )
end

function run_subject_smoke(mode::Symbol, witness_dir::AbstractString, opts)
    subject = BitFlipSubject(mode)
    fault_vars = bitflip_fault_vars()
    solver = smoke_solver(fault_vars, opts)
    result = run_concolic(
        input -> run_bitflip_subject(subject, input),
        fault_vars;
        max_tests=parse_positive_int(opts["budget"], "--budget"),
        max_fault_weight=parse_positive_int(opts["max-weight"], "--max-weight"),
        solver=solver,
        witness_dir=witness_dir,
        stop_on_bug=true,
    )

    divergence = result.witness === nothing ?
        "none" :
        String(result.witness["earliest_divergence_stage"])

    println("subject: ", subject.name)
    println("  generated tests: ", result.generated_tests)
    println("  unique syndromes covered: ", length(result.unique_syndromes))
    println("  bug found: ", result.bug_found)
    println("  backend: ", solver_name(solver))
    println("  earliest divergence: ", divergence)
    println("  witness file: ", result.witness_path === nothing ? "none" : result.witness_path)

    expected = EXPECTED[mode]
    if result.bug_found != expected.bug_found || divergence != expected.divergence
        error(
            "Smoke test failed for $(subject.name): expected bug_found=$(expected.bug_found), " *
            "divergence=$(expected.divergence), got bug_found=$(result.bug_found), " *
            "divergence=$(divergence)",
        )
    end

    if result.witness !== nothing
        decoder_output = result.witness["decoder_output"]
        expected_decoder_output = result.witness["expected_decoder_output"]
        recovery_target = result.witness["recovery_actually_applied"][1]["target"]
        expected_recovery_target = result.witness["expected_recovery"]["target"]
        missing_recovery_branch =
            result.witness["logical_verdicts"]["missing_recovery_branch"]
        syndrome_mismatch =
            result.witness["logical_verdicts"]["syndrome_mismatch"]
        syndrome_diagnostics = result.witness["metadata"]["syndrome_diagnostics"]
        observed_syndrome = syndrome_diagnostics["observed"]
        expected_syndrome = syndrome_diagnostics["expected"]

        println("  syndrome observed/expected: ",
            observed_syndrome, " / ", expected_syndrome)
        println("  syndrome mismatch: ", syndrome_mismatch)

        if decoder_output != expected.decoder_output ||
            expected_decoder_output != expected.expected_decoder_output ||
            recovery_target != expected.recovery_target ||
            expected_recovery_target != expected.expected_recovery_target ||
            missing_recovery_branch != expected.missing_recovery_branch ||
            syndrome_mismatch != expected.syndrome_mismatch ||
            observed_syndrome != expected.observed_syndrome ||
            expected_syndrome != expected.expected_syndrome

            error(
                "Smoke witness failed for $(subject.name): got decoder=$(decoder_output), " *
                "expected_decoder=$(expected_decoder_output), recovery=$(recovery_target), " *
                "expected_recovery=$(expected_recovery_target), " *
                "missing_recovery_branch=$(missing_recovery_branch), " *
                "syndrome=$(observed_syndrome), expected_syndrome=$(expected_syndrome), " *
                "syndrome_mismatch=$(syndrome_mismatch)",
            )
        end
    end
    return result
end

function main(args=ARGS)
    opts = parse_smoke_args(String.(args))
    if haskey(opts, "help")
        usage()
        return 0
    end

    witness_dir = resolve_smoke_witness_dir(opts)
    println("ConQEC smoke tests")
    println("===================")
    println("witness_dir: ", witness_dir)
    println("backend: ", opts["backend"])
    println("solver_path: ", get(opts, "solver-path", opts["backend"] == "z3" ? "z3" : "default"))
    println()

    modes = smoke_modes_from_options(opts)
    for (idx, mode) in enumerate(modes)
        idx == 1 || println()
        run_subject_smoke(mode, witness_dir, opts)
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
