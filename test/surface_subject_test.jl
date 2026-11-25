if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "surface-code kernel subject" begin
    @test surface_fault_vars() == vcat(
        [Symbol("x", idx) for idx in 1:9],
        [Symbol("z", idx) for idx in 1:9],
        [Symbol("y", idx) for idx in 1:9],
    )
    @test surface_syndrome_from_single_fault(1) == "1000"
    @test surface_syndrome_from_single_fault(5) == "1111"
    @test surface_syndrome_from_single_fault(9) == "0001"
    @test reference_surface_decoder("0000") == "none"
    @test reference_surface_decoder("1000") == "q1"
    @test reference_surface_decoder("1111") == "q5"

    clean = SurfaceSubject()
    @test subject_name(clean) == "surface_d3_x_memory_clean"
    @test subject_fault_vars(clean) == surface_fault_vars()
    @test subject_metadata(clean)["subject_family"] == "surface_code_kernel"
    @test subject_metadata(clean)["code"] == "distance-3 surface-code CSS patch kernel"

    q1_fault = Dict(
        :x1 => true,
        :x2 => false,
        :x3 => false,
        :x4 => false,
        :x5 => false,
        :x6 => false,
        :x7 => false,
        :x8 => false,
        :x9 => false,
    )
    clean_trace = run_subject(clean, q1_fault)
    @test clean_trace.decoder_decisions["syndrome"] == "X=1000;Z=0000"
    @test clean_trace.decoder_decisions["x_syndrome"] == "1000"
    @test clean_trace.decoder_decisions["z_syndrome"] == "0000"
    @test clean_trace.decoder_decisions["actual"] == "q1"
    @test clean_trace.decoder_decisions["expected"] == "q1"
    @test clean_trace.recovery_actions[1]["target"] == "q1"
    @test clean_trace.metadata["single_fault_syndromes"] ==
        ["1000", "1100", "0100", "1010", "1111", "0101", "0010", "0011", "0001"]
    @test clean_trace.metadata["axis_syndrome_space_size"] == 16
    @test clean_trace.metadata["syndrome_space_size"] == 256
    @test clean_trace.metadata["decoder_table_total"]
    @test clean_trace.logical_verdicts["oracle_verdict"]

    z1_fault = Dict(:z1 => true)
    z_trace = run_subject(clean, z1_fault)
    @test z_trace.decoder_decisions["syndrome"] == "X=0000;Z=1000"
    @test z_trace.decoder_decisions["actual"] == "Z:q1"
    @test z_trace.recovery_actions[1]["pauli"] == "Z"
    @test z_trace.recovery_actions[1]["target"] == "q1"
    @test z_trace.logical_verdicts["oracle_verdict"]

    y1_fault = Dict(:y1 => true)
    y_trace = run_subject(clean, y1_fault)
    @test y_trace.decoder_decisions["syndrome"] == "X=1000;Z=1000"
    @test y_trace.decoder_decisions["actual"] == "X:q1|Z:q1"
    @test y_trace.recovery_actions[1]["pauli"] == "Y"
    @test y_trace.recovery_actions[1]["target"] == "q1"
    @test y_trace.metadata["residual_logical_class"]["logical_ok"]
    @test y_trace.logical_verdicts["oracle_verdict"]

    clean_result = run_concolic_subject(
        clean;
        max_tests=50,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test !clean_result.bug_found
    @test clean_result.generated_tests == 28
    @test length(clean_result.unique_syndromes) == 28

    buggy = SurfaceSubject(:buggy_decoder)
    buggy_result = run_concolic_subject(
        buggy;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test buggy_result.bug_found
    @test buggy_result.generated_tests == 2
    @test buggy_result.witness["subject_name"] == "surface_d3_x_memory_buggy_decoder_table"
    @test buggy_result.witness["earliest_divergence_stage"] == "decoder"
    @test buggy_result.witness["decoder_output"] == "q2"
    @test buggy_result.witness["expected_decoder_output"] == "q1"
    @test buggy_result.witness["recovery_actually_applied"][1]["target"] == "q2"
    @test buggy_result.witness["expected_recovery"]["target"] == "q1"
    @test buggy_result.witness["logical_verdicts"]["decoder_mismatch"]
    @test buggy_result.witness["metadata"]["subject_family"] == "surface_code_kernel"
    @test buggy_result.witness["metadata"]["decoder_diagnostics"]["x_decoder_buggy_entry"] ==
        "1000 -> q2 instead of q1"
    @test buggy_result.witness["metadata"]["symbolic_stabilizer"]["tracked_paulis"] ==
        ["X", "Z"]
end
