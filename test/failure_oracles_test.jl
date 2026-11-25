if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "failure oracle taxonomy" begin
    definitions = failure_oracle_definitions()
    @test [definition.id for definition in definitions] == [
        "O1_LOGICAL_MISMATCH",
        "O2_DECODER_MISMATCH",
        "O3_RESIDUAL_CORRECTABLE_ERROR",
        "O4_DEAD_RECOVERY_BRANCH",
        "O5_INCONSISTENT_CONTROL",
    ]
    @test failure_oracle_by_id("O4_DEAD_RECOVERY_BRANCH").name ==
        "Dead recovery branch"

    clean_trace = run_bitflip_subject(
        BitFlipSubject(:clean),
        Dict(:x1 => false, :x2 => false, :x3 => false),
    )
    @test triggered_failure_oracle_ids(clean_trace) == String[]

    decoder_trace = run_bitflip_subject(
        BitFlipSubject(:buggy_decoder),
        Dict(:x1 => true, :x2 => false, :x3 => false),
    )
    @test triggered_failure_oracle_ids(decoder_trace) == [
        "O1_LOGICAL_MISMATCH",
        "O2_DECODER_MISMATCH",
        "O3_RESIDUAL_CORRECTABLE_ERROR",
    ]
    @test [oracle["id"] for oracle in triggered_failure_oracles(
        decoder_trace.logical_verdicts;
        fault_weight_value=1,
        distance=3,
    )] == [
        "O1_LOGICAL_MISMATCH",
        "O2_DECODER_MISMATCH",
        "O3_RESIDUAL_CORRECTABLE_ERROR",
    ]

    wrong_recovery_trace = run_bitflip_subject(
        BitFlipSubject(:wrong_recovery_target),
        Dict(:x1 => true, :x2 => false, :x3 => false),
    )
    @test triggered_failure_oracle_ids(wrong_recovery_trace) == [
        "O1_LOGICAL_MISMATCH",
        "O3_RESIDUAL_CORRECTABLE_ERROR",
    ]

    missing_recovery_trace = run_bitflip_subject(
        BitFlipSubject(:missing_recovery_branch),
        Dict(:x1 => true, :x2 => false, :x3 => false),
    )
    @test triggered_failure_oracle_ids(missing_recovery_trace) == [
        "O1_LOGICAL_MISMATCH",
        "O3_RESIDUAL_CORRECTABLE_ERROR",
        "O4_DEAD_RECOVERY_BRANCH",
    ]

    syndrome_trace = run_bitflip_subject(
        BitFlipSubject(:syndrome_wiring_bug),
        Dict(:x1 => false, :x2 => true, :x3 => false),
    )
    @test get(syndrome_trace.logical_verdicts, "decoder_mismatch", false)
    @test triggered_failure_oracle_ids(syndrome_trace) == [
        "O1_LOGICAL_MISMATCH",
        "O3_RESIDUAL_CORRECTABLE_ERROR",
    ]

    history_trace = run_round_repetition_subject(
        RoundRepetitionSubject(3, 2, :history_drop_bug),
        Dict(:x_r1_q1 => true, :x_r1_q2 => false, :x_r1_q3 => false,
            :x_r2_q1 => false, :x_r2_q2 => false, :x_r2_q3 => false),
    )
    @test triggered_failure_oracle_ids(history_trace) == [
        "O2_DECODER_MISMATCH",
    ]

    relational_result = run_concolic_subject(
        RoundRepetitionSubject(3, 2, :inconsistent_control_bug);
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test relational_result.bug_found
    @test relational_result.generated_tests == 5
    @test triggered_failure_oracle_ids(relational_result.traces[end]) == [
        "O5_INCONSISTENT_CONTROL",
    ]
    @test stored_primary_failure_oracle_id(relational_result.witness) ==
        "O5_INCONSISTENT_CONTROL"
    @test relational_result.witness["earliest_divergence_stage"] == "repeated_round_control"
    @test relational_result.witness["logical_verdicts"]["inconsistent_control"]
    @test relational_result.witness["relational_counterexample"]["control_state"] ==
        "latest_syndrome=10;decoder_target=q1"
    @test relational_result.witness["relational_counterexample"]["prior"]["trace_index"] == 2
    @test relational_result.witness["relational_counterexample"]["current"]["trace_index"] == 5
    @test relational_result.witness["minimization"]["strategy"] == "relational_oracle_noop"

    decoder_witness = build_witness(decoder_trace)
    @test stored_triggered_failure_oracle_ids(decoder_witness) ==
        triggered_failure_oracle_ids(decoder_witness)
    @test [oracle["id"] for oracle in triggered_failure_oracles(decoder_witness)] ==
        stored_triggered_failure_oracle_ids(decoder_witness)
    @test stored_oracle_summary_text(decoder_witness) ==
        "O1_LOGICAL_MISMATCH+O2_DECODER_MISMATCH+O3_RESIDUAL_CORRECTABLE_ERROR"

    decoder_result = run_concolic(
        input -> run_bitflip_subject(BitFlipSubject(:buggy_decoder), input),
        bitflip_fault_vars();
        max_tests=8,
        max_fault_weight=1,
        max_witnesses=3,
        witness_dir=mktempdir(),
    )
    @test length(decoder_result.witnesses) == 3
    @test [stored_primary_failure_oracle_id(w) for w in decoder_result.witnesses] == [
        "O1_LOGICAL_MISMATCH",
        "O2_DECODER_MISMATCH",
        "O3_RESIDUAL_CORRECTABLE_ERROR",
    ]
    @test all(isfile, decoder_result.witness_paths)
    @test basename(decoder_result.witness_paths[1]) ==
        "bitflip_buggy_decoder_table_witness_2.json"
    @test occursin("O2_DECODER_MISMATCH", basename(decoder_result.witness_paths[2]))
end
