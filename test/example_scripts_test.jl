using Test

const EXAMPLE_PROJECT_ROOT = normpath(joinpath(@__DIR__, ".."))

function run_example_script(script_name::AbstractString, witness_dir::AbstractString)
    script = joinpath(EXAMPLE_PROJECT_ROOT, "example", script_name)
    return read(
        setenv(
            `$(Base.julia_cmd()) --project=$EXAMPLE_PROJECT_ROOT $script`,
            "CONQEC_WITNESS_DIR" => witness_dir,
        ),
        String,
    )
end

@testset "standalone example scripts" begin
    cases = [
        (
            script="conqec_bitflip.jl",
            subject="bitflip_buggy_decoder_table",
            witness="bitflip_buggy_decoder_table_witness_2.json",
            diagnostic="decoder actual/expected: q2 / q1",
        ),
        (
            script="conqec_phaseflip.jl",
            subject="phaseflip_buggy_decoder_table",
            witness="phaseflip_buggy_decoder_table_witness_2.json",
            diagnostic="recovery: Z@q2",
        ),
        (
            script="conqec_steane.jl",
            subject="steane_css_buggy_decoder_table",
            witness="steane_css_buggy_decoder_table_witness_2.json",
            diagnostic="decoder actual/expected: q2 / q1",
        ),
        (
            script="conqec_surface.jl",
            subject="surface_d3_x_memory_buggy_decoder_table",
            witness="surface_d3_x_memory_buggy_decoder_table_witness_2.json",
            diagnostic="syndrome: X=1000;Z=0000",
        ),
        (
            script="conqec_repetition.jl",
            subject="repetition_d5_decoder_neighbor_bug",
            witness="repetition_d5_decoder_neighbor_bug_witness_2.json",
            diagnostic="decoder actual/expected: q2 / q1",
        ),
        (
            script="conqec_round_repetition.jl",
            subject="round_repetition_d3_r2_history_drop_bug",
            witness="round_repetition_d3_r2_history_drop_bug_witness_2.json",
            diagnostic="decoder history used: 00|10",
        ),
    ]

    for case in cases
        witness_dir = mktempdir()
        output = run_example_script(case.script, witness_dir)
        @test occursin("subject: $(case.subject)", output)
        @test occursin("bug found: true", output)
        @test occursin("witness file: $(joinpath(witness_dir, case.witness))", output)
        @test occursin(case.diagnostic, output)
        @test isfile(joinpath(witness_dir, case.witness))
    end
end
