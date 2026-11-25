if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "Solver-chain dependency slicing soundness" begin
    vars = [:x1, :x2, :x3, :x4]
    query = normalize_query(
        [boolvar(:x1), bnot(boolvar(:x2)), bor(boolvar(:x4), bnot(boolvar(:x4)))],
        vars;
        target_expr_vars=[:x1],
        max_fault_weight=4,
        construct_cache=false,
    )
    sliced = slice_query(query)
    @test sliced.dropped_constraint_count >= 1
    @test :x1 in sliced.fault_vars
    @test all(v -> v != :x2, sliced.fault_vars)
    @test all(v -> v != :x3, sliced.fault_vars)
    @test all(v -> v != :x4, sliced.fault_vars)

    full_solver = BruteForceBoolSolver(vars; max_weight=4)
    full_result = solve_model(full_solver, query.constraints)
    @test full_result.status == :sat

    sliced_solver = BruteForceBoolSolver(sliced.fault_vars; max_weight=4)
    sliced_result = solve_model(sliced_solver, sliced.constraints)
    @test sliced_result.status == :sat
    @test validate_model(query, sliced_result.model)

    chain = SolverChainBackend(
        BruteForceBoolSolver(vars; max_weight=4);
        mode=:transparent,
        slicing=true,
        cache=true,
        presolve=false,
        validate_model=true,
    )
    chain_result = solve_model(
        chain,
        [boolvar(:x1), bnot(boolvar(:x2)), bor(boolvar(:x4), bnot(boolvar(:x4)))],
    )
    @test chain_result.status == full_result.status
    @test chain_result.metadata["slice_ratio"] <= 1.0
    @test chain_result.metadata["slice_ratio"] >= 0.0
end
