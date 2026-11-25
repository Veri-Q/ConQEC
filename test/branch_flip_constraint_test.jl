if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "branch-flip constraint construction" begin
    subject = BitFlipSubject(:clean)
    vars = bitflip_fault_vars()
    zero = zero_assignment(vars)
    trace = run_bitflip_subject(subject, zero)

    @test length(trace.branch_guards) >= 1
    @test trace.branch_guards[1].id == "decoder:syndrome_00"
    @test trace.branch_guards[1].taken
    @test trace.branch_guards[1].path_constraint
    @test !trace.branch_guards[2].path_constraint

    constraints = flipped_path_constraint(trace, 1)
    solver = BruteForceBoolSolver(vars; max_weight=1)
    avoid = Set([assignment_key(vars, zero)])
    model = solve(solver, constraints; avoid=avoid)

    @test model !== nothing
    @test model[:x1]
    @test !model[:x2]
    @test !model[:x3]

    x2 = zero_assignment(vars)
    x2[:x2] = true
    x2_trace = run_bitflip_subject(subject, x2)
    @test x2_trace.branch_guards[2].id == "decoder:syndrome_10"
    @test !x2_trace.branch_guards[2].taken
    @test x2_trace.branch_guards[3].id == "decoder:syndrome_11"
    @test x2_trace.branch_guards[3].taken
    control_group_constraints = full_flipped_path_constraint(x2_trace, 2)
    @test length(control_group_constraints) == 2
    sibling_model = solve(
        solver,
        control_group_constraints;
        avoid=Set([assignment_key(vars, zero), assignment_key(vars, x2)]),
    )
    @test sibling_model == Dict(:x1 => true, :x2 => false, :x3 => false)

    synthetic = ConcolicTrace(
        "synthetic_full_path";
        fault_vars=vars,
        fault_assignments=Dict(:x1 => false, :x2 => false, :x3 => true),
        metadata=Dict("max_fault_weight" => 1),
    )
    record_branch!(synthetic, "b1", :fault, boolvar(:x1), false)
    record_branch!(synthetic, "b2", :decoder, boolvar(:x2), false)
    record_branch!(synthetic, "b3", :recovery, boolvar(:x3), true)

    prefix_constraints = flipped_path_constraint(synthetic, 2)
    full_constraints = full_flipped_path_constraint(synthetic, 2)
    full_query_constraints = branch_query_constraints(synthetic, 2)

    @test length(prefix_constraints) == 2
    @test length(full_constraints) == 3
    @test length(full_query_constraints) == 4
    @test all(expr -> evaluate(expr, Dict(:x1 => false, :x2 => true, :x3 => true)),
        prefix_constraints)
    @test all(expr -> evaluate(expr, Dict(:x1 => false, :x2 => true, :x3 => true)),
        full_constraints)
    @test all(expr -> evaluate(expr, Dict(:x1 => false, :x2 => true, :x3 => false)),
        prefix_constraints)
    @test !all(expr -> evaluate(expr, Dict(:x1 => false, :x2 => true, :x3 => false)),
        full_constraints)
    @test !all(expr -> evaluate(expr, Dict(:x1 => false, :x2 => true, :x3 => true)),
        full_query_constraints)

    guarded = ConcolicTrace(
        "semantic_guard_api";
        fault_vars=vars,
        fault_assignments=Dict(:x1 => false, :x2 => false, :x3 => false),
    )
    record_semantic_guard!(guarded, "decoder:public_guard", :decoder, boolvar(:x1), false)
    record_oracle_check!(guarded, "logical:oracle_check", bconst(true), true)
    @test guarded.branch_guards[end - 1].path_constraint
    @test guarded.branch_guards[end - 1].flippable
    @test guarded.branch_guards[end - 1].source == :semantic
    @test !guarded.branch_guards[end].path_constraint
    @test !guarded.branch_guards[end].flippable
    @test guarded.branch_guards[end].diagnostic_only
    @test guarded.branch_guards[end].source == :oracle
    @test_throws ErrorException record_branch!(
        guarded,
        "logical:oracle_as_path",
        :logical_check,
        bconst(true),
        true;
        path_constraint=true,
        source=:oracle,
    )
    @test_throws ErrorException record_semantic_guard!(
        guarded,
        "decoder:target_leak",
        :decoder,
        boolvar(:x1),
        false,
    )
    @test_throws ErrorException record_semantic_guard!(
        guarded,
        "decoder:foreign_var",
        :decoder,
        boolvar(:outside),
        false,
    )
end
