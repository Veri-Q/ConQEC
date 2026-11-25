if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

has_recovery_path_branch(trace) =
    any(guard -> guard.stage == :recovery && guard.path_constraint, trace.branch_guards)

function run_toy_subject(input)
    fault_vars = [:x1]
    model = normalize_assignment(fault_vars, input)
    x1 = model[:x1]
    x1_expr = boolvar(:x1)

    trace = ConcolicTrace(
        "toy_subject";
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=Dict{String,Any}("subject_family" => "toy"),
    )
    record_branch!(
        trace,
        "toy:x1",
        :decoder,
        x1_expr,
        x1;
        description="toy branch over x1",
    )
    record_syndrome!(trace, "x1", x1, x1_expr)
    record_logical_verdict!(trace, "oracle_verdict", !x1)
    record_logical_verdict!(trace, "decoder_mismatch", x1)
    x1 && (trace.metadata["earliest_divergence_stage"] = "decoder")
    return trace
end

@testset "subject interface for BitFlipSubject" begin
    clean = BitFlipSubject(:clean)
    @test subject_name(clean) == "bitflip_clean"
    @test subject_fault_vars(clean) == [:x1, :x2, :x3]
    @test subject_metadata(clean)["mode"] == "clean"

    clean_trace = run_subject(
        clean,
        Dict("x1" => true, "x2" => false, "x3" => false),
    )
    @test clean_trace.fault_assignments[:x1]
    @test clean_trace.decoder_decisions["actual"] == "q1"
    @test clean_trace.logical_verdicts["oracle_verdict"]
    @test has_recovery_path_branch(clean_trace)

    clean_result = run_concolic_subject(
        clean;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test !clean_result.bug_found
    @test clean_result.generated_tests == 4

    buggy = BitFlipSubject(:buggy_decoder)
    buggy_trace = run_subject(
        buggy,
        Dict("x1" => true, "x2" => false, "x3" => false),
    )
    @test buggy_trace.decoder_decisions["actual"] == "q2"
    @test buggy_trace.decoder_decisions["expected"] == "q1"
    @test !buggy_trace.logical_verdicts["oracle_verdict"]
    @test has_recovery_path_branch(buggy_trace)

    buggy_result = run_concolic_subject(
        buggy;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test buggy_result.bug_found
    @test buggy_result.generated_tests == 2
    @test buggy_result.witness["earliest_divergence_stage"] == "decoder"
end

@testset "subject interface for RepetitionSubject" begin
    subject = RepetitionSubject(5, :decoder_neighbor_bug)

    @test subject_name(subject) == "repetition_d5_decoder_neighbor_bug"
    @test subject_fault_vars(subject) == [:x1, :x2, :x3, :x4, :x5]
    @test subject_metadata(subject)["distance"] == 5

    trace = run_subject(
        subject,
        Dict("x1" => true, "x2" => false, "x3" => false, "x4" => false, "x5" => false),
    )
    @test trace.decoder_decisions["actual"] == "q2"
    @test trace.decoder_decisions["expected"] == "q1"
    @test has_recovery_path_branch(trace)

    result = run_concolic_subject(
        subject;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test result.bug_found
    @test result.generated_tests == 2
    @test result.witness["earliest_divergence_stage"] == "decoder"
end

@testset "subject interface for PhaseFlipSubject" begin
    subject = PhaseFlipSubject(:buggy_decoder)

    @test subject_name(subject) == "phaseflip_buggy_decoder_table"
    @test subject_fault_vars(subject) == [:z1, :z2, :z3]
    @test subject_metadata(subject)["subject_family"] == "three_qubit_phaseflip"
    @test subject_metadata(subject)["css_orientation"] ==
        "X-check repetition syndrome for Z data faults"

    trace = run_subject(
        subject,
        Dict("z1" => true, "z2" => false, "z3" => false),
    )
    @test trace.decoder_decisions["actual"] == "q2"
    @test trace.decoder_decisions["expected"] == "q1"
    @test !trace.logical_verdicts["oracle_verdict"]
    @test has_recovery_path_branch(trace)

    result = run_concolic_subject(
        subject;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test result.bug_found
    @test result.generated_tests == 2
    @test result.witness["earliest_divergence_stage"] == "decoder"
end

@testset "subject interface for SteaneSubject" begin
    subject = SteaneSubject(:buggy_decoder)

    @test subject_name(subject) == "steane_css_buggy_decoder_table"
    @test subject_fault_vars(subject) == steane_fault_vars()
    @test subject_metadata(subject)["subject_family"] == "steane_css_code"
    @test subject_metadata(subject)["css_orientation"] ==
        "six CSS checks: Z checks decode X faults; X checks decode Z faults"

    trace = run_subject(
        subject,
        Dict(
            "x1" => true,
            "x2" => false,
            "x3" => false,
            "x4" => false,
            "x5" => false,
            "x6" => false,
            "x7" => false,
        ),
    )
    @test trace.decoder_decisions["syndrome"] == "X=100;Z=000"
    @test trace.decoder_decisions["actual"] == "q2"
    @test trace.decoder_decisions["expected"] == "q1"
    @test !trace.logical_verdicts["oracle_verdict"]
    @test has_recovery_path_branch(trace)

    result = run_concolic_subject(
        subject;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test result.bug_found
    @test result.generated_tests == 2
    @test result.witness["earliest_divergence_stage"] == "decoder"
end

@testset "subject interface for SurfaceSubject" begin
    subject = SurfaceSubject(:buggy_decoder)

    @test subject_name(subject) == "surface_d3_x_memory_buggy_decoder_table"
    @test subject_fault_vars(subject) == surface_fault_vars()
    @test subject_metadata(subject)["subject_family"] == "surface_code_kernel"
    @test subject_metadata(subject)["code"] == "distance-3 surface-code CSS patch kernel"

    trace = run_subject(
        subject,
        Dict(
            "x1" => true,
            "x2" => false,
            "x3" => false,
            "x4" => false,
            "x5" => false,
            "x6" => false,
            "x7" => false,
            "x8" => false,
            "x9" => false,
        ),
    )
    @test trace.decoder_decisions["syndrome"] == "X=1000;Z=0000"
    @test trace.decoder_decisions["actual"] == "q2"
    @test trace.decoder_decisions["expected"] == "q1"
    @test !trace.logical_verdicts["oracle_verdict"]
    @test has_recovery_path_branch(trace)

    result = run_concolic_subject(
        subject;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test result.bug_found
    @test result.generated_tests == 2
    @test result.witness["earliest_divergence_stage"] == "decoder"
end

@testset "subject interface for RoundRepetitionSubject" begin
    subject = RoundRepetitionSubject(3, 2, :history_drop_bug)

    @test subject_name(subject) == "round_repetition_d3_r2_history_drop_bug"
    @test subject_fault_vars(subject) == [
        :x_r1_q1,
        :x_r1_q2,
        :x_r1_q3,
        :x_r2_q1,
        :x_r2_q2,
        :x_r2_q3,
    ]
    @test subject_metadata(subject)["subject_family"] == "round_repetition_code"
    @test subject_metadata(subject)["rounds"] == 2

    trace = run_subject(
        subject,
        Dict(
            "x_r1_q1" => true,
            "x_r1_q2" => false,
            "x_r1_q3" => false,
            "x_r2_q1" => false,
            "x_r2_q2" => false,
            "x_r2_q3" => false,
        ),
    )
    @test trace.decoder_decisions["observed_history"] == "10|10"
    @test trace.decoder_decisions["decoder_history_used"] == "00|10"
    @test trace.decoder_decisions["actual"] == "r2_q1"
    @test trace.decoder_decisions["expected"] == "r1_q1"
    @test has_recovery_path_branch(trace)

    result = run_concolic_subject(
        subject;
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test result.bug_found
    @test result.generated_tests == 2
    @test result.witness["earliest_divergence_stage"] == "repeated_round_control"
end

@testset "ConcolicSubjectSpec wrapper" begin
    spec = ConcolicSubjectSpec(
        "toy_subject",
        ["x1"],
        run_toy_subject;
        metadata=Dict(:subject_family => "toy"),
    )

    @test subject_name(spec) == "toy_subject"
    @test subject_fault_vars(spec) == [:x1]
    @test subject_metadata(spec)["subject_family"] == "toy"

    trace = run_subject(spec, Dict("x1" => true))
    @test trace.fault_assignments[:x1]
    @test !trace.logical_verdicts["oracle_verdict"]

    result = run_concolic_subject(
        spec;
        max_tests=4,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )
    @test result.bug_found
    @test result.generated_tests == 2
    @test result.witness["subject_name"] == "toy_subject"
    @test result.witness["earliest_divergence_stage"] == "decoder"
end
