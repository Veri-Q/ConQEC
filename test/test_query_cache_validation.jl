if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "Solver-chain cache validation" begin
    vars = [:x1, :x2, :x3]
    chain = SolverChainBackend(
        BruteForceBoolSolver(vars; max_weight=2);
        mode=:transparent,
        normalization=true,
        slicing=false,
        cache=true,
        cache_mode=:validated,
        presolve=false,
        incremental=false,
        validate_model=true,
        construct_cache=false,
    )

    baseline = solve_model(chain, [bxor(boolvar(:x1), boolvar(:x2)), boolvar(:x3)])
    repeated = solve_model(chain, [bxor(boolvar(:x1), boolvar(:x2)), boolvar(:x3)])
    @test baseline.status == repeated.status == :sat
    @test repeated.metadata["cache_hit"] == true
    @test repeated.metadata["cache_hit_kind"] == "exact"
    @test solver_chain_cache_stats(chain)["exact_hits"] >= 1

    unsat = solve_model(chain, [boolvar(:x1), bnot(boolvar(:x1))])
    unsat_repeat = solve_model(chain, [boolvar(:x1), bnot(boolvar(:x1))])
    @test unsat.status == :unsat
    @test unsat_repeat.status == :unsat
    @test unsat_repeat.metadata["cache_hit"] == true

    snapshot = ConQEC.solver_chain_cache_snapshot(chain)
    @test snapshot["schema_version"] == ConQEC.SOLVER_CHAIN_SCHEMA_VERSION
    @test snapshot["counters"]["version"] == ConQEC.SOLVER_CHAIN_QUERY_CACHE_VERSION
    @test haskey(snapshot["counters"], "cache_hits")
    @test snapshot["counters"]["cache_hits"] >= 1

    ConQEC.solver_chain_cache_clear!(chain)
    post_clear = solver_chain_cache_stats(chain)
    @test post_clear["cache_hits"] == 0
end
