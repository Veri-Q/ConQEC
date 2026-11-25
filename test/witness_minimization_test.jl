if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

function synthetic_minimization_runner(input)
    vars = [:x1, :x2, :x3]
    model = normalize_assignment(vars, input)
    trace = ConcolicTrace(
        "synthetic_minimization";
        fault_vars=vars,
        fault_assignments=model,
    )
    record_branch!(
        trace,
        "fault:x1_active",
        :fault,
        boolvar(:x1),
        model[:x1];
        description="synthetic bug is controlled only by x1",
    )
    record_logical_verdict!(trace, "oracle_verdict", !model[:x1])
    record_logical_verdict!(trace, "logical_mismatch", model[:x1])
    model[:x1] && (trace.metadata["earliest_divergence_stage"] = "logical_check")
    return trace
end

function non_greedy_minimization_runner(input)
    vars = [:a, :b, :c]
    model = normalize_assignment(vars, input)
    trace = ConcolicTrace(
        "synthetic_non_greedy_minimization";
        fault_vars=vars,
        fault_assignments=model,
    )
    fails = (model[:a] && model[:b]) || model[:c]
    record_logical_verdict!(trace, "oracle_verdict", !fails)
    record_logical_verdict!(trace, "logical_mismatch", fails)
    fails && (trace.metadata["earliest_divergence_stage"] = "logical_check")
    return trace
end

function synthetic_o5_minimization_runner(input)
    vars = [:r1, :r2]
    model = normalize_assignment(vars, input)
    trace = ConcolicTrace(
        "synthetic_o5_minimization";
        fault_vars=vars,
        fault_assignments=model,
    )
    fails = model[:r1] || model[:r2]
    record_logical_verdict!(trace, "oracle_verdict", !fails)
    record_logical_verdict!(trace, "inconsistent_control", fails)
    fails && (trace.metadata["earliest_divergence_stage"] = "recovery")
    return trace
end

@testset "witness minimization" begin
    original = synthetic_minimization_runner(Dict(:x1 => true, :x2 => true, :x3 => false))
    witness, minimized_trace = minimize_witness(original, synthetic_minimization_runner)

    @test fault_weight(original) == 2
    @test fault_weight(minimized_trace) == 1
    @test active_fault_vars(minimized_trace) == [:x1]
    @test witness["oracle_verdict"] == false
    @test witness["earliest_divergence_stage"] == "logical_check"
    @test witness["minimization"]["original_fault_weight"] == 2
    @test witness["minimization"]["minimized_fault_weight"] == 1
    @test witness["minimization"]["removed_fault_variables"] == ["x2"]
    @test witness["minimization"]["added_fault_variables"] == []
    @test witness["minimization"]["changed_fault_variables"] == ["x2"]
    @test witness["minimization"]["preserved_earliest_divergence"] == true

    non_greedy_original = non_greedy_minimization_runner(
        Dict(:a => true, :b => true, :c => false),
    )
    @test non_greedy_minimization_runner(
        Dict(:a => false, :b => true, :c => false),
    ).logical_verdicts["oracle_verdict"]
    @test non_greedy_minimization_runner(
        Dict(:a => true, :b => false, :c => false),
    ).logical_verdicts["oracle_verdict"]

    non_greedy_witness, non_greedy_trace =
        minimize_witness(non_greedy_original, non_greedy_minimization_runner)

    @test fault_weight(non_greedy_original) == 2
    @test fault_weight(non_greedy_trace) == 1
    @test active_fault_vars(non_greedy_trace) == [:c]
    @test non_greedy_witness["oracle_verdict"] == false
    @test non_greedy_witness["minimization"]["strategy"] == "bounded_fault_weight_search"
    @test non_greedy_witness["minimization"]["removed_fault_variables"] == ["a", "b"]
    @test non_greedy_witness["minimization"]["added_fault_variables"] == ["c"]
    @test non_greedy_witness["minimization"]["changed_fault_variables"] == ["a", "b", "c"]
    @test non_greedy_witness["minimization"]["preserved_earliest_divergence"] == true

    o5_original = synthetic_o5_minimization_runner(Dict(:r1 => true, :r2 => true))
    o5_witness, o5_trace = minimize_witness(
        o5_original,
        synthetic_o5_minimization_runner;
        primary_oracle="O5_INCONSISTENT_CONTROL",
    )
    @test o5_trace === o5_original
    @test fault_weight(o5_trace) == 2
    @test o5_witness["minimization"]["strategy"] == "relational_oracle_noop"

    subject = BitFlipSubject(:buggy_decoder)
    result = run_concolic(
        input -> run_bitflip_subject(subject, input),
        bitflip_fault_vars();
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test result.bug_found
    @test haskey(result.witness, "minimization")
    @test result.witness["minimization"]["original_fault_weight"] == 1
    @test result.witness["minimization"]["minimized_fault_weight"] == 1
end
