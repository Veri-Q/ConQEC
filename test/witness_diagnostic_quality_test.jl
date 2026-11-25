if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

function evaluated_diagnostic_subject(name::AbstractString)
    config = paper_subject_config_by_name(name)
    result = run_concolic_subject(
        config.subject;
        max_tests=config.max_tests,
        max_fault_weight=1,
        witness_dir=mktempdir(),
        stop_on_bug=true,
    )
    contract = paper_diagnostic_contract_by_name(name)
    evaluation = evaluate_diagnostic_result(result, contract; subject=config.subject)
    return config, result, contract, evaluation
end

@testset "catalog-backed witness diagnostic contracts" begin
    contracts = paper_diagnostic_contracts()
    @test length(contracts) == length(paper_subject_configs())
    @test [contract.subject_name for contract in contracts] == paper_subject_names()
    @test all(contract -> contract.bug_class != "", contracts)

    _, _, _, clean_evaluation = evaluated_diagnostic_subject("bitflip_clean")
    @test clean_evaluation.bug_class == "clean"
    @test !clean_evaluation.bug_found
    @test clean_evaluation.actual_divergence == "none"
    @test clean_evaluation.diagnostic_match
    @test clean_evaluation.replay_consistent
    @test clean_evaluation.decoder_actual_expected == "none"
    @test clean_evaluation.recovery_actual_expected == "none"
    @test clean_evaluation.expected_oracles == "none"
    @test clean_evaluation.actual_oracles == "none"

    _, _, _, decoder_evaluation =
        evaluated_diagnostic_subject("bitflip_buggy_decoder_table")
    @test decoder_evaluation.bug_class == "decoder_table"
    @test decoder_evaluation.expected_divergence == "decoder"
    @test decoder_evaluation.actual_divergence == "decoder"
    @test decoder_evaluation.decoder_actual_expected == "q2/q1"
    @test decoder_evaluation.recovery_actual_expected == "X@q2/X@q1"
    @test decoder_evaluation.expected_oracles ==
        "O1_LOGICAL_MISMATCH+O2_DECODER_MISMATCH+O3_RESIDUAL_CORRECTABLE_ERROR"
    @test decoder_evaluation.actual_oracles == decoder_evaluation.expected_oracles
    @test decoder_evaluation.diagnostic_match
    @test decoder_evaluation.replay_consistent

    _, priority_result, _, priority_evaluation =
        evaluated_diagnostic_subject("bitflip_priority_decoder_bug")
    @test priority_evaluation.bug_class == "decoder_table_priority"
    @test priority_evaluation.expected_divergence == "decoder"
    @test priority_evaluation.actual_divergence == "decoder"
    @test priority_evaluation.decoder_actual_expected == "q2/q1"
    @test priority_evaluation.recovery_actual_expected == "X@q2/X@q1"
    @test priority_evaluation.expected_oracles ==
        "O1_LOGICAL_MISMATCH+O2_DECODER_MISMATCH+O3_RESIDUAL_CORRECTABLE_ERROR"
    @test priority_evaluation.actual_oracles == priority_evaluation.expected_oracles
    @test priority_evaluation.diagnostic_match
    @test priority_evaluation.replay_consistent
    @test priority_result.generated_tests == 2

    _, _, _, recovery_evaluation =
        evaluated_diagnostic_subject("bitflip_wrong_recovery_target")
    @test recovery_evaluation.bug_class == "wrong_recovery_target"
    @test recovery_evaluation.expected_divergence == "recovery"
    @test recovery_evaluation.actual_divergence == "recovery"
    @test recovery_evaluation.decoder_actual_expected == "q1/q1"
    @test recovery_evaluation.recovery_actual_expected == "X@q2/X@q1"
    @test recovery_evaluation.actual_oracles ==
        "O1_LOGICAL_MISMATCH+O3_RESIDUAL_CORRECTABLE_ERROR"
    @test recovery_evaluation.diagnostic_match
    @test recovery_evaluation.replay_consistent

    _, _, _, missing_evaluation =
        evaluated_diagnostic_subject("bitflip_missing_recovery_branch")
    @test missing_evaluation.bug_class == "missing_recovery_branch"
    @test missing_evaluation.decoder_actual_expected == "q1/q1"
    @test missing_evaluation.recovery_actual_expected == "missing@missing/X@q1"
    @test missing_evaluation.actual_oracles ==
        "O1_LOGICAL_MISMATCH+O3_RESIDUAL_CORRECTABLE_ERROR+O4_DEAD_RECOVERY_BRANCH"
    @test missing_evaluation.diagnostic_match
    @test missing_evaluation.replay_consistent

    _, _, _, syndrome_evaluation =
        evaluated_diagnostic_subject("bitflip_syndrome_wiring_bug")
    @test syndrome_evaluation.bug_class == "syndrome_wiring"
    @test syndrome_evaluation.expected_divergence == "syndrome"
    @test syndrome_evaluation.decoder_actual_expected == "q3/q2"
    @test syndrome_evaluation.recovery_actual_expected == "X@q3/X@q2"
    @test syndrome_evaluation.actual_oracles ==
        "O1_LOGICAL_MISMATCH+O3_RESIDUAL_CORRECTABLE_ERROR"
    @test syndrome_evaluation.diagnostic_match
    @test syndrome_evaluation.replay_consistent

    _, _, _, measurement_evaluation =
        evaluated_diagnostic_subject("bitflip_measurement_misuse")
    @test measurement_evaluation.bug_class == "measurement_misuse"
    @test measurement_evaluation.expected_divergence == "measurement_result"
    @test measurement_evaluation.decoder_actual_expected == "q2/q1"
    @test measurement_evaluation.actual_oracles ==
        "O1_LOGICAL_MISMATCH+O3_RESIDUAL_CORRECTABLE_ERROR"
    @test measurement_evaluation.diagnostic_match
    @test measurement_evaluation.replay_consistent

    _, _, _, steane_evaluation =
        evaluated_diagnostic_subject("steane_css_buggy_decoder_table")
    @test steane_evaluation.bug_class == "decoder_table"
    @test steane_evaluation.decoder_actual_expected == "q2/q1"
    @test steane_evaluation.recovery_actual_expected == "X@q2/X@q1"
    @test steane_evaluation.diagnostic_match
    @test steane_evaluation.replay_consistent

    _, _, _, surface_evaluation =
        evaluated_diagnostic_subject("surface_d3_x_memory_buggy_decoder_table")
    @test surface_evaluation.bug_class == "decoder_table"
    @test surface_evaluation.decoder_actual_expected == "q2/q1"
    @test surface_evaluation.recovery_actual_expected == "X@q2/X@q1"
    @test surface_evaluation.diagnostic_match
    @test surface_evaluation.replay_consistent

    _, _, _, repetition_evaluation =
        evaluated_diagnostic_subject("repetition_d5_decoder_neighbor_bug")
    @test repetition_evaluation.bug_class == "decoder_neighbor"
    @test repetition_evaluation.decoder_actual_expected == "q2/q1"
    @test repetition_evaluation.recovery_actual_expected == "X@q2/X@q1"
    @test repetition_evaluation.diagnostic_match
    @test repetition_evaluation.replay_consistent

    _, _, _, round_evaluation =
        evaluated_diagnostic_subject("round_repetition_d3_r2_history_drop_bug")
    @test round_evaluation.bug_class == "repeated_round_history_drop"
    @test round_evaluation.decoder_actual_expected == "r2_q1/r1_q1"
    @test round_evaluation.recovery_actual_expected == "X@q1:round=2/X@q1:round=1"
    @test round_evaluation.actual_oracles == "O2_DECODER_MISMATCH"
    @test round_evaluation.diagnostic_match
    @test round_evaluation.replay_consistent

    _, _, _, relational_evaluation =
        evaluated_diagnostic_subject("round_repetition_d3_r2_inconsistent_control_bug")
    @test relational_evaluation.bug_class == "repeated_round_inconsistent_control"
    @test relational_evaluation.actual_divergence == "repeated_round_control"
    @test relational_evaluation.decoder_actual_expected == "r2_q1/r2_q1"
    @test relational_evaluation.recovery_actual_expected == "X@q1:round=2/X@q1:round=2"
    @test relational_evaluation.actual_oracles == "O5_INCONSISTENT_CONTROL"
    @test relational_evaluation.diagnostic_match
    @test relational_evaluation.replay_consistent
