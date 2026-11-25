@testset "DEM parity subject" begin
    dem = """
    error(0.01) D0 L0
    error(0.02) D1
    error(0.03) D0 D1 L0
    """
    model = parse_dem_text(
        dem;
        source_path="testdata/colorcodes/r=1,d=3,p=0.01,noise=x,c=test,q=7,gates=test.dem",
    )
    @test length(dem_fault_vars(model)) == 3
    @test !dem_encoding_uses_or(model)
    @test dem_model_summary(model)["dem_error_mechanisms_total"] == 3
    @test dem_model_summary(model)["dem_fault_cap_reached"] == false

    capped_model = parse_dem_text(
        dem;
        source_path="testdata/colorcodes/r=1,d=3,p=0.01,noise=x,c=test,q=7,gates=test.dem",
        max_faults=1,
    )
    capped_summary = dem_model_summary(capped_model)
    @test capped_summary["dem_error_mechanisms"] == 1
    @test capped_summary["dem_error_mechanisms_total"] == 3
    @test capped_summary["dem_fault_cap"] == 1
    @test capped_summary["dem_fault_cap_reached"] == true
    @test occursin("fault_cap_reached", capped_summary["dem_parse_warnings"])

    repeated_dem = """
    repeat 2 {
      error(0.01) D0
      shift_detectors 1
    }
    """
    repeated_model = parse_dem_text(repeated_dem; source_path="testdata/repeat.dem")
    repeated_summary = dem_model_summary(repeated_model)
    @test repeated_summary["dem_repeat_blocks"] == 1
    @test repeated_summary["dem_flatten_loops"] == false
    @test occursin("dem_repeat_block_not_expanded", repeated_summary["dem_parse_warnings"])

    subject = DemParitySubject(
        model;
        bug_class=:decoder_decision_error,
        budget=8,
        public_prefix_count=1,
    )
    metadata = subject_metadata(subject)
    @test get(metadata, "encoding", "") == "dem_xor_parity"
    @test get(metadata, "scheduler_visible_target_metadata", true) == false
    @test get(metadata, "target_metadata_used", true) == false
    @test get(metadata, "oracle_branch_path_constraint", true) == false
    @test haskey(metadata, "target_semantic_hash")
    @test haskey(metadata, "target_selection_pool_size")
    @test !haskey(metadata, "trigger_index")

    target_fault = first(subject.contract.target_selection.state.representative_faults)
    vars = dem_fault_vars(model)
    hit = run_subject(subject, Dict(vars[target_fault] => true))
    @test get(hit.logical_verdicts, "oracle_verdict", true) == false
    @test "O2_DECODER_MISMATCH" in triggered_failure_oracle_ids(hit)
    @test any(
        guard -> guard.id == "logical:dem_pipeline_oracle" && !guard.path_constraint,
        hit.branch_guards,
    )

    same_target_other_view = DemParitySubject(
        model;
        bug_class=:decoder_decision_error,
        budget=8,
        public_prefix_count=0,
        decoder_proxy_branch_limit=1,
        salt="",
    )
    @test same_target_other_view.contract.target_selection.state.semantic_hash ==
        subject.contract.target_selection.state.semantic_hash

    pair_dem = """
    error(0.01) D0 L0
    error(0.02) D1
    error(0.03) D2 L0
    error(0.04) D3
    """
    pair_model = parse_dem_text(
        pair_dem;
        source_path="testdata/colorcodes/r=1,d=5,p=0.01,noise=x,c=test,q=11,gates=test.dem",
    )
    pair_table = dem_reference_decoder_table(pair_model; max_weight=2, max_pair_faults=3)
    @test any(entry -> entry.weight == 2, values(pair_table))
    @test dem_reference_pair_policy(pair_model, 2, 3) == "public-prefix-window-pairs"
    @test dem_reference_candidate_count(pair_model, pair_table; public_prefix_count=1) ==
        length(dem_reference_candidate_entries(pair_model, pair_table; public_prefix_count=1))
    pair_subject = DemParitySubject(
        pair_model;
        bug_class=:unhandled_syndrome,
        max_fault_weight=2,
        reference_max_weight=2,
        max_pair_faults=3,
        budget=8,
        public_prefix_count=1,
    )
    pair_meta = subject_metadata(pair_subject)
    @test pair_meta["reference_decoder_max_weight"] == 2
    @test pair_meta["reference_decoder_pair_window"] == 3
    @test pair_meta["reference_decoder_pair_policy"] == "public-prefix-window-pairs"

    boundary_subject = DemParitySubject(
        model;
        bug_class=:boundary_classification_error,
        budget=8,
        public_prefix_count=1,
        oracle_region_policy="syndrome_key",
    )
    boundary_fault = first(boundary_subject.contract.target_selection.state.representative_faults)
    boundary_trace = run_subject(boundary_subject, Dict(vars[boundary_fault] => true))
    @test get(boundary_trace.logical_verdicts, "oracle_verdict", true) == false
    @test get(boundary_trace.logical_verdicts, "boundary_misclassification", false) == true
    @test get(boundary_trace.logical_verdicts, "missing_recovery_branch", false) == true
    @test earliest_divergence(boundary_trace) == "boundary_classification"

    observable_subject = DemParitySubject(
        model;
        bug_class=:observable_mapping_error,
        budget=8,
        public_prefix_count=1,
        oracle_region_policy="observable_key",
    )
    observable_fault = first(observable_subject.contract.target_selection.state.representative_faults)
    observable_trace = run_subject(observable_subject, Dict(vars[observable_fault] => true))
    @test get(observable_trace.logical_verdicts, "oracle_verdict", true) == false
    @test get(observable_trace.logical_verdicts, "observable_mapping_mismatch", false) == true
    @test get(observable_trace.logical_verdicts, "logical_mismatch", false) == true
    @test earliest_divergence(observable_trace) == "observable_mapping"
end
