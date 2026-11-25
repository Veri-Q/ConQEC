if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "weight-two correctable-fault subjects" begin
    @test_throws ErrorException WeightTwoSubject(4)
    @test_throws ErrorException WeightTwoSubject(25, :unknown)
    @test_throws ErrorException WeightTwoSubject(25, :decoder_pair_bug; target_pair=(19, 7))

    subject = WeightTwoSubject(25, :decoder_pair_bug; target_pair=(7, 19))
    @test subject_name(subject) == "weight2_repetition_n25_decoder_pair_bug_q7_q19"
    @test length(subject_fault_vars(subject)) == 25
    metadata = subject_metadata(subject)
    @test metadata["benchmark_family"] == "WeightTwoFaults"
    @test metadata["benchmark_family_alias"] == "WeightTwoCorrectableFaults"
    @test metadata["max_fault_weight"] == 2
    @test metadata["admissible_fault_assignments"] == 25 + div(25 * 24, 2)
    @test metadata["single_fault_baseline"] == "misses pair-only trigger"

    single = zero_assignment(subject_fault_vars(subject))
    single[:x7] = true
    single_trace = run_subject(subject, single)
    @test single_trace.logical_verdicts["oracle_verdict"]
    @test single_trace.decoder_decisions["actual"] == "q7"

    pair = zero_assignment(subject_fault_vars(subject))
    pair[:x7] = true
    pair[:x19] = true
    pair_trace = run_subject(subject, pair)
    @test !pair_trace.logical_verdicts["oracle_verdict"]
    @test pair_trace.decoder_decisions["expected"] == "pair:q7_q19"
    @test pair_trace.decoder_decisions["actual"] == "pair:q7_q20"
    @test earliest_divergence(pair_trace) == "decoder"
    @test fault_weight(pair_trace) == 2

    result = run_concolic_subject(
        subject;
        max_tests=6,
        max_fault_weight=2,
        witness_dir=mktempdir(),
    )
    @test result.bug_found
    @test result.generated_tests == 2
    @test result.witness["earliest_divergence_stage"] == "decoder"
    @test result.witness["minimization"]["minimized_fault_weight"] == 2

    recovery_subject = WeightTwoSubject(25, :recovery_pair_bug; target_pair=(6, 20))
    recovery_pair = zero_assignment(subject_fault_vars(recovery_subject))
    recovery_pair[:x6] = true
    recovery_pair[:x20] = true
    recovery_trace = run_subject(recovery_subject, recovery_pair)
    @test recovery_trace.decoder_decisions["actual"] == "pair:q6_q20"
    @test recovery_trace.logical_verdicts["recovery_mismatch"]
    @test earliest_divergence(recovery_trace) == "recovery"

    unhandled_subject = WeightTwoSubject(50, :unhandled_pair_bug; target_pair=(11, 43))
    unhandled_pair = zero_assignment(subject_fault_vars(unhandled_subject))
    unhandled_pair[:x11] = true
    unhandled_pair[:x43] = true
    unhandled_trace = run_subject(unhandled_subject, unhandled_pair)
    @test unhandled_trace.decoder_decisions["actual"] == "missing"
    @test unhandled_trace.logical_verdicts["missing_recovery_branch"]
    @test earliest_divergence(unhandled_trace) == "decoder"
end
