if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "bit-flip clean and recovery smoke variants" begin
    clean = BitFlipSubject(:clean)
    clean_result = run_concolic(
        input -> run_bitflip_subject(clean, input),
        bitflip_fault_vars();
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test !clean_result.bug_found
    @test clean_result.generated_tests == 4
    @test length(clean_result.unique_syndromes) == 4
    @test clean_result.witness_path === nothing

    wrong_recovery = BitFlipSubject(:wrong_recovery_target)
    wrong_result = run_concolic(
        input -> run_bitflip_subject(wrong_recovery, input),
        bitflip_fault_vars();
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test wrong_result.bug_found
    @test wrong_result.generated_tests == 2
    @test wrong_result.witness["earliest_divergence_stage"] == "recovery"
    @test wrong_result.witness["decoder_output"] == "q1"
    @test wrong_result.witness["expected_decoder_output"] == "q1"
    @test wrong_result.witness["expected_recovery"]["target"] == "q1"
    @test wrong_result.witness["recovery_actually_applied"][1]["target"] == "q2"
    @test wrong_result.witness["logical_verdicts"]["missing_recovery_branch"] == false

    missing_recovery = BitFlipSubject(:missing_recovery_branch)
    missing_result = run_concolic(
        input -> run_bitflip_subject(missing_recovery, input),
        bitflip_fault_vars();
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test missing_result.bug_found
    @test missing_result.generated_tests == 2
    @test missing_result.witness["earliest_divergence_stage"] == "recovery"
    @test missing_result.witness["decoder_output"] == "q1"
    @test missing_result.witness["expected_decoder_output"] == "q1"
    @test missing_result.witness["expected_recovery"]["target"] == "q1"
    @test missing_result.witness["recovery_actually_applied"][1]["target"] == "missing"
    @test missing_result.witness["logical_verdicts"]["missing_recovery_branch"] == true

    syndrome_wiring = BitFlipSubject(:syndrome_wiring_bug)
    syndrome_result = run_concolic(
        input -> run_bitflip_subject(syndrome_wiring, input),
        bitflip_fault_vars();
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test syndrome_result.bug_found
    @test syndrome_result.generated_tests == 3
    @test syndrome_result.witness["subject_name"] == "bitflip_syndrome_wiring_bug"
    @test syndrome_result.witness["earliest_divergence_stage"] == "syndrome"
    @test syndrome_result.witness["logical_verdicts"]["syndrome_mismatch"] == true
    @test syndrome_result.witness["logical_verdicts"]["decoder_mismatch"] == true
    @test syndrome_result.witness["decoder_output"] == "q3"
    @test syndrome_result.witness["expected_decoder_output"] == "q2"
    @test syndrome_result.witness["recovery_actually_applied"][1]["target"] == "q3"
    @test syndrome_result.witness["expected_recovery"]["target"] == "q2"

    diagnostics = syndrome_result.witness["metadata"]["syndrome_diagnostics"]
    @test diagnostics["observed"] == "01"
    @test diagnostics["expected"] == "11"
    @test diagnostics["observed_bits"]["s12"] == false
    @test diagnostics["observed_bits"]["s23"] == true
    @test diagnostics["expected_bits"]["s12"] == true
    @test diagnostics["expected_bits"]["s23"] == true
    @test any(
        entry -> entry["id"] == "syndrome:s12_wiring_matches_reference" &&
            entry["stage"] == "syndrome" &&
            entry["path_constraint"] == false,
        syndrome_result.witness["path"],
    )

    measurement_misuse = BitFlipSubject(:measurement_misuse)
    measurement_result = run_concolic(
        input -> run_bitflip_subject(measurement_misuse, input),
        bitflip_fault_vars();
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test measurement_result.bug_found
    @test measurement_result.generated_tests == 2
    @test measurement_result.witness["subject_name"] == "bitflip_measurement_misuse"
    @test measurement_result.witness["earliest_divergence_stage"] == "measurement_result"
    @test measurement_result.witness["logical_verdicts"]["measurement_misuse"] == true
    @test measurement_result.witness["metadata"]["measurement_misuse"]["misused_observable"] ==
        "s23 reads s12 parity"
    @test measurement_result.witness["metadata"]["syndrome_diagnostics"]["observed"] == "11"
    @test measurement_result.witness["metadata"]["syndrome_diagnostics"]["expected"] == "10"
end
