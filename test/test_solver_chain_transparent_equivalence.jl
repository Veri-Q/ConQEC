if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "Transparent mode equivalence checks" begin
    vars = [:x1, :x2, :x3, :x4]
    constraints_batches = [
        [boolvar(:x1), bxor(boolvar(:x2), boolvar(:x3))],
        [bor(boolvar(:x1), bnot(boolvar(:x2)), boolvar(:x4))],
        [bnot(boolvar(:x1)), beq(boolvar(:x2), boolvar(:x3))],
        [bxor(boolvar(:x1), boolvar(:x2)), bnot(boolvar(:x4))],
    ]

    baseline_solver = BruteForceBoolSolver(vars; max_weight=2)
    chain_solver = SolverChainBackend(
        BruteForceBoolSolver(vars; max_weight=2);
        mode=:transparent,
        slicing=true,
        cache=true,
        cache_mode=:validated,
        presolve=true,
        validate_model=true,
        construct_cache=true,
    )

    for constraints in constraints_batches
        baseline = solve_model(baseline_solver, constraints)
        optimized = solve_model(chain_solver, constraints)
        @test baseline.status == optimized.status
        @test optimized.metadata["solver_chain"] == "on"
        if baseline.status == :sat
            normalized = normalize_query(constraints, vars; construct_cache=false, max_fault_weight=2)
            @test validate_model(normalized, optimized.model)
        end
    end

    @test solver_chain_cache_stats(chain_solver)["cache_hits"] >= 0

    for subject in (:clean, :buggy_decoder)
        baseline_subject = run_concolic_subject(
            BitFlipSubject(subject);
            max_tests=3,
            solver=BruteForceBoolSolver(bitflip_fault_vars(); max_weight=1),
            witness_dir=mktempdir(),
            stop_on_bug=true,
        )
        chain_subject = run_concolic_subject(
            BitFlipSubject(subject);
            max_tests=3,
            solver=SolverChainBackend(
                BruteForceBoolSolver(bitflip_fault_vars(); max_weight=1);
                mode=:transparent,
                slicing=true,
                cache=true,
                presolve=true,
                validate_model=true,
            ),
            witness_dir=mktempdir(),
            stop_on_bug=true,
        )
        @test baseline_subject.bug_found == chain_subject.bug_found
        if baseline_subject.bug_found
            @test baseline_subject.witness["earliest_divergence_stage"] ==
                chain_subject.witness["earliest_divergence_stage"]
        end
    end
end
