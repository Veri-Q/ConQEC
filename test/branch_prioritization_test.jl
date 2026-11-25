if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

function synthetic_syndrome_diversity_trace()
    vars = [:x1, :x2]
    trace = ConcolicTrace(
        "synthetic_syndrome_diversity";
        fault_vars=vars,
        fault_assignments=Dict(:x1 => false, :x2 => false),
    )
    record_syndrome!(trace, "a", false, boolvar(:x1))
    record_syndrome!(trace, "b", false, boolvar(:x2))
    record_branch!(
        trace,
        "syndrome:a",
        :syndrome,
        boolvar(:x1),
        false;
        description="flip a syndrome bit",
    )
    record_branch!(
        trace,
        "syndrome:b",
        :syndrome,
        boolvar(:x2),
        false;
        description="flip b syndrome bit",
    )
    return trace
end

function synthetic_failure_adjacent_trace()
    vars = [:x1, :x2]
    trace = ConcolicTrace(
        "synthetic_failure_adjacent";
        fault_vars=vars,
        fault_assignments=Dict(:x1 => false, :x2 => false),
    )
    record_branch!(
        trace,
        "fault:near_witness",
        :fault,
        boolvar(:x1),
        false;
        description="old stage ranking would place this branch last",
    )
    record_branch!(
        trace,
        "recovery:far_from_witness",
        :recovery,
        boolvar(:x2),
        false;
        description="old stage ranking would place this branch first",
    )
    return trace
end

function synthetic_failure_adjacency_ablation_trace()
    vars = [:x1, :x2]
    trace = ConcolicTrace(
        "synthetic_failure_adjacency_ablation";
        fault_vars=vars,
        fault_assignments=Dict(:x1 => false, :x2 => false),
    )
    record_branch!(
        trace,
        "fault:far_from_witness",
        :fault,
        boolvar(:x2),
        false;
        description="trace-order winner when failure-adjacent scoring is disabled",
    )
    record_branch!(
        trace,
        "fault:near_witness",
        :fault,
        boolvar(:x1),
        false;
        description="candidate closest to a previous witness",
    )
    return trace
end

function synthetic_small_fault_ablation_trace()
    vars = [:x1, :x2]
    trace = ConcolicTrace(
        "synthetic_small_fault_ablation";
        fault_vars=vars,
        fault_assignments=Dict(:x1 => false, :x2 => false),
    )
    record_branch!(
        trace,
        "fault:weight_two_candidate",
        :fault,
        band(boolvar(:x1), boolvar(:x2)),
        false;
        description="trace-order winner when small-fault scoring is disabled",
    )
    record_branch!(
        trace,
        "fault:weight_one_candidate",
        :fault,
        boolvar(:x1),
        false;
        description="lower-weight branch candidate",
    )
    return trace
end

function synthetic_w_tie_trace()
    vars = [:x1, :x2]
    trace = ConcolicTrace(
        "synthetic_w_tie";
        fault_vars=vars,
        fault_assignments=Dict(:x1 => false, :x2 => false),
    )
    record_branch!(
        trace,
        "fault:first_in_trace",
        :fault,
        boolvar(:x1),
        false;
        description="trace-order winner when W-mode metrics tie",
    )
    record_branch!(
        trace,
        "decoder:second_in_trace",
        :decoder,
        boolvar(:x2),
        false;
        description="old stage ordering would incorrectly win in W mode",
    )
    return trace
end

function synthetic_branch_trace_distance_trace()
    vars = [:x1, :x2]
    trace = ConcolicTrace(
        "synthetic_branch_trace_distance";
        fault_vars=vars,
        fault_assignments=Dict(:x1 => false, :x2 => false),
    )
    record_branch!(
        trace,
        "decoder:near_witness",
        :decoder,
        boolvar(:x1),
        false;
        description="branch-trace winner even though recovery has earlier stage priority",
    )
    record_branch!(
        trace,
        "recovery:far_from_witness",
        :recovery,
        boolvar(:x2),
        false;
        description="old stage priority would choose this branch first",
    )
    return trace
end

using Test

function synthetic_priority_trace()
    vars = [:x1, :x2]
    trace = ConcolicTrace(
        "synthetic_priority";
        fault_vars=vars,
        fault_assignments=Dict(:x1 => false, :x2 => true),
    )
    record_branch!(
        trace,
        "fault:x1",
        :fault,
        boolvar(:x1),
        false;
        description="fault gate",
    )
    record_branch!(
        trace,
        "syndrome:s12",
        :syndrome,
        boolvar(:x2),
        true;
        description="syndrome branch",
    )
    record_branch!(
        trace,
        "decoder:lookup",
        :decoder,
        boolvar(:x1),
        false;
        description="decoder branch",
    )
    record_branch!(
        trace,
        "recovery:target",
        :recovery,
        boolvar(:x2),
        true;
        description="recovery branch",
    )
    return trace
