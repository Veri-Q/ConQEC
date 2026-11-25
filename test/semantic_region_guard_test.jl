function semantic_region_test_assignment(fault_vars, active)
    active_set = Set(Int.(active))
    return Dict{Symbol,Bool}(
        var => (idx in active_set)
        for (idx, var) in enumerate(fault_vars)
    )
end

@testset "semantic region observable guards" begin
    dem = """
    error(0.01) D0 L0
    error(0.02) D1
    error(0.03) D2 L1
    error(0.04) D0 D2 L0 L1
    """
    model = parse_dem_text(
        dem;
        source_path="testdata/colorcodes/r=1,d=3,p=0.01,noise=x,c=test,q=7,gates=test.dem",
    )

    guard = ObservableRegionGuard("10")
    @test canonical_region_id(model, guard) == "observable_key:10"
    @test guard_kind(guard) == :observable_exact
    @test scheduler_visible_metadata(model, guard)["scheduler_visible_target_metadata"] == false
    @test scheduler_visible_metadata(model, guard)["scheduler_visible_oracle_region_metadata"] == false
    @test !haskey(scheduler_visible_metadata(model, guard), "oracle_region_key")
    @test :dem_f1 in guard_dependencies(model, guard)

    assignment = semantic_region_test_assignment(dem_fault_vars(model), [1])
    @test evaluate(guard_expr(model, guard), assignment)
    @test !evaluate(guard_expr(model, guard), semantic_region_test_assignment(dem_fault_vars(model), [2]))

    unseen = NewObservableGuard(["00", "10"])
    @test guard_kind(unseen) == :observable_unseen
    @test !evaluate(guard_expr(model, unseen), semantic_region_test_assignment(dem_fault_vars(model), [1]))
    @test evaluate(guard_expr(model, unseen), semantic_region_test_assignment(dem_fault_vars(model), [3]))

    sw = SyndromeWeightGuard(1, 2)
    @test evaluate(guard_expr(model, sw), semantic_region_test_assignment(dem_fault_vars(model), [1]))
    @test !evaluate(guard_expr(model, SyndromeWeightGuard(2, 2)), semantic_region_test_assignment(dem_fault_vars(model), [1]))

    rw = RoundWeightGuard(:initial, 1, nothing)
    @test evaluate(guard_expr(model, rw), semantic_region_test_assignment(dem_fault_vars(model), [1]))

    boundary = BoundaryGuard([0], true)
    @test evaluate(guard_expr(model, boundary), semantic_region_test_assignment(dem_fault_vars(model), [1]))
    bulk = BoundaryGuard([0], false)
    @test !evaluate(guard_expr(model, bulk), semantic_region_test_assignment(dem_fault_vars(model), [1]))

    compound = CompoundGuard(SemanticRegionGuard[ObservableRegionGuard("10"), BoundaryGuard([0], true)])
    @test evaluate(guard_expr(model, compound), semantic_region_test_assignment(dem_fault_vars(model), [1]))
    reordered = CompoundGuard(SemanticRegionGuard[BoundaryGuard([0], true), ObservableRegionGuard("10")])
    @test canonical_region_id(model, compound) == canonical_region_id(model, reordered)
end

@testset "semantic region pure query solver" begin
    dem = """
    error(0.01) D0 L0
    error(0.02) D1 L1
    error(0.03) D2 L0 L1
    """
    model = parse_dem_text(
        dem;
        source_path="testdata/colorcodes/r=1,d=3,p=0.01,noise=x,c=test,q=7,gates=test.dem",
    )
    vars = dem_fault_vars(model)

    query = build_pure_region_query(model, ObservableRegionGuard("11"); max_fault_weight=1)
    result = solve_semantic_region_query(
        LocalEnumeratorBackend(vars; max_weight=1),
        model,
        query,
    )
    @test result.status == :sat
    @test result.active_faults == [3]
    @test dem_parity_key(dem_logical_bits(model, result.active_faults)) == "11"
    @test result.metadata["query_mode"] == "pure_region"
    @test result.metadata["scheduler_visible_target_metadata"] == false

    # Exact observable generation at weight 2 uses observable-key pairing, not
    # a full pair-list materialization.
    pair_query = build_pure_region_query(model, ObservableRegionGuard("00"); max_fault_weight=2)
    pair_result = solve_semantic_region_query(
        LocalEnumeratorBackend(vars; max_weight=2),
        model,
        pair_query,
    )
    @test pair_result.status == :sat
    @test length(pair_result.active_faults) <= 2
    @test dem_parity_key(dem_logical_bits(model, pair_result.active_faults)) == "00"
    @test pair_result.solver_backend == "direct-gf2-observable"

    seen = NewObservableGuard(["10"])
    seen_query = build_pure_region_query(model, seen; max_fault_weight=1)
    seen_result = solve_semantic_region_query(
        LocalEnumeratorBackend(vars; max_weight=1),
        model,
        seen_query,
    )
    @test seen_result.status == :sat
    @test dem_parity_key(dem_logical_bits(model, seen_result.active_faults)) != "10"

    avoided_assignment = assignment_key(vars, semantic_region_test_assignment(vars, seen_result.active_faults))
    avoid_query = build_pure_region_query(model, seen; max_fault_weight=1, avoid=Set([avoided_assignment]))
    avoid_result = solve_semantic_region_query(
        LocalEnumeratorBackend(vars; max_weight=1),
        model,
        avoid_query,
    )
    @test avoid_result.status == :sat
    @test assignment_key(vars, avoid_result.model) != avoided_assignment
end

@testset "semantic region new-observable grouped weight-2 synthesis" begin
    dem = """
    error(0.01) D0 L0
    error(0.02) D1 L1
    error(0.03) D2
    """
    model = parse_dem_text(
        dem;
        source_path="testdata/colorcodes/r=1,d=3,p=0.01,noise=x,c=test,q=7,gates=test.dem",
    )
    vars = dem_fault_vars(model)
    query = build_pure_region_query(
        model,
        NewObservableGuard(["00", "10", "01"]);
        max_fault_weight=2,
    )
    result = solve_semantic_region_query(
        LocalEnumeratorBackend(vars; max_weight=2),
        model,
        query,
    )
    @test result.status == :sat
    @test result.solver_backend == "direct-gf2-observable"
    @test dem_parity_key(dem_logical_bits(model, result.active_faults)) == "11"
    @test length(result.active_faults) == 2
end
