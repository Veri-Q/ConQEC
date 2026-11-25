if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "Steane CSS subject" begin
    @test steane_fault_vars() == vcat(
        [Symbol("x", idx) for idx in 1:7],
        [Symbol("z", idx) for idx in 1:7],
        [Symbol("y", idx) for idx in 1:7],
    )
    @test steane_column_syndrome(1) == "100"
    @test steane_column_syndrome(7) == "111"
    @test reference_steane_decoder("000") == "none"
    @test reference_steane_decoder("100") == "q1"
    @test reference_steane_decoder("111") == "q7"

    clean = SteaneSubject()
    @test subject_name(clean) == "steane_css_clean"
    @test subject_fault_vars(clean) == steane_fault_vars()
    @test subject_metadata(clean)["subject_family"] == "steane_css_code"
    @test subject_metadata(clean)["code"] == "[[7,1,3]] Steane CSS code"

    q1_fault = Dict(
        :x1 => true,
        :x2 => false,
        :x3 => false,
        :x4 => false,
        :x5 => false,
        :x6 => false,
        :x7 => false,
    )
    clean_trace = run_subject(clean, q1_fault)
    @test clean_trace.decoder_decisions["syndrome"] == "X=100;Z=000"
    @test clean_trace.decoder_decisions["x_syndrome"] == "100"
    @test clean_trace.decoder_decisions["z_syndrome"] == "000"
    @test clean_trace.decoder_decisions["actual"] == "q1"
    @test clean_trace.decoder_decisions["expected"] == "q1"
    @test clean_trace.recovery_actions[1]["pauli"] == "X"
    @test clean_trace.recovery_actions[1]["target"] == "q1"
    @test clean_trace.metadata["parity_check_columns"] ==
        ["100", "010", "001", "110", "011", "101", "111"]
    @test clean_trace.metadata["syndrome_space_size"] == 64
    @test clean_trace.metadata["decoder_table_total"]
    @test clean_trace.logical_verdicts["oracle_verdict"]

    z1_fault = Dict(:z1 => true)
    z_trace = run_subject(clean, z1_fault)
    @test z_trace.decoder_decisions["syndrome"] == "X=000;Z=100"
    @test z_trace.decoder_decisions["actual"] == "Z:q1"
    @test z_trace.recovery_actions[1]["pauli"] == "Z"
    @test z_trace.recovery_actions[1]["target"] == "q1"
    @test z_trace.logical_verdicts["oracle_verdict"]

    y1_fault = Dict(:y1 => true)
    y_trace = run_subject(clean, y1_fault)
    @test y_trace.decoder_decisions["syndrome"] == "X=100;Z=100"
    @test y_trace.decoder_decisions["actual"] == "X:q1|Z:q1"
    @test y_trace.recovery_actions[1]["pauli"] == "Y"
    @test y_trace.recovery_actions[1]["target"] == "q1"
    @test y_trace.metadata["residual_logical_class"]["logical_ok"]
    @test y_trace.logical_verdicts["oracle_verdict"]

    clean_result = run_concolic_subject(
        clean;
        max_tests=40,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test !clean_result.bug_found
    @test clean_result.generated_tests == 22
    @test length(clean_result.unique_syndromes) == 22

    buggy = SteaneSubject(:buggy_decoder)
    buggy_result = run_concolic_subject(
        buggy;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test buggy_result.bug_found
    @test buggy_result.generated_tests == 2
    @test buggy_result.witness["subject_name"] == "steane_css_buggy_decoder_table"
    @test buggy_result.witness["earliest_divergence_stage"] == "decoder"
    @test buggy_result.witness["decoder_output"] == "q2"
    @test buggy_result.witness["expected_decoder_output"] == "q1"
    @test buggy_result.witness["recovery_actually_applied"][1]["target"] == "q2"
    @test buggy_result.witness["expected_recovery"]["target"] == "q1"
    @test buggy_result.witness["logical_verdicts"]["decoder_mismatch"]
    @test buggy_result.witness["metadata"]["subject_family"] == "steane_css_code"
    @test buggy_result.witness["metadata"]["decoder_diagnostics"]["x_decoder_buggy_entry"] ==
        "100 -> q2 instead of q1"
    @test buggy_result.witness["metadata"]["symbolic_stabilizer"]["tracked_paulis"] ==
        ["X", "Z"]
end
