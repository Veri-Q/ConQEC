@testset "repetition-code subject" begin
    @test_throws ErrorException RepetitionSubject(4)
    @test_throws ErrorException RepetitionSubject(2)

    vars = repetition_fault_vars(5)
    @test vars == [:x1, :x2, :x3, :x4, :x5]
    @test reference_repetition_decoder(5, "0000") == "none"
    @test reference_repetition_decoder(5, "1000") == "q1"
    @test reference_repetition_decoder(5, "1100") == "q2"
    @test reference_repetition_decoder(5, "0110") == "q3"
    @test reference_repetition_decoder(5, "0011") == "q4"
    @test reference_repetition_decoder(5, "0001") == "q5"

    clean = RepetitionSubject(5)
    clean_result = run_concolic(
        input -> run_repetition_subject(clean, input),
        vars;
        max_tests=12,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test !clean_result.bug_found
    @test clean_result.generated_tests == 6
    @test length(clean_result.unique_syndromes) == 6
    @test clean_result.witness_path === nothing

    zero = zero_assignment(vars)
    zero_trace = run_repetition_subject(clean, zero)
    @test zero_trace.branch_guards[1].id == "decoder:syndrome_0000"
    @test zero_trace.branch_guards[1].taken

    constraints = flipped_path_constraint(zero_trace, 1)
    solver = BruteForceBoolSolver(vars; max_weight=1)
    model = solve(solver, constraints; avoid=Set([assignment_key(vars, zero)]))

    @test model !== nothing
    @test model[:x1]
    @test all(!model[var] for var in vars[2:end])

    buggy = RepetitionSubject(5, :decoder_neighbor_bug)
    buggy_result = run_concolic(
        input -> run_repetition_subject(buggy, input),
        vars;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test buggy_result.bug_found
    @test buggy_result.generated_tests == 2
    @test buggy_result.witness_path !== nothing
    @test isfile(buggy_result.witness_path)
    @test buggy_result.witness["earliest_divergence_stage"] == "decoder"
    @test buggy_result.witness["decoder_output"] == "q2"
    @test buggy_result.witness["expected_decoder_output"] == "q1"
    @test buggy_result.witness["expected_recovery"]["target"] == "q1"
    @test buggy_result.witness["recovery_actually_applied"][1]["target"] == "q2"
    @test buggy_result.witness["logical_verdicts"]["decoder_mismatch"]
    @test buggy_result.witness["logical_verdicts"]["recovery_mismatch"]
end
