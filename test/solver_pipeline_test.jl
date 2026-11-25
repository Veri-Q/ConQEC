if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "Solver pipeline normalization and cache" begin
    vars = [:x1, :x2, :x3]
    q1 = normalize_query(
        [boolvar(:x1), bxor(boolvar(:x2), boolvar(:x3))],
        vars;
        max_fault_weight=1,
    )
    q2 = normalize_query(
        [bxor(boolvar(:x3), boolvar(:x2)), boolvar(:x1)],
        vars;
        max_fault_weight=1,
    )
    @test q1.hashes["full_query_hash"] == q2.hashes["full_query_hash"]

    q3 = normalize_query(
        [boolvar(:x1), bxor(boolvar(:x2), boolvar(:x3))],
        vars;
        avoid=Set(["x1=1;x2=0;x3=0"]),
        max_fault_weight=1,
    )
    @test q1.hashes["full_query_hash"] != q3.hashes["full_query_hash"]

    simplified = normalize_query(
        [bxor(boolvar(:x1), boolvar(:x1)), boolvar(:x2), boolvar(:x2)],
        vars,
    )
    @test simplified.canonical_constraints == ["const:false", "var:x2"]

    target = normalize_query(
        [boolvar(:x1), boolvar(:x2)],
        vars;
        target_expr_vars=[:x1],
        max_fault_weight=1,
    )
    sliced = slice_query(target)
    @test sliced.dropped_constraint_count == 1
    @test length(sliced.constraints) == 1
    @test sliced.fault_vars == [:x1]

    chain = SolverChainBackend(
        BruteForceBoolSolver(vars; max_weight=1);
        slicing=true,
        cache=true,
        cache_mode=:exact,
        presolve=true,
    )
    result = solve_model(chain, [boolvar(:x1)])
    @test result.status == :sat
    @test result.model[:x1]
    @test result.metadata["solver_chain"] == "on"
    @test result.metadata["cache_mode"] == "exact"
    @test result.metadata["presolver_status"] == "SAT"
    @test validate_model(normalize_query([boolvar(:x1)], vars; max_fault_weight=1), result.model)

    cached = solve_model(chain, [boolvar(:x1)])
    @test cached.status == :sat
    @test cached.metadata["cache_hit"] == true
    @test cached.metadata["cache_hit_kind"] == "exact"
    @test solver_chain_cache_stats(chain)["exact_hits"] >= 1
end

@testset "Solver pipeline preserves exploration semantics" begin
    subject = BitFlipSubject(:buggy_decoder)
    baseline = run_concolic_subject(
        subject;
        max_tests=4,
        solver=BruteForceBoolSolver(bitflip_fault_vars(); max_weight=1),
        witness_dir=mktempdir(),
        stop_on_bug=true,
    )
    optimized = run_concolic_subject(
        subject;
        max_tests=4,
        solver=SolverChainBackend(
            BruteForceBoolSolver(bitflip_fault_vars(); max_weight=1);
            slicing=true,
            cache=true,
            presolve=true,
        ),
        witness_dir=mktempdir(),
        stop_on_bug=true,
    )
    @test optimized.bug_found == baseline.bug_found
    @test optimized.witness["earliest_divergence_stage"] ==
        baseline.witness["earliest_divergence_stage"]
    @test !isempty(optimized.branch_query_results)
    @test any(row -> get(row, "solver_chain", "off") == "on",
        optimized.branch_query_results)

    batched = run_concolic_subject(
        BitFlipSubject(:clean);
        max_tests=1,
        solver=SolverChainBackend(BruteForceBoolSolver(bitflip_fault_vars(); max_weight=1)),
        branch_batching=true,
        max_branch_batch_size=1,
        batch_mode=:coverage,
        witness_dir=mktempdir(),
        stop_on_bug=false,
    )
    @test length(batched.branch_query_results) == 1
    @test first(batched.branch_query_results)["branch_batching"] == "on"
    @test first(batched.branch_query_results)["branch_rank"] == 1

    first_successor = run_concolic_subject(
        BitFlipSubject(:clean);
        max_tests=2,
        solver=SolverChainBackend(BruteForceBoolSolver(bitflip_fault_vars(); max_weight=1)),
        first_new_successor=true,
        witness_dir=mktempdir(),
        stop_on_bug=false,
    )
    @test !isempty(first_successor.branch_query_results)
    @test first(first_successor.branch_query_results)["first_new_successor"] == "on"

    parallel = run_concolic_subject(
        BitFlipSubject(:clean);
        max_tests=2,
        solver=BruteForceBoolSolver(bitflip_fault_vars(); max_weight=1),
        parallel_branches=true,
        parallel_branch_jobs=2,
        witness_dir=mktempdir(),
        stop_on_bug=false,
    )
    @test !isempty(parallel.branch_query_results)
    @test any(
        row -> get(row, "parallel_branch_query", "off") in
            ("on", "sequential-retry"),
        parallel.branch_query_results,
    )
    @test all(
        row -> get(row, "parallel_branch_jobs", 0) == 2,
        filter(row -> get(row, "parallel_branch_query", "off") in
            ("on", "sequential-retry"), parallel.branch_query_results),
    )
end
