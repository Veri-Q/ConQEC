@testset "DEM semantic rendezvous target policy" begin
    dem = """
    error(0.01) D0 L0
    error(0.02) D1
    error(0.03) D2 L0
    error(0.04) D3
    """
    model = parse_dem_text(
        dem;
        source_path="testdata/colorcodes/r=2,d=5,p=0.01,noise=x,c=test,q=11,gates=test.dem",
    )
    table = dem_reference_decoder_table(model)
    states = dem_weight1_semantic_states(
        model,
        table;
        policy_version=DEM_RENDEZVOUS_TARGET_POLICY_VERSION,
    )
    @test length(states) >= 3

    forward = dem_select_semantic_target_rendezvous(
        model,
        table,
        :syndrome_extraction_wiring;
        salt="phase0",
        semantic_states=states,
    )
    reversed = dem_select_semantic_target_rendezvous(
        model,
        table,
        :syndrome_extraction_wiring;
        salt="phase0",
        semantic_states=reverse(states),
    )
    shuffled = dem_select_semantic_target_rendezvous(
        model,
        table,
        :syndrome_extraction_wiring;
        salt="phase0",
        semantic_states=[states[2:end]; states[1:1]],
    )

    @test forward.policy == DEM_RENDEZVOUS_TARGET_POLICY_VERSION
    @test forward.state.semantic_hash == reversed.state.semantic_hash
    @test forward.state.semantic_hash == shuffled.state.semantic_hash
    @test forward.target_index == reversed.target_index
    @test forward.target_index == shuffled.target_index
    @test forward.pool_size == reversed.pool_size == shuffled.pool_size

    key = dem_rendezvous_target_key(
        model,
        :syndrome_extraction_wiring,
        "phase0",
        DEM_RENDEZVOUS_TARGET_POLICY_VERSION,
        forward.state,
    )
    @test length(key) == 64
    @test dem_canonical_candidate_id(forward.state) ==
        dem_canonical_candidate_id(reversed.state)
end