end

@testset "diagnostic contracts reject drifted witnesses" begin
    config, result, contract, _ =
        evaluated_diagnostic_subject("bitflip_buggy_decoder_table")

    wrong_decoder = deepcopy(result.witness)
    wrong_decoder["decoder_output"] = "q3"
    wrong_decoder_eval = evaluate_witness_diagnostics(
        wrong_decoder,
        contract;
        bug_found=true,
        replay_witness=replay_witness_for_subject(config.subject, wrong_decoder),
    )
    @test !wrong_decoder_eval.diagnostic_match
    @test !wrong_decoder_eval.replay_consistent
    @test any(mismatch -> occursin("decoder actual", mismatch),
        wrong_decoder_eval.mismatches)

    wrong_stage = deepcopy(result.witness)
    wrong_stage["earliest_divergence_stage"] = "recovery"
    wrong_stage_eval = evaluate_witness_diagnostics(
        wrong_stage,
        contract;
        bug_found=true,
        replay_witness=replay_witness_for_subject(config.subject, wrong_stage),
    )
    @test !wrong_stage_eval.diagnostic_match
    @test !wrong_stage_eval.replay_consistent
    @test any(mismatch -> occursin("earliest_divergence", mismatch),
        wrong_stage_eval.mismatches)

    wrong_recovery = deepcopy(result.witness)
    wrong_recovery["recovery_actually_applied"][1]["target"] = "q3"
    wrong_recovery_eval = evaluate_witness_diagnostics(
        wrong_recovery,
        contract;
        bug_found=true,
        replay_witness=replay_witness_for_subject(config.subject, wrong_recovery),
    )
    @test !wrong_recovery_eval.diagnostic_match
    @test !wrong_recovery_eval.replay_consistent
    @test any(mismatch -> occursin("recovery actual", mismatch),
        wrong_recovery_eval.mismatches)

    missing_metadata = deepcopy(result.witness)
    delete!(missing_metadata["metadata"], "syndrome_diagnostics")
    missing_metadata_eval = evaluate_witness_diagnostics(
        missing_metadata,
        contract;
        bug_found=true,
        replay_witness=replay_witness_for_subject(config.subject, missing_metadata),
    )
    @test !missing_metadata_eval.diagnostic_match
    @test !missing_metadata_eval.replay_consistent
    @test any(mismatch -> occursin("missing required diagnostic value", mismatch),
        missing_metadata_eval.mismatches)

    wrong_oracles = deepcopy(result.witness)
    wrong_oracles["triggered_oracles"] = [
        Dict{String,Any}(
            "id" => "O4_DEAD_RECOVERY_BRANCH",
            "name" => "Dead recovery branch",
            "verdict_key" => "missing_recovery_branch",
            "description" => "wrong drifted oracle",
        ),
    ]
    wrong_oracles["oracle_summary"] = Dict{String,Any}(
        "triggered" => true,
        "triggered_count" => 1,
        "triggered_ids" => ["O4_DEAD_RECOVERY_BRANCH"],
        "summary" => "O4_DEAD_RECOVERY_BRANCH",
    )
    wrong_oracles_eval = evaluate_witness_diagnostics(
        wrong_oracles,
        contract;
        bug_found=true,
        replay_witness=replay_witness_for_subject(config.subject, wrong_oracles),
    )
    @test !wrong_oracles_eval.diagnostic_match
    @test !wrong_oracles_eval.replay_consistent
    @test any(mismatch -> occursin("triggered_oracles expected", mismatch),
        wrong_oracles_eval.mismatches)
    @test any(mismatch -> occursin("stored triggered_oracles disagree", mismatch),
        wrong_oracles_eval.mismatches)
end
