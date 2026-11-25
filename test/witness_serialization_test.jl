if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "witness serialization" begin
    subject = BitFlipSubject(:buggy_decoder)
    trace = run_bitflip_subject(subject, Dict(:x1 => true, :x2 => false, :x3 => false))
    witness = build_witness(trace)

    @test witness["schema_version"] == WITNESS_SCHEMA_VERSION
    @test witness["generated_by"] == "ConQEC.jl AE prototype"
    @test witness["solver_backend"] == "bruteforce_boolean"
    @test witness["subject_name"] == "bitflip_buggy_decoder_table"
    @test witness["expected_decoder_output"] == "q1"
    @test witness["decoder_output"] == "q2"
    @test witness["earliest_divergence_stage"] == "decoder"
    @test all(haskey(witness, key) for key in [
        "subject_name",
        "code_size",
        "distance",
        "fault_pattern",
        "observed_syndrome",
        "decoder_output",
        "expected_decoder_output",
        "recovery_actually_applied",
        "expected_recovery",
        "logical_verdicts",
        "oracle_verdict",
        "primary_oracle",
        "triggered_oracles",
        "oracle_summary",
        "oracle_witnesses",
        "earliest_divergence_stage",
        "path",
        "exploration_policy",
        "exploration_settings",
    ])
    @test witness["logical_verdicts"]["decoder_mismatch"] == true
    @test witness["primary_oracle"] === nothing
    @test [oracle["id"] for oracle in witness["triggered_oracles"]] == [
        "O1_LOGICAL_MISMATCH",
        "O2_DECODER_MISMATCH",
        "O3_RESIDUAL_CORRECTABLE_ERROR",
    ]
    @test witness["oracle_summary"]["triggered"] == true
    @test witness["oracle_summary"]["triggered_count"] == 3
    @test witness["oracle_summary"]["summary"] ==
        "O1_LOGICAL_MISMATCH+O2_DECODER_MISMATCH+O3_RESIDUAL_CORRECTABLE_ERROR"
    @test length(witness["oracle_witnesses"]) == 3
    @test all(
        record -> record["subject_name"] == "bitflip_buggy_decoder_table",
        witness["oracle_witnesses"],
    )
    @test witness["exploration_policy"]["branch_flip_order"] == "qec_priority"
    @test witness["exploration_policy"]["branch_priority_levels"] == [
        "positive_witness_branch_trace_distance",
        "failure_adjacent_stage",
        "unseen_syndrome",
        "lower_fault_weight",
        "trace_order",
    ]

    dir = mktempdir()
    path = joinpath(dir, "witness.json")
    write_witness(path, witness)
    text = read(path, String)

    @test occursin("\"subject_name\"", text)
    @test occursin("\"schema_version\": \"conqec-witness-v1\"", text)
    @test occursin("\"solver_backend\": \"bruteforce_boolean\"", text)
    @test occursin("\"fault_pattern\"", text)
    @test occursin("\"logical_verdicts\"", text)
    @test occursin("\"primary_oracle\"", text)
    @test occursin("\"triggered_oracles\"", text)
    @test occursin("\"oracle_summary\"", text)
    @test occursin("\"oracle_witnesses\"", text)
    @test occursin("\"O2_DECODER_MISMATCH\"", text)
    @test occursin("\"earliest_divergence_stage\": \"decoder\"", text)

    clean_trace = run_bitflip_subject(
        BitFlipSubject(:clean),
        Dict(:x1 => false, :x2 => false, :x3 => false),
    )
    clean_witness = build_witness(clean_trace)
    @test clean_witness["triggered_oracles"] == Dict{String,Any}[]
    @test clean_witness["oracle_witnesses"] == Dict{String,Any}[]
    @test clean_witness["oracle_summary"]["triggered"] == false
    @test clean_witness["oracle_summary"]["summary"] == "none"

    manual_trace = ConcolicTrace(
        "manual";
        fault_vars=[:x1],
        fault_assignments=Dict(:x1 => true),
    )
    record_recovery_action!(
        manual_trace,
        Dict("pauli" => "X", "target" => "q1", "source" => "manual"),
    )
    @test manual_trace.recovery_actions[1]["target"] == "q1"

    generic_path = joinpath(dir, "generic.json")
    write_witness(generic_path, Dict("ok" => true))
    @test occursin("\"ok\": true", read(generic_path, String))

    settings_witness = build_witness(
        trace;
        exploration_settings=Dict(
            "max_tests" => 8,
            "max_fault_weight" => 1,
            "stop_on_bug" => true,
        ),
    )
    @test settings_witness["exploration_settings"]["max_tests"] == 8
    @test settings_witness["exploration_settings"]["max_fault_weight"] == 1
    @test settings_witness["exploration_settings"]["stop_on_bug"] == true
    @test settings_witness["solver_backend"] == "bruteforce_boolean"

    external_settings_witness = build_witness(
        trace;
        exploration_settings=Dict(
            "solver_backend" => "external-smt:z3",
            "max_tests" => 8,
        ),
    )
    @test external_settings_witness["solver_backend"] == "external-smt:z3"
    @test external_settings_witness["exploration_settings"]["solver_backend"] == "external-smt:z3"

    primary_witness = build_witness(
        trace;
        primary_oracle=failure_oracle_by_id("O2_DECODER_MISMATCH"),
    )
    @test primary_witness["primary_oracle"]["id"] == "O2_DECODER_MISMATCH"
end
