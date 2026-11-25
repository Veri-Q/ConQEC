if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "large decoder-table benchmark family" begin
    configs = [
        config for config in paper_subject_configs()
        if get(subject_metadata(config.subject), "subject_family", "") == "large_decoder_table"
    ]
    @test length(configs) == 8
    @test count(config -> config_bug_metadata(config)["decoder_arms"] == 32, configs) == 2
    @test count(config -> config_bug_metadata(config)["decoder_arms"] == 64, configs) == 2
    @test count(config -> config_bug_metadata(config)["decoder_arms"] == 128, configs) == 2
    @test count(config -> config_bug_metadata(config)["decoder_arms"] == 256, configs) == 2
    @test all(config -> config_bug_metadata(config)["path_sensitive"], configs)
    @test all(config -> config_bug_metadata(config)["failing_assignments"] == 1, configs)
    @test count(config -> config_bug_metadata(config)["hardness_bin"] == "medium", configs) == 8

    config = paper_subject_config_by_name("large_decoder_table_a32_sparse_29_a")
    subject = config.subject
    metadata = config_bug_metadata(config)
    @test metadata["decoder_arms"] == 32
    @test metadata["reachable_syndromes"] == 33
    @test metadata["admissible_assignments"] == 97
    @test metadata["budget"] == 16
    @test metadata["bug_hit_probability"] < 0.011

    zero = zero_assignment(subject_fault_vars(subject))
    zero_trace = run_subject(subject, zero)
    @test zero_trace.logical_verdicts["oracle_verdict"]
    @test zero_trace.decoder_decisions["actual"] == "none"
    @test zero_trace.metadata["decoder_arms"] == 32
    @test zero_trace.metadata["exhaustibility_ratio"] < 0.2
    @test findfirst(guard -> guard.id == "fault:large_decoder_decoy_0001",
        zero_trace.branch_guards) <
        findfirst(guard -> guard.id == "decoder:arm_0029", zero_trace.branch_guards)

    bug_model = copy(zero)
    bug_model[Symbol("ldt_arm_0029")] = true
    bug_trace = run_subject(subject, bug_model)
    @test !bug_trace.logical_verdicts["oracle_verdict"]
    @test bug_trace.logical_verdicts["decoder_mismatch"]
    @test bug_trace.decoder_decisions["expected"] == "q0029"
    @test bug_trace.decoder_decisions["actual"] == "q0030"
    @test bug_trace.metadata["earliest_divergence_stage"] == "decoder"

    witness_dir = mktempdir()
    qec = run_concolic_subject(
        subject;
        max_tests=config.max_tests,
        max_fault_weight=1,
        branch_strategy=:qec_priority,
        witness_dir=witness_dir,
        stop_on_bug=true,
    )
    trace_order = run_concolic_subject(
        subject;
        max_tests=config.max_tests,
        max_fault_weight=1,
        branch_strategy=:trace_order,
        witness_dir=witness_dir,
        stop_on_bug=true,
    )
    @test qec.bug_found
    @test first_failure_trial(qec.traces) == 2
    @test !trace_order.bug_found
    @test first_failure_trial(trace_order.traces) === nothing

    stress = LargeDecoderTableSubject(
        2048,
        2047;
        decoys=2048,
        budget=16,
        label="large_decoder_table_a2048_sparse_2047_stress_test",
    )
    stress_meta = subject_metadata(stress)
    @test stress_meta["decoder_arms"] == 2048
    @test stress_meta["budget"] == 16
    @test stress_meta["hardness_bin"] == "hard"
    @test stress_meta["bug_hit_probability"] < 0.00025
    @test !(subject_name(stress) in paper_subject_names())
end
