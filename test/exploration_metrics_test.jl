if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end
using Test

@testset "exploration metrics" begin
    bitflip_vars = bitflip_fault_vars()
    clean_bitflip = BitFlipSubject(:clean)
    clean_result = run_concolic(
        input -> run_bitflip_subject(clean_bitflip, input),
        bitflip_vars;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    expected_bitflip_ids = [
        "decoder:syndrome_00",
        "decoder:syndrome_01",
        "decoder:syndrome_10",
        "decoder:syndrome_11",
        "recovery:decoder_output_none",
        "recovery:decoder_output_q1",
        "recovery:decoder_output_q2",
        "recovery:decoder_output_q3",
        "syndrome:s12_value",
        "syndrome:s23_value",
    ]
    @test branch_ids(clean_result) == expected_bitflip_ids
    @test branch_ids(clean_result.traces) == expected_bitflip_ids

    clean_counts = stage_counts(clean_result)
    @test clean_counts["decoder"] == 10
    @test clean_counts["syndrome"] == 8
    @test clean_counts["recovery"] == 10

    clean_summary = exploration_summary(clean_result)
    @test clean_summary["generated_tests"] == 4
    @test clean_summary["unique_syndromes"] == 4
    @test clean_summary["unique_branch_ids"] == 10
    @test clean_summary["branch_ids"] == expected_bitflip_ids
    @test clean_summary["branch_guard_count"] == 28
    @test clean_summary["stage_counts"]["decoder"] == 10
    @test clean_summary["bug_found"] == false
    @test clean_summary["witness_count"] == 0
    @test clean_summary["earliest_divergence"] === nothing
    @test clean_summary["witness_fault_weight"] === nothing
    @test clean_summary["minimized_fault_weight"] === nothing

    syndrome_bug = BitFlipSubject(:syndrome_wiring_bug)
    syndrome_result = run_concolic(
        input -> run_bitflip_subject(syndrome_bug, input),
        bitflip_vars;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test branch_ids(syndrome_result) == [
        "decoder:syndrome_00",
        "decoder:syndrome_01",
        "decoder:syndrome_10",
        "decoder:syndrome_11",
        "recovery:decoder_output_none",
        "recovery:decoder_output_q1",
        "recovery:decoder_output_q2",
        "recovery:decoder_output_q3",
        "syndrome:s12_value",
        "syndrome:s12_wiring_matches_reference",
        "syndrome:s23_value",
    ]

    syndrome_counts = stage_counts(syndrome_result)
    @test syndrome_counts["syndrome"] == 9
    @test syndrome_counts["decoder"] == 7
    @test syndrome_counts["recovery"] == 7

    syndrome_summary = exploration_summary(syndrome_result)
    @test syndrome_summary["generated_tests"] == 3
    @test syndrome_summary["unique_syndromes"] == 3
    @test syndrome_summary["unique_branch_ids"] == 11
    @test syndrome_summary["bug_found"] == true
    @test syndrome_summary["witness_count"] == 1
    @test syndrome_summary["earliest_divergence"] == "syndrome"
    @test syndrome_summary["witness_fault_weight"] == 1
    @test syndrome_summary["minimized_fault_weight"] == 1

    multi_witness_dir = mktempdir()
    multi_witness_result = run_concolic(
        input -> run_bitflip_subject(syndrome_bug, input),
        bitflip_vars;
        max_tests=8,
        max_fault_weight=1,
        stop_on_bug=false,
        max_witnesses=2,
        witness_dir=multi_witness_dir,
    )
    @test multi_witness_result.generated_tests == 3
    @test length(multi_witness_result.witnesses) == 2
    @test length(multi_witness_result.witness_paths) == 2
    @test multi_witness_result.witness == first(multi_witness_result.witnesses)
    @test multi_witness_result.witness_path == first(multi_witness_result.witness_paths)
    @test all(isfile, multi_witness_result.witness_paths)
    @test exploration_summary(multi_witness_result)["witness_count"] == 2
    @test [w["earliest_divergence_stage"] for w in multi_witness_result.witnesses] ==
        ["syndrome", "syndrome"]
    @test [stored_primary_failure_oracle_id(w) for w in multi_witness_result.witnesses] == [
        "O1_LOGICAL_MISMATCH",
        "O3_RESIDUAL_CORRECTABLE_ERROR",
    ]
    @test [w["decoder_output"] for w in multi_witness_result.witnesses] == ["q3", "q3"]
    @test [w["expected_decoder_output"] for w in multi_witness_result.witnesses] ==
        ["q2", "q2"]
    @test [w["exploration_settings"]["witness_index"] for w in multi_witness_result.witnesses] ==
        [1, 2]
    @test all(
        w -> w["exploration_settings"]["max_witnesses"] == 2,
        multi_witness_result.witnesses,
    )
    @test all(
        w -> w["exploration_settings"]["witness_uniqueness"] == "oracle",
        multi_witness_result.witnesses,
    )

    execution_unique_result = run_concolic(
        input -> run_bitflip_subject(syndrome_bug, input),
        bitflip_vars;
        max_tests=8,
        max_fault_weight=1,
        stop_on_bug=false,
        max_witnesses=2,
        witness_uniqueness=:execution,
        witness_dir=mktempdir(),
    )
    @test execution_unique_result.generated_tests == 4
    @test length(execution_unique_result.witnesses) == 2
    @test [stored_primary_failure_oracle_id(w) for w in execution_unique_result.witnesses] == [
        "O1_LOGICAL_MISMATCH",
        "O1_LOGICAL_MISMATCH",
    ]
    @test [
        join([item["label"] for item in w["fault_pattern"] if item["active"]], ";")
        for w in execution_unique_result.witnesses
    ] == ["X@q2", "X@q3"]
    @test all(
        w -> w["exploration_settings"]["witness_uniqueness"] == "execution",
        execution_unique_result.witnesses,
    )

    one_witness_continue_result = run_concolic(
        input -> run_bitflip_subject(syndrome_bug, input),
        bitflip_vars;
        max_tests=8,
        max_fault_weight=1,
        stop_on_bug=false,
        max_witnesses=1,
        witness_dir=mktempdir(),
    )
    @test one_witness_continue_result.generated_tests == 3
    @test length(one_witness_continue_result.witnesses) == 1
    @test_throws ErrorException run_concolic(
        input -> run_bitflip_subject(syndrome_bug, input),
        bitflip_vars;
        max_witnesses=0,
        witness_dir=mktempdir(),
    )

    trace_order_syndrome_result = run_concolic(
        input -> run_bitflip_subject(syndrome_bug, input),
        bitflip_vars;
        max_tests=8,
        max_fault_weight=1,
        branch_strategy=:trace_order,
        witness_dir=mktempdir(),
    )
    @test exploration_summary(trace_order_syndrome_result)["generated_tests"] == 3
    @test stage_counts(trace_order_syndrome_result)["syndrome"] == 9
    @test trace_order_syndrome_result.witness["exploration_settings"]["branch_strategy"] ==
        "trace_order"

    repetition_vars = repetition_fault_vars(5)
    clean_repetition = RepetitionSubject(5)
    clean_repetition_result = run_concolic(
        input -> run_repetition_subject(clean_repetition, input),
        repetition_vars;
        max_tests=12,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    repetition_ids = branch_ids(clean_repetition_result)
    @test repetition_ids == [
        "decoder:syndrome_0000",
        "decoder:syndrome_0001",
        "decoder:syndrome_0011",
        "decoder:syndrome_0110",
        "decoder:syndrome_1000",
        "decoder:syndrome_1100",
        "recovery:decoder_output_none",
        "recovery:decoder_output_q1",
        "recovery:decoder_output_q2",
        "recovery:decoder_output_q3",
        "recovery:decoder_output_q4",
        "recovery:decoder_output_q5",
        "syndrome:s12_value",
        "syndrome:s23_value",
        "syndrome:s34_value",
        "syndrome:s45_value",
    ]
    @test stage_counts(clean_repetition_result)["decoder"] == 21
    @test stage_counts(clean_repetition_result)["recovery"] == 21
    @test stage_counts(clean_repetition_result)["syndrome"] == 24

    buggy_repetition = RepetitionSubject(5, :decoder_neighbor_bug)
    buggy_repetition_result = run_concolic(
        input -> run_repetition_subject(buggy_repetition, input),
        repetition_vars;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    buggy_summary = exploration_summary(buggy_repetition_result)
    @test buggy_summary["generated_tests"] == 2
    @test buggy_summary["unique_syndromes"] == 2
    @test buggy_summary["unique_branch_ids"] == 8
    @test buggy_summary["stage_counts"]["decoder"] == 3
    @test buggy_summary["stage_counts"]["recovery"] == 3
    @test buggy_summary["stage_counts"]["syndrome"] == 8
    @test buggy_summary["bug_found"] == true
    @test buggy_summary["earliest_divergence"] == "decoder"
    @test buggy_summary["witness_fault_weight"] == 1
    @test buggy_summary["minimized_fault_weight"] == 1
end
