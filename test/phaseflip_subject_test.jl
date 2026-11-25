@testset "phase-flip subject" begin
    @test phaseflip_fault_vars() == [:z1, :z2, :z3]
    @test reference_phaseflip_decoder("00") == "none"
    @test reference_phaseflip_decoder("10") == "q1"
    @test reference_phaseflip_decoder("11") == "q2"
    @test reference_phaseflip_decoder("01") == "q3"

    clean = PhaseFlipSubject()
    @test subject_name(clean) == "phaseflip_clean"
    @test subject_fault_vars(clean) == [:z1, :z2, :z3]
    @test subject_metadata(clean)["mode"] == "clean"
    @test subject_metadata(clean)["fault_model"] == "single Pauli-Z data fault"

    clean_trace = run_subject(
        clean,
        Dict("z1" => true, "z2" => false, "z3" => false),
    )
    clean_pattern = fault_pattern(clean_trace)
    @test clean_pattern[1]["variable"] == "z1"
    @test clean_pattern[1]["pauli"] == "Z"
    @test clean_pattern[1]["label"] == "Z@q1"
    @test clean_pattern[1]["active"] == true
    @test clean_trace.decoder_decisions["actual"] == "q1"
    @test clean_trace.decoder_decisions["expected"] == "q1"
    @test clean_trace.recovery_actions[1]["pauli"] == "Z"
    @test clean_trace.recovery_actions[1]["target"] == "q1"
    @test clean_trace.metadata["expected_recovery"]["pauli"] == "Z"
    @test clean_trace.logical_verdicts["oracle_verdict"]

    clean_result = run_concolic_subject(
        clean;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test !clean_result.bug_found
    @test clean_result.generated_tests == 4
    @test length(clean_result.unique_syndromes) == 4
    @test clean_result.witness_path === nothing

    buggy = PhaseFlipSubject(:buggy_decoder)
    buggy_result = run_concolic_subject(
        buggy;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test buggy_result.bug_found
    @test buggy_result.generated_tests == 2
    @test buggy_result.witness["earliest_divergence_stage"] == "decoder"
    @test buggy_result.witness["fault_pattern"][1]["label"] == "Z@q1"
    @test buggy_result.witness["fault_pattern"][1]["active"] == true
    @test buggy_result.witness["decoder_output"] == "q2"
    @test buggy_result.witness["expected_decoder_output"] == "q1"
    @test buggy_result.witness["recovery_actually_applied"][1]["pauli"] == "Z"
    @test buggy_result.witness["recovery_actually_applied"][1]["target"] == "q2"
    @test buggy_result.witness["expected_recovery"]["pauli"] == "Z"
    @test buggy_result.witness["expected_recovery"]["target"] == "q1"
    @test buggy_result.witness["logical_verdicts"]["decoder_mismatch"]
    @test buggy_result.witness["logical_verdicts"]["recovery_mismatch"]

    wrong_recovery = PhaseFlipSubject(:wrong_recovery_target)
    wrong_result = run_concolic_subject(
        wrong_recovery;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test wrong_result.bug_found
    @test wrong_result.generated_tests == 2
    @test wrong_result.witness["earliest_divergence_stage"] == "recovery"
    @test wrong_result.witness["decoder_output"] == "q1"
    @test wrong_result.witness["expected_decoder_output"] == "q1"
    @test wrong_result.witness["recovery_actually_applied"][1]["pauli"] == "Z"
    @test wrong_result.witness["recovery_actually_applied"][1]["target"] == "q2"
    @test wrong_result.witness["expected_recovery"]["pauli"] == "Z"
    @test wrong_result.witness["expected_recovery"]["target"] == "q1"
end