end

@testset "QECC-aware branch prioritization" begin
    trace = synthetic_priority_trace()

    @test prioritized_branch_indices(trace, :trace_order) == [1, 2, 3, 4]
    @test prioritized_branch_indices(trace, :qec_priority) == [4, 3, 2, 1]
    @test stage_priority(:recovery) < stage_priority(:decoder)
    @test stage_priority(:decoder) < stage_priority(:syndrome)
    @test branch_priority_key(trace, 4, :qec_priority) <
        branch_priority_key(trace, 1, :qec_priority)
    weights = BranchPriorityWeights(
        failure_adjacent=100,
        syndrome_diverse=10,
        small_fault=1,
    )
    @test weights.failure_adjacent > weights.syndrome_diverse > weights.small_fault
    @test branch_priority_score(1, 1, 1; weights=weights) == 111
    @test BranchPriorityWeights(failure_adjacent=0, syndrome_diverse=10, small_fault=1).failure_adjacent == 0
    @test BranchPriorityWeights(failure_adjacent=100, syndrome_diverse=0, small_fault=1).syndrome_diverse == 0
    @test BranchPriorityWeights(failure_adjacent=100, syndrome_diverse=10, small_fault=0).small_fault == 0
    @test_throws ErrorException BranchPriorityWeights(
        failure_adjacent=0,
        syndrome_diverse=0,
        small_fault=0,
    )
    @test_throws ErrorException BranchPriorityWeights(
        failure_adjacent=10,
        syndrome_diverse=10,
        small_fault=1,
    )

    diversity_trace = synthetic_syndrome_diversity_trace()
    solver = BruteForceBoolSolver([:x1, :x2]; max_weight=1)
    seen_inputs = Set([assignment_key([:x1, :x2], Dict(:x1 => false, :x2 => false))])
    seen_syndromes = Set(["a=1,b=0"])
    @test syndrome_key_for_model(diversity_trace, Dict(:x1 => false, :x2 => true)) ==
        "a=0,b=1"
    @test prioritized_branch_indices(
        diversity_trace,
        :qec_priority;
        solver=solver,
        seen_syndromes=seen_syndromes,
        seen_inputs=seen_inputs,
    ) == [2, 1]
    no_syndrome_weights = BranchPriorityWeights(
        failure_adjacent=100,
        syndrome_diverse=0,
        small_fault=1,
    )
    @test branch_priority_syndrome_rank(no_syndrome_weights, 1) == 0
    @test prioritized_branch_indices(
        diversity_trace,
        :qec_priority;
        solver=solver,
        seen_syndromes=seen_syndromes,
        seen_inputs=seen_inputs,
        priority_weights=no_syndrome_weights,
    ) == [1, 2]
    @test prioritized_branch_indices(
        diversity_trace,
        :qec_priority;
        solver=solver,
        seen_syndromes=seen_syndromes,
        seen_inputs=seen_inputs,
        witness_models=[Dict(:x1 => true, :x2 => false)],
    ) == [1, 2]

    adjacent_trace = synthetic_failure_adjacent_trace()
    adjacent_solver = BruteForceBoolSolver([:x1, :x2]; max_weight=1)
    adjacent_seen = Set([assignment_key([:x1, :x2], Dict(:x1 => false, :x2 => false))])
    witness_models = [Dict(:x1 => true, :x2 => false)]
    @test prioritized_branch_indices(
        adjacent_trace,
        :qec_priority;
        solver=adjacent_solver,
        seen_inputs=adjacent_seen,
    ) == [2, 1]
    @test model_hamming_distance(
        [:x1, :x2],
        Dict(:x1 => true, :x2 => false),
        first(witness_models),
    ) == 0
    @test witness_distance(
        [:x1, :x2],
        Dict(:x1 => false, :x2 => true),
        witness_models,
    ) == 2
    @test prioritized_branch_indices(
        adjacent_trace,
        :qec_priority;
        solver=adjacent_solver,
        seen_inputs=adjacent_seen,
        witness_models=witness_models,
    ) == [1, 2]

    failure_ablation_trace = synthetic_failure_adjacency_ablation_trace()
    no_failure_weights = BranchPriorityWeights(
        failure_adjacent=0,
        syndrome_diverse=10,
        small_fault=1,
    )
    @test prioritized_branch_indices(
        failure_ablation_trace,
        :qec_priority;
        solver=adjacent_solver,
        seen_inputs=adjacent_seen,
        witness_models=witness_models,
    ) == [2, 1]
    @test prioritized_branch_indices(
        failure_ablation_trace,
        :qec_priority;
        solver=adjacent_solver,
        seen_inputs=adjacent_seen,
        witness_models=witness_models,
        priority_weights=no_failure_weights,
    ) == [1, 2]

    small_fault_trace = synthetic_small_fault_ablation_trace()
    small_fault_solver = BruteForceBoolSolver([:x1, :x2]; max_weight=2)
    @test prioritized_branch_indices(
        small_fault_trace,
        :qec_priority;
        solver=small_fault_solver,
    ) == [2, 1]
    no_small_fault_weights = BranchPriorityWeights(
        failure_adjacent=100,
        syndrome_diverse=10,
        small_fault=0,
    )
    @test branch_priority_fault_weight_rank(no_small_fault_weights, 2) == 0
    @test prioritized_branch_indices(
        small_fault_trace,
        :qec_priority;
        solver=small_fault_solver,
        priority_weights=no_small_fault_weights,
    ) == [1, 2]

    tie_trace = synthetic_w_tie_trace()
    @test prioritized_branch_indices(
        tie_trace,
        :qec_priority;
        solver=BruteForceBoolSolver([:x1, :x2]; max_weight=1),
        seen_inputs=adjacent_seen,
        witness_models=[Dict(:x1 => false, :x2 => false)],
    ) == [1, 2]

    branch_distance_trace = synthetic_branch_trace_distance_trace()
    near_signature = Dict(
        "decoder:near_witness" => true,
    )
    @test branch_signature(branch_distance_trace) == Dict(
        "decoder:near_witness" => false,
        "recovery:far_from_witness" => false,
    )
    @test branch_signature(branch_distance_trace; branch_index=1) == Dict(
        "decoder:near_witness" => true,
        "recovery:far_from_witness" => false,
    )
    @test witness_branch_distance(branch_distance_trace, 1, [near_signature]) == 1
    @test witness_branch_distance(branch_distance_trace, 2, [near_signature]) == 2
    @test witness_branch_priority_distance(branch_distance_trace, 1, [near_signature]) == 0
    @test witness_branch_priority_distance(branch_distance_trace, 2, [near_signature]) == 1
    @test branch_trace_hamming_distance(
        Dict("decoder:near_witness" => true, "recovery:far_from_witness" => false),
        near_signature,
    ) == 1
    @test prioritized_branch_indices(
        branch_distance_trace,
        :qec_priority;
        solver=BruteForceBoolSolver([:x1, :x2]; max_weight=1),
        seen_inputs=adjacent_seen,
        witness_signatures=[near_signature],
    ) == [1, 2]

    exact_duplicate_signature = branch_signature(branch_distance_trace; branch_index=1)
    current_signature = branch_signature(branch_distance_trace)
    @test witness_branch_distance(
        branch_distance_trace,
        1,
        [exact_duplicate_signature],
    ) == 0
    @test witness_branch_distance(
        branch_distance_trace,
        2,
        [current_signature],
    ) == 1
    @test prioritized_branch_indices(
        branch_distance_trace,
        :qec_priority;
        solver=BruteForceBoolSolver([:x1, :x2]; max_weight=1),
        seen_inputs=adjacent_seen,
        witness_signatures=[exact_duplicate_signature, current_signature],
    ) == [2, 1]

    explorer = ConcolicExplorer([:x1]; branch_strategy=:trace_order)
    @test explorer.branch_strategy == :trace_order
    @test_throws ErrorException ConcolicExplorer([:x1]; branch_strategy=:unknown)

    subject = BitFlipSubject(:buggy_decoder)
    result = run_concolic(
        input -> run_bitflip_subject(subject, input),
        bitflip_fault_vars();
        max_tests=8,
        max_fault_weight=1,
        branch_strategy=:qec_priority,
        priority_weights=weights,
        witness_dir=mktempdir(),
    )
    @test result.bug_found
    @test result.witness["exploration_settings"]["branch_strategy"] == "qec_priority"
    @test result.witness["exploration_settings"]["branch_priority_weights"][
        "failure_adjacent"
    ] == 100

    priority_subject = BitFlipSubject(:priority_decoder_bug)
    priority_result = run_concolic_subject(
        priority_subject;
        max_tests=8,
        max_fault_weight=1,
        branch_strategy=:qec_priority,
        witness_dir=mktempdir(),
    )
    trace_order_result = run_concolic_subject(
        priority_subject;
        max_tests=8,
        max_fault_weight=1,
        branch_strategy=:trace_order,
        witness_dir=mktempdir(),
    )
    @test priority_result.bug_found
    @test trace_order_result.bug_found
    @test priority_result.generated_tests == 2
    @test trace_order_result.generated_tests == 4
    @test priority_result.generated_tests < trace_order_result.generated_tests
    @test priority_result.witness["decoder_output"] == "q2"
    @test priority_result.witness["expected_decoder_output"] == "q1"
end
