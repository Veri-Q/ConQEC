if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "round repetition-code subject" begin
    @test_throws ErrorException RoundRepetitionSubject(4, 2)
    one_round = RoundRepetitionSubject(3, 1, :history_drop_bug)
    @test subject_fault_vars(one_round) == [:x_r1_q1, :x_r1_q2, :x_r1_q3]
    @test_throws ErrorException RoundRepetitionSubject(3, 2, :unknown)

    vars = round_repetition_fault_vars(3, 2)
    @test vars == [
        :x_r1_q1,
        :x_r1_q2,
        :x_r1_q3,
        :x_r2_q1,
        :x_r2_q2,
        :x_r2_q3,
    ]
    @test round_repetition_syndrome_names(3, 2) ==
        ["r1_s12", "r1_s23", "r2_s12", "r2_s23"]
    @test reference_round_repetition_decoder(3, 2, "00|00") == "none"
    @test reference_round_repetition_decoder(3, 2, "10|10") == "r1_q1"
    @test reference_round_repetition_decoder(3, 2, "00|10") == "r2_q1"
    @test reference_round_repetition_decoder(3, 2, "11|11") == "r1_q2"
    @test reference_round_repetition_decoder(3, 2, "00|01") == "r2_q3"

    clean = RoundRepetitionSubject(3, 2)
    @test subject_name(clean) == "round_repetition_d3_r2_clean"
    @test subject_fault_vars(clean) == vars
    metadata = subject_metadata(clean)
    @test metadata["rounds"] == 2
    @test metadata["fault_locations"][1]["variable"] == "x_r1_q1"
    @test metadata["fault_locations"][1]["round"] == 1
    @test metadata["fault_locations"][1]["qubit"] == 1

    zero = zero_assignment(vars)
    zero_trace = run_round_repetition_subject(clean, zero)
    @test zero_trace.decoder_decisions["observed_history"] == "00|00"
    @test zero_trace.decoder_decisions["decoder_history_used"] == "00|00"
    @test zero_trace.decoder_decisions["actual"] == "none"
    @test zero_trace.logical_verdicts["oracle_verdict"]
    @test haskey(zero_trace.syndrome_values, "r1_s12")
    @test haskey(zero_trace.syndrome_values, "r2_s23")
    @test zero_trace.metadata["rounds"] == 2
    @test zero_trace.metadata["syndrome_history_key"] == "00|00"
    @test length(zero_trace.metadata["syndrome_history"]) == 2

    single = zero_assignment(vars)
    single[:x_r1_q1] = true
    single_trace = run_round_repetition_subject(clean, single)
    @test single_trace.syndrome_values["r1_s12"]
    @test single_trace.syndrome_values["r2_s12"]
    @test !single_trace.syndrome_values["r1_s23"]
    @test single_trace.decoder_decisions["observed_history"] == "10|10"
    @test single_trace.decoder_decisions["actual"] == "r1_q1"
    @test single_trace.decoder_decisions["expected"] == "r1_q1"
    @test single_trace.recovery_actions[1]["target"] == "q1"
    @test single_trace.recovery_actions[1]["inferred_round"] == 1
    @test single_trace.logical_verdicts["oracle_verdict"]

    constraints = flipped_path_constraint(zero_trace, 1)
    solver = BruteForceBoolSolver(vars; max_weight=1)
    model = solve(solver, constraints; avoid=Set([assignment_key(vars, zero)]))
    @test model !== nothing
    @test model[:x_r1_q1]
    @test all(!model[var] for var in vars[2:end])

    clean_result = run_concolic_subject(
        clean;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test !clean_result.bug_found
    @test clean_result.generated_tests == 7
    @test length(clean_result.unique_syndromes) == 7
    @test clean_result.witness_path === nothing

    buggy = RoundRepetitionSubject(3, 2, :history_drop_bug)
    buggy_result = run_concolic_subject(
        buggy;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test buggy_result.bug_found
    @test buggy_result.generated_tests == 2
    @test buggy_result.witness_path !== nothing
    @test isfile(buggy_result.witness_path)
    witness = buggy_result.witness
    @test witness["earliest_divergence_stage"] == "repeated_round_control"
    @test witness["decoder_output"] == "r2_q1"
    @test witness["expected_decoder_output"] == "r1_q1"
    @test witness["metadata"]["rounds"] == 2
    @test witness["metadata"]["syndrome_history_key"] == "10|10"
    @test witness["metadata"]["decoder_diagnostics"]["observed_history"] == "10|10"
    @test witness["metadata"]["decoder_diagnostics"]["decoder_history_used"] == "00|10"
    @test witness["metadata"]["decoder_diagnostics"]["history_mismatch"]
    @test witness["metadata"]["history_drop_bug"]["dropped_round"] == 1
    @test witness["logical_verdicts"]["history_mismatch"]
    @test witness["logical_verdicts"]["decoder_mismatch"]
    @test witness["logical_verdicts"]["recovery_mismatch"]
    @test witness["recovery_actually_applied"][1]["target"] == "q1"
    @test witness["recovery_actually_applied"][1]["inferred_round"] == 2
    @test witness["expected_recovery"]["target"] == "q1"
    @test witness["expected_recovery"]["inferred_round"] == 1
    @test witness["minimization"]["round_minimization"]["strategy"] ==
        "bounded_prefix_round_search"
    @test witness["minimization"]["round_minimization"]["original_rounds"] == 2
    @test witness["minimization"]["round_minimization"]["minimized_rounds"] == 1
    @test witness["minimization"]["round_minimization"]["shortened"] == true
    @test witness["minimization"]["round_minimization"]["reproducer_subject"] ==
        "round_repetition_d3_r1_history_drop_bug"
end
