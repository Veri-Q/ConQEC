using Test

if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

@testset "large repetition-code scalability subject" begin
    @test_throws ErrorException LargeRepetitionSubject(2, :clean)
    @test_throws ErrorException LargeRepetitionSubject(100, :unknown)

    clean = LargeRepetitionSubject(100, :clean)
    @test subject_name(clean) == "large_repetition_n100_clean"
    @test length(subject_fault_vars(clean)) == 100
    @test subject_metadata(clean)["scalability_profile"] == "large_100_to_1000_qubits"

    zero_trace = run_subject(clean, Dict{Symbol,Bool}())
    @test zero_trace.code_size == 100
    @test length(zero_trace.syndrome_values) == 99
    @test zero_trace.decoder_decisions["actual"] == "none"
    @test zero_trace.logical_verdicts["oracle_verdict"] == true
    @test length(zero_trace.branch_guards) == 101

    boundary_trace = run_subject(clean, Dict(:x1 => true))
    @test boundary_trace.decoder_decisions["actual"] == "q1"
    @test boundary_trace.decoder_decisions["expected"] == "q1"
    @test boundary_trace.logical_verdicts["oracle_verdict"] == true
    @test boundary_trace.metadata["large_scale_summary"]["observed_syndrome_weight"] == 1
    @test boundary_trace.metadata["symbolic_stabilizer"]["code"] ==
        "large_repetition_code"
    @test boundary_trace.metadata["symbolic_stabilizer"]["tracked_pauli"] == "X"
    @test boundary_trace.metadata["symbolic_stabilizer"]["generator_count"] == 99
    @test boundary_trace.metadata["symbolic_stabilizer"]["pre_recovery_residual_weight"] == 1
    @test boundary_trace.metadata["symbolic_stabilizer"]["post_recovery_residual_weight"] == 0
    @test boundary_trace.metadata["symbolic_stabilizer"]["logical_ok"] == true
    @test boundary_trace.metadata["symbolic_stabilizer"]["compact_large_repetition"] == true

    bug = LargeRepetitionSubject(100, :decoder_boundary_bug)
    bug_trace = run_subject(bug, Dict(:x1 => true))
    @test bug_trace.decoder_decisions["actual"] == "q2"
    @test bug_trace.decoder_decisions["expected"] == "q1"
    @test bug_trace.logical_verdicts["decoder_mismatch"] == true
    @test bug_trace.logical_verdicts["oracle_verdict"] == false
    @test earliest_divergence(bug_trace) == "decoder"

    recovery_bug = LargeRepetitionSubject(100, :wrong_recovery_target)
    recovery_trace = run_subject(recovery_bug, Dict(:x1 => true))
    @test recovery_trace.decoder_decisions["actual"] == "q1"
    @test recovery_trace.decoder_decisions["expected"] == "q1"
    @test recovery_trace.recovery_actions[1]["target"] == "q2"
    @test recovery_trace.metadata["expected_recovery"]["target"] == "q1"
    @test recovery_trace.logical_verdicts["recovery_mismatch"] == true
    @test earliest_divergence(recovery_trace) == "recovery"

    recovery_boundary_bug = LargeRepetitionSubject(100, :recovery_boundary_bug)
    @test subject_name(recovery_boundary_bug) ==
        "large_repetition_n100_recovery_boundary_bug"
    recovery_boundary_trace = run_subject(recovery_boundary_bug, Dict(:x1 => true))
    @test recovery_boundary_trace.decoder_decisions["actual"] == "q1"
    @test recovery_boundary_trace.recovery_actions[1]["target"] == "q2"
    @test earliest_divergence(recovery_boundary_trace) == "recovery"

    unhandled_bug = LargeRepetitionSubject(100, :unhandled_syndrome_bug)
    @test subject_name(unhandled_bug) ==
        "large_repetition_n100_unhandled_syndrome_bug"
    unhandled_trace = run_subject(unhandled_bug, Dict(:x1 => true))
    @test unhandled_trace.decoder_decisions["actual"] == "uncorrectable"
    @test unhandled_trace.decoder_decisions["expected"] == "q1"
    @test unhandled_trace.logical_verdicts["missing_recovery_branch"] == true
    @test earliest_divergence(unhandled_trace) == "decoder"

    large_trace = run_subject(LargeRepetitionSubject(1000, :decoder_boundary_bug), Dict(:x1 => true))
    @test large_trace.code_size == 1000
    @test length(large_trace.syndrome_values) == 999
    @test large_trace.decoder_decisions["actual"] == "q2"
    @test large_trace.decoder_decisions["expected"] == "q1"
    @test length(large_trace.branch_guards) == 1001
end
