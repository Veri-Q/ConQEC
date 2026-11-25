if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "repeated-round history challenge subjects" begin
    @test_throws ErrorException HistoryChallengeSubject(4, 2)
    @test_throws ErrorException HistoryChallengeSubject(25, 1)
    @test_throws ErrorException HistoryChallengeSubject(25, 2, :unknown)

    subject = HistoryChallengeSubject(25, 2, :history_drop_bug;
        target_round=1, target_qubit=5)
    @test subject_name(subject) ==
        "history_challenge_n25_r2_history_drop_bug_r1_q5"
    @test length(subject_fault_vars(subject)) == 50
    metadata = subject_metadata(subject)
    @test metadata["benchmark_family"] == "RepeatedRoundHistory"
    @test metadata["rounds"] == 2
    @test metadata["history_states"] == 51
    @test metadata["admissible_fault_assignments"] == 50

    zero_trace = run_subject(subject, zero_assignment(subject_fault_vars(subject)))
    @test zero_trace.decoder_decisions["actual"] == "none"
    @test zero_trace.logical_verdicts["oracle_verdict"]
    @test zero_trace.metadata["syndrome_history_key"] ==
        repeat("0", 25) * "|" * repeat("0", 25)

    target = zero_assignment(subject_fault_vars(subject))
    target[:x_r1_q5] = true
    target_trace = run_subject(subject, target)
    @test !target_trace.logical_verdicts["oracle_verdict"]
    @test target_trace.decoder_decisions["actual"] == "r2_q5"
    @test target_trace.decoder_decisions["expected"] == "r1_q5"
    @test target_trace.logical_verdicts["decoder_mismatch"]
    @test earliest_divergence(target_trace) == "repeated_round_control"

    result = run_concolic_subject(
        subject;
        max_tests=6,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test result.bug_found
    @test result.generated_tests == 2
    @test result.witness["earliest_divergence_stage"] == "repeated_round_control"
    @test result.witness["decoder_output"] == "r2_q5"
    @test result.witness["expected_decoder_output"] == "r1_q5"

    stale = HistoryChallengeSubject(25, 3, :stale_history_reuse_bug;
        target_round=2, target_qubit=10)
    stale_model = zero_assignment(subject_fault_vars(stale))
    stale_model[:x_r2_q10] = true
    stale_trace = run_subject(stale, stale_model)
    @test stale_trace.decoder_decisions["actual"] == "r1_q10"
    @test stale_trace.decoder_decisions["expected"] == "r2_q10"

    relational = HistoryChallengeSubject(50, 4, :inconsistent_control_bug;
        target_round=3, target_qubit=37)
    relational_model = zero_assignment(subject_fault_vars(relational))
    relational_model[:x_r3_q37] = true
    relational_trace = run_subject(relational, relational_model)
    @test relational_trace.logical_verdicts["inconsistent_control"]
    @test !relational_trace.logical_verdicts["decoder_mismatch"]
    @test !relational_trace.logical_verdicts["recovery_mismatch"]

    missing_reset = HistoryChallengeSubject(100, 4, :missing_reset_bug;
        target_round=2, target_qubit=75)
    reset_model = zero_assignment(subject_fault_vars(missing_reset))
    reset_model[:x_r2_q75] = true
    reset_trace = run_subject(missing_reset, reset_model)
    @test reset_trace.decoder_decisions["actual"] == "uncorrectable"
    @test reset_trace.logical_verdicts["missing_recovery_branch"]
end
