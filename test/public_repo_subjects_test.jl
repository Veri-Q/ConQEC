if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "public-repo-derived QECC subjects" begin
    subject = PublicRepoQECCSubject(
        "public_qecsim_planar_decoder_smoke";
        repo_name="qecsim",
        repo_url="https://github.com/qecsim/qecsim",
        repo_commit="24d6b8a",
        source_path="tests/models/test_planar_cmwpm_decoder.py",
        source_lines="77-101",
        source_motif="PlanarCode(3,3) correlated error recovery/logical checks",
        code_kind=:qecsim_planar,
        bug_mode=:recovery_application_error,
        qubits=9,
        rounds=1,
        public_arms=18,
        neutral_decoys=24,
        trigger_index=13,
        wrong_index=4,
        budget=8,
    )
    metadata = public_repo_subject_metadata(subject)
    @test metadata["public_repo_derived"] == true
    @test metadata["benchmark_family"] == "PublicRepoQECC"
    @test metadata["repo_commit"] == "24d6b8a"
    @test metadata["source_path"] == "tests/models/test_planar_cmwpm_decoder.py"
    @test metadata["neutral_control_branches"] == 24

    vars = subject_fault_vars(subject)
    zero = zero_assignment(vars)
    @test !ConQEC.trace_has_bug(run_subject(subject, zero))

    trigger = zero_assignment(vars)
    trigger[Symbol(metadata["trigger_faults"][1])] = true
    trigger_trace = run_subject(subject, trigger)
    @test ConQEC.trace_has_bug(trigger_trace)
    @test earliest_divergence(trigger_trace) == "recovery"

    result = mktempdir() do witness_dir
        run_concolic_subject(
            subject;
            max_tests=8,
            max_fault_weight=1,
            solver=BruteForceBoolSolver(vars; max_weight=1),
            witness_dir=witness_dir,
            stop_on_bug=true,
            minimize_witnesses=false,
        )
    end
    @test result.bug_found

    for (bug_mode, divergence, verdict_key) in (
        (:syndrome_extraction_wiring, "syndrome", "syndrome_mismatch"),
        (:measurement_result_misuse, "measurement_result", "measurement_misuse"),
    )
        six_class_subject = PublicRepoQECCSubject(
            "public_tesseract_$(bug_mode)_smoke";
            repo_name="Tesseract",
            repo_url="https://github.com/quantumlib/tesseract-decoder",
            repo_commit="04b3d49",
            source_path="testdata/smoke/r=3,d=3,p=0.001,noise=SI1000,c=memory,q=17.stim",
            source_lines="entire .stim testdata file",
            source_motif="six-class public Tesseract smoke",
            code_kind=:stim_detector,
            bug_mode=bug_mode,
            qubits=17,
            rounds=3,
            public_arms=12,
            neutral_decoys=4,
            trigger_index=10,
            wrong_index=3,
            budget=8,
            tesseract_family="smoke",
            arm_branch_mode=:expanded_detector_arms,
            priority_arm_policy="observable_tail",
            priority_arm_indices=[10, 11, 12],
            trigger_selection_policy="priority_arm_hash",
            bug_assignment_policy="six_class_hash_balanced",
        )
        metadata = public_repo_subject_metadata(six_class_subject)
        @test metadata["bug_assignment_policy"] == "six_class_hash_balanced"
        vars = subject_fault_vars(six_class_subject)
        trigger = zero_assignment(vars)
        trigger[Symbol(metadata["trigger_faults"][1])] = true
        trigger_trace = run_subject(six_class_subject, trigger)
        @test ConQEC.trace_has_bug(trigger_trace)
        @test earliest_divergence(trigger_trace) == divergence
        @test trigger_trace.logical_verdicts[verdict_key] == true
    end
end
