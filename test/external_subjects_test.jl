@testset "external/adapted QECC subject validation" begin
    configs = external_subject_configs()
    @test length(configs) >= 5
    @test length(unique(string(get(subject_metadata(config.subject), "code_kind", "unknown"))
        for config in configs)) >= 3

    for config in configs
        metadata = config_bug_metadata(config)
        @test metadata !== nothing
        @test !isempty(string(metadata["bug_class"]))
        @test !isempty(string(metadata["mutation_operator"]))
        @test string(get(metadata, "benchmark_family", "")) == "ExternalSubjects"
        @test get(metadata, "external_subject", false) == true

        vars = subject_fault_vars(config.subject)
        zero = zero_assignment(vars)
        zero_trace = run_subject(config.subject, zero)
        @test !ConQEC.trace_has_bug(zero_trace)

        trigger = zero_assignment(vars)
        for fault in get(metadata, "trigger_faults", String[])
            trigger[Symbol(String(fault))] = true
        end
        trigger_trace = run_subject(config.subject, trigger)
        @test ConQEC.trace_has_bug(trigger_trace)
        @test earliest_divergence(trigger_trace) ==
            string(metadata["expected_earliest_divergence"])

        result = mktempdir() do witness_dir
            run_concolic_subject(
                config.subject;
                max_tests=config.max_tests,
                max_fault_weight=1,
                solver=BruteForceBoolSolver(vars; max_weight=1),
                witness_dir=witness_dir,
                stop_on_bug=true,
                minimize_witnesses=false,
            )
        end
        @test result.bug_found
        contract = DiagnosticContract(
            subject_name(config.subject),
            string(metadata["bug_class"]);
            expected_bug_found=true,
            expected_divergence=string(metadata["expected_earliest_divergence"]),
            expected_decoder_actual=get(metadata, "expected_actual_decoder", nothing),
            expected_decoder_expected=get(metadata, "expected_reference_decoder", nothing),
            expected_recovery_actual=get(metadata, "expected_actual_recovery", nothing),
            expected_recovery_expected=get(metadata, "expected_reference_recovery", nothing),
            expected_oracles=get(metadata, "expected_oracle_classes", String[]),
        )
        evaluation = evaluate_diagnostic_result(result, contract; subject=config.subject)
        @test evaluation.replay_consistent
        @test evaluation.diagnostic_match
    end
end
