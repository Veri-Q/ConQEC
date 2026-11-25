using Test

const SMOKE_PROJECT_ROOT = normpath(joinpath(@__DIR__, ".."))
const SMOKE_SCRIPT = joinpath(
    SMOKE_PROJECT_ROOT,
    "scripts",
    "run_conqec_smoke_tests.jl",
)

function run_smoke_script(args...; env=nothing)
    cmd = `$(Base.julia_cmd()) --project=$SMOKE_PROJECT_ROOT $SMOKE_SCRIPT $args`
    if env !== nothing
        merged_env = copy(ENV)
        for pair in env
            merged_env[string(pair.first)] = string(pair.second)
        end
        cmd = setenv(cmd, merged_env)
    end
    return read(cmd, String)
end

@testset "legacy smoke script CLI" begin
    help_output = run_smoke_script("--help")
    @test occursin("ConQEC legacy bit-flip smoke tests", help_output)
    @test occursin("--witness-dir DIR", help_output)
    @test occursin("Overrides CONQEC_WITNESS_DIR", help_output)

    witness_dir = mktempdir()
    output = run_smoke_script("--witness-dir", witness_dir)
    @test occursin("witness_dir: $(witness_dir)", output)
    @test occursin("subject: bitflip_clean", output)
    @test occursin("subject: bitflip_syndrome_wiring_bug", output)
    @test occursin("subject: bitflip_buggy_decoder_table", output)
    @test occursin("subject: bitflip_wrong_recovery_target", output)
    @test occursin("subject: bitflip_missing_recovery_branch", output)
    @test occursin("bug found: false", output)
    @test occursin("bug found: true", output)

    expected_witnesses = [
        "bitflip_syndrome_wiring_bug_witness_3.json",
        "bitflip_buggy_decoder_table_witness_2.json",
        "bitflip_wrong_recovery_target_witness_2.json",
        "bitflip_missing_recovery_branch_witness_2.json",
    ]
    for name in expected_witnesses
        path = joinpath(witness_dir, name)
        @test isfile(path)
        @test occursin(path, output)
    end

    env_witness_dir = mktempdir()
    cli_witness_dir = mktempdir()
    precedence_output = run_smoke_script(
        "--witness-dir",
        cli_witness_dir;
        env=("CONQEC_WITNESS_DIR" => env_witness_dir,),
    )
    @test occursin("witness_dir: $(cli_witness_dir)", precedence_output)
    @test all(name -> isfile(joinpath(cli_witness_dir, name)), expected_witnesses)
    @test isempty(filter(name -> endswith(name, ".json"), readdir(env_witness_dir)))
end
