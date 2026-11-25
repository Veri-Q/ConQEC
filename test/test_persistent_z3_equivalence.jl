if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "Persistent Z3 equivalence" begin
    Sys.which("z3") === nothing && begin
        @test true
        return
    end

    vars = [:x1, :x2, :x3]
    constraints = [bxor(boolvar(:x1), boolvar(:x2)), bnot(boolvar(:x3))]

    direct = solve_model(Z3Backend(vars; solver_path="z3", timeout_ms=30000), constraints)

    non_persistent_solver = SolverChainBackend(
        Z3Backend(vars; solver_path="z3", timeout_ms=30000);
        mode=:transparent,
        incremental=false,
        normalization=false,
        slicing=false,
        cache=false,
        presolve=false,
        construct_cache=false,
        validate_model=false,
    )
    non_persistent = solve_model(non_persistent_solver, constraints)

    persistent_solver = SolverChainBackend(
        Z3Backend(vars; solver_path="z3", timeout_ms=30000);
        mode=:transparent,
        incremental=true,
        normalization=false,
        slicing=false,
        cache=false,
        presolve=false,
        construct_cache=false,
        validate_model=false,
    )
    persistent = solve_model(persistent_solver, constraints)

    @test direct.status == non_persistent.status
    @test direct.status == persistent.status
    @test persistent_solver.base isa PersistentZ3Backend
    @test ConQEC.is_persistent_z3_backend(persistent_solver.base)

    if persistent.status == :sat
        @test haskey(persistent.model, :x1)
    end

    stats = ConQEC.persistent_z3_metadata(persistent_solver.base)
    @test stats["backend_type"] == "persistent-z3"
    @test stats["schema_version"] == ConQEC.SOLVER_CHAIN_PERSISTENT_Z3_VERSION
    @test get(stats, "persistent_query_count", 0) >= 1
end
