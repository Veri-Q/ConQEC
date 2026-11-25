using Test

const PROJECT_ROOT = normpath(joinpath(@__DIR__, ".."))
const AE_SUITE_SCRIPT = joinpath(PROJECT_ROOT, "scripts", "run_conqec_ae_suite.jl")

@testset "AE suite script" begin
    help_output = read(
        `$(Base.julia_cmd()) --project=$PROJECT_ROOT $AE_SUITE_SCRIPT --help`,
        String,
    )
    @test occursin("ConQEC AE suite summary", help_output)
    @test occursin("--subject NAME", help_output)
    @test occursin("--quick", help_output)
    @test occursin("--witness-dir DIR", help_output)
    @test occursin("--list-subjects", help_output)

    list_output = read(
        `$(Base.julia_cmd()) --project=$PROJECT_ROOT $AE_SUITE_SCRIPT --list-subjects`,
        String,
    )
    @test occursin("ConQEC paper subjects", list_output)
    @test occursin("bitflip_syndrome_wiring_bug max_tests=8", list_output)
    @test occursin("bitflip_measurement_misuse max_tests=8", list_output)
    @test occursin("bitflip_priority_decoder_bug max_tests=8", list_output)
    @test occursin("steane_css_buggy_decoder_table max_tests=8", list_output)
    @test occursin("surface_d3_x_memory_buggy_decoder_table max_tests=8", list_output)
    @test occursin("round_repetition_d3_r2_history_drop_bug max_tests=8", list_output)
    @test occursin("round_repetition_d3_r2_inconsistent_control_bug max_tests=8", list_output)

    witness_dir = mktempdir()
    output = read(
        `$(Base.julia_cmd()) --project=$PROJECT_ROOT $AE_SUITE_SCRIPT --quick --witness-dir $witness_dir`,
        String,
    )

    @test occursin("Example", output)
    @test occursin("Smoke subjects", output)
    @test occursin("Witness replay diagnostics", output)
    @test occursin("bitflip_clean", output)
    @test occursin("bitflip_buggy_decoder_table", output)
    @test occursin("bitflip_priority_decoder_bug", output)
    @test occursin("bitflip_syndrome_wiring_bug", output)
    @test occursin("bitflip_measurement_misuse", output)
    @test occursin("bitflip_wrong_recovery_target", output)
    @test occursin("bitflip_missing_recovery_branch", output)
    @test occursin("phaseflip_clean", output)
    @test occursin("phaseflip_buggy_decoder_table", output)
    @test occursin("steane_css_clean", output)
    @test occursin("steane_css_buggy_decoder_table", output)
    @test occursin("surface_d3_x_memory_clean", output)
    @test occursin("surface_d3_x_memory_buggy_decoder_table", output)
    @test occursin("repetition_d5_clean", output)
    @test occursin("repetition_d5_decoder_neighbor_bug", output)
    @test occursin("round_repetition_d3_r2_clean", output)
    @test occursin("round_repetition_d3_r2_history_drop_bug", output)
    @test occursin("round_repetition_d3_r2_inconsistent_control_bug", output)
    @test occursin("syndrome observed/expected: 01 / 11", output)
    @test occursin("syndrome observed/expected: 11 / 10", output)
    @test occursin("triggered oracles: O1_LOGICAL_MISMATCH+O3_RESIDUAL_CORRECTABLE_ERROR", output)
    @test occursin(
        "triggered oracles: O1_LOGICAL_MISMATCH+O2_DECODER_MISMATCH+O3_RESIDUAL_CORRECTABLE_ERROR",
        output,
    )
    @test occursin("triggered oracles: O5_INCONSISTENT_CONTROL", output)
    @test occursin("measurement misuse: observed s23=", output)
    @test occursin("syndrome_mismatch: true", output)
    @test occursin("decoder actual/expected: q2 / q1", output)
    @test occursin("subject: bitflip_priority_decoder_bug", output)
    @test occursin("recovery actual/expected: Z@q2 / Z@q1", output)
    @test occursin("observed history: 10|10", output)
    @test occursin("decoder history used: 00|10", output)
    @test occursin("history_mismatch: true", output)
    @test occursin("decoder actual/expected: r2_q1 / r1_q1", output)
    @test occursin(
        "recovery actual/expected: X@q1 (round 2) / X@q1 (round 1)",
        output,
    )
    @test occursin("recovery actual/expected: missing@missing / X@q1", output)
    @test occursin("missing_recovery_branch: true", output)
    @test occursin("minimized fault weight: 1 -> 1", output)

    @test isfile(joinpath(witness_dir, "bitflip_buggy_decoder_table_witness_2.json"))
    @test isfile(joinpath(witness_dir, "bitflip_priority_decoder_bug_witness_2.json"))
    @test any(
        path -> occursin("bitflip_syndrome_wiring_bug_witness_", basename(path)),
        readdir(witness_dir; join=true),
    )
    @test any(
        path -> occursin("bitflip_measurement_misuse_witness_", basename(path)),
        readdir(witness_dir; join=true),
    )
    @test isfile(joinpath(witness_dir, "bitflip_wrong_recovery_target_witness_2.json"))
    @test isfile(joinpath(witness_dir, "bitflip_missing_recovery_branch_witness_2.json"))
    @test isfile(joinpath(witness_dir, "phaseflip_buggy_decoder_table_witness_2.json"))
    @test isfile(joinpath(witness_dir, "steane_css_buggy_decoder_table_witness_2.json"))
    @test isfile(joinpath(witness_dir, "surface_d3_x_memory_buggy_decoder_table_witness_2.json"))
    @test isfile(joinpath(witness_dir, "repetition_d5_decoder_neighbor_bug_witness_2.json"))
    @test isfile(joinpath(
        witness_dir,
        "round_repetition_d3_r2_history_drop_bug_witness_2.json",
    ))
    @test isfile(joinpath(
        witness_dir,
        "round_repetition_d3_r2_inconsistent_control_bug_witness_5.json",
    ))

    single_witness_dir = mktempdir()
    single_output = read(
        `$(Base.julia_cmd()) --project=$PROJECT_ROOT $AE_SUITE_SCRIPT --subject bitflip_buggy_decoder --witness-dir $single_witness_dir`,
        String,
    )
    @test occursin("Smoke subjects", single_output)
    @test occursin("bitflip_buggy_decoder_table", single_output)
    @test occursin("subject: bitflip_buggy_decoder_table", single_output)
    @test !occursin("phaseflip_clean", single_output)
    @test isfile(joinpath(single_witness_dir, "bitflip_buggy_decoder_table_witness_2.json"))

    bad_stderr = tempname()
    read(
        pipeline(
            ignorestatus(`$(Base.julia_cmd()) --project=$PROJECT_ROOT $AE_SUITE_SCRIPT --subject not_a_subject`),
            stderr=bad_stderr,
        ),
        String,
    )
    bad_output = read(bad_stderr, String)
    @test occursin("error: unknown paper subject: not_a_subject", bad_output)
    @test occursin("Use --list-subjects to inspect the registry", bad_output)
end
