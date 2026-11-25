module ConQEC

using SHA

include("BoolConstraints.jl")
include("ConcolicTrace.jl")
include("SemanticIR.jl")
include("SymbolicStabilizer.jl")
include("SmtLibExport.jl")
include("SolverPipeline.jl")
include("solver/QueryCanonicalizer.jl")
include("solver/DependencySlicer.jl")
include("solver/QueryCache.jl")
include("solver/QECCPreSolver.jl")
include("solver/SMTConstructCache.jl")
include("solver/PersistentZ3Backend.jl")
include("solver/SolverChainValidation.jl")
include("solver/SolverChain.jl")
include("SeedGenerator.jl")
include("FailureOracles.jl")
include("Witness.jl")
include("ConcolicExplorer.jl")
include("WitnessMinimizer.jl")
include("ExplorationMetrics.jl")
include("EvaluationIO.jl")
include("BitFlipSubject.jl")
include("PhaseFlipSubject.jl")
include("SteaneSubject.jl")
include("SurfaceSubject.jl")
include("RepetitionSubject.jl")
include("LargeRepetitionSubject.jl")
include("RoundRepetitionSubject.jl")
include("LargeDecoderTableSubject.jl")
include("WeightTwoSubject.jl")
include("WeightThreeSubject.jl")
include("HistoryChallengeSubject.jl")
include("DemFaultModel.jl")
include("DemParityEncoding.jl")
include("SemanticRegionGuards.jl")
include("SemanticRegionSolver.jl")
include("DemReferenceDecoder.jl")
include("DemRecoverySemantics.jl")
include("DemSemanticTargets.jl")
include("TesseractSeededBugs.jl")
include("DemSeededBugContracts.jl")
include("TesseractDemSubject.jl")
include("SubjectInterface.jl")
include("BenchmarkMutations.jl")
include("StressBenchmarkSubject.jl")
include("ExternalSubjects.jl")
include("PublicRepoSubjects.jl")
include("SubjectCatalog.jl")
include("BenchmarkCharacterization.jl")
include("WitnessDiagnostics.jl")

export BoolExpr,
    BoolVar,
    BoolConst,
    BoolNot,
    BoolAnd,
    BoolOr,
    BoolXor,
    BoolEq,
    boolvar,
    bconst,
    bnot,
    band,
    bor,
    bxor,
    beq,
    evaluate,
    expr_vars,
    expr_to_string,
    AbstractConstraintBackend,
    AbstractConcolicSolver,
    SolverResult,
    solver_name,
    solver_fault_vars,
    solver_max_weight,
    solve_model,
    solver_query_text,
    LocalEnumeratorBackend,
    BruteForceBoolSolver,
    solve,
    zero_assignment,
    normalize_assignment,
    assignment_key,
    model_to_fault_pattern

export smt_symbol,
    expr_to_smt2,
    declare_bool_vars_smt2,
    smt_safe_suffix,
    sigma_smt_symbol,
    smt_syndrome_pattern,
    decoder_recovery_semantics_row,
    set_decoder_recovery_semantics!,
    decoder_recovery_semantics,
    syndrome_semantics_smt2,
    fault_capacity_constraint,
    add_fault_capacity_constraint,
    constraints_to_smt2,
    ConstraintQuery,
    build_query,
    solve_query,
    parse_model,
    query_stats,
    query_bytes,
    SMTLibExportBackend,
    SmtLibExportSolver,
    Z3Backend,
    BitwuzlaBackend,
    ExternalSmtSolver,
    ExprConstructCache,
    NormalizedQuery,
    SlicedQuery,
    PresolveResult,
    ReplayResult,
    SolverResultCache,
    PersistentZ3Backend,
    SolverChainBackend,
    constraint_backend_from_name,
    parse_smt_bool_model,
    branch_query_constraints,
    branch_query_smt2,
    solve_branch_query,
    normalize_query,
    normalize_branch_query,
    slice_query,
    presolve,
    validate_model,
    replay_fault,
    solver_chain_cache_stats,
    query_hash_breakdown

export BranchGuard,
    ConcolicTrace,
    SemanticExpr,
    FaultVar,
    ParityExpr,
    SemanticGuard,
    OracleCheck,
    SemanticTrace,
    SemanticStateKey,
    check_no_oracle_branch,
    check_no_target_dependency,
    check_no_seeded_contract_dependency,
    check_branch_source_hygiene,
    check_branch_guard_source_hygiene,
    record_semantic_guard!,
    record_oracle_check!,
    SymbolicStabilizerState,
    copy_symbolic_stabilizer_state,
    absorb!,
    absorb_recovery!,
    stabilizer_generator_phase_exprs,
    stabilizer_generator_phase_values,
    symbolic_residual_vector,
    symbolic_residual_error_dict,
    symbolic_residual_weight,
    symbolic_logical_ok,
    stabilizer_generator_summary,
    record_symbolic_stabilizer_summary!,
    symbolic_stabilizer_from_faults,
    record_branch!,
    record_syndrome_bit_branches!,
    record_recovery_output_branches!,
    record_syndrome!,
    record_decoder_decision!,
    record_recovery_action!,
    record_logical_verdict!,
    path_constraint,
    flipped_path_constraint,
    full_flipped_path_constraint,
    max_fault_weight,
    branch_control_dependent_suffix,
    syndrome_key,
    fault_pattern

export SemanticRegionGuard,
    ObservableRegionGuard,
    NewObservableGuard,
    SyndromeWeightGuard,
    RoundWeightGuard,
    BoundaryGuard,
    CompoundGuard,
    canonical_region_id,
    guard_kind,
    guard_description,
    guard_expr,
    guard_dependencies,
    scheduler_visible_metadata,
    audit_only_metadata,
    SemanticRegionQuery,
    SemanticRegionSolveResult,
    active_set_key,
    semantic_region_direct_active,
    build_pure_region_query,
    build_branch_region_query,
    semantic_region_constraints_with_capacity,
    solve_semantic_region_query

export build_witness,
    write_witness,
    json_string,
    WITNESS_SCHEMA_VERSION,
    earliest_divergence,
    FailureOracleDefinition,
    failure_oracle_definitions,
    failure_oracle_by_id,
    failure_oracle_record,
    primary_oracle_id,
    residual_error_weight,
    correction_capacity,
    triggered_failure_oracles,
    triggered_failure_oracle_ids,
    stored_triggered_failure_oracle_ids,
    stored_primary_failure_oracle_id,
    stored_oracle_summary_text,
    failure_oracle_summary,
    oracle_witnesses,
    RelationalOracleState,
    canonical_value_string,
    recovery_signature,
    trace_decoder_state_key,
    trace_control_state_key,
    relational_oracle_snapshot,
    apply_relational_oracles!,
    fault_weight,
    generate_fault_seeds,
    active_fault_vars,
    minimize_fault_assignment,
    minimize_witness

export ConcolicExplorer,
    ExplorationResult,
    BranchPriorityWeights,
    DEFAULT_BRANCH_PRIORITY_WEIGHTS,
    enqueue!,
    stage_priority,
    model_fault_weight,
    model_hamming_distance,
    witness_solver_backend_name,
    witness_distance,
    branch_signature,
    branch_signature_key,
    branch_trace_hamming_distance,
    witness_branch_distance,
    witness_branch_priority_distance,
    branch_priority_score,
    branch_priority_syndrome_rank,
    branch_priority_fault_weight_rank,
    fault_model_small_fault_feature,
    model_failure_adjacency_feature,
    branch_failure_adjacency_feature,
    syndrome_key_for_model,
    branch_priority_key,
    path_branch_indices,
    prioritized_branch_indices,
    explore!,
    run_concolic

export branch_ids,
    stage_counts,
    exploration_summary

export ICSE_RAW_SCHEMA_VERSION,
    ICSE_RAW_ROW_FIELDS,
    normalized_fault_pattern,
    decoder_output_key,
    recovery_action_key,
    branch_id_key,
    fsr_tuple_key,
    fsdr_tuple_key,
    first_failure_trial,
    cumulative_semantic_coverage,
    coverage_auc,
    trace_raw_rows,
    complete_raw_row,
    compact_json_string,
    write_jsonl,
    append_jsonl,
    parse_jsonl_object,
    read_jsonl,
    read_jsonl_dir,
    write_latex_table,
    write_csv_table

export ConcolicSubjectSpec,
    subject_name,
    subject_fault_vars,
    run_subject,
    subject_metadata,
    run_concolic_subject

export WeightTwoSubject,
    weight_two_fault_vars,
    weight_two_admissible_assignments,
    run_weight_two_subject,
    WeightThreeSubject,
    weight_three_fault_vars,
    weight_three_admissible_assignments,
    run_weight_three_subject,
    HistoryChallengeSubject,
    history_challenge_fault_vars,
    history_state_count,
    run_history_challenge_subject,
    SiblingBugSubject,
    MinimizationStressSubject,
    ExternalQECCSubject,
    external_fault_vars,
    external_subject_metadata,
    external_bug_class,
    external_mutation_operator,
    external_divergence,
    external_expected_oracles

export paper_subject_configs,
    external_subject_configs,
    extended_challenge_subject_configs,
    hard_external_subject_configs,
    all_subject_configs,
    paper_subject_names,
    paper_subject_config_by_name,
    supported_subject_families,
    supported_subject_modes,
    supported_subject_mode_names

export BENCHMARK_CHARACTERIZATION_SCHEMA_VERSION,
    CHARACTERIZATION_FIELD_ORDER,
    admissible_fault_assignments,
    hardness_bin,
    benchmark_characterization_row,
    benchmark_characterization_rows,
    write_benchmark_characterization_table,
    write_benchmark_characterization_outputs

export BenchmarkSubjectSpec,
    HIGH_LEVEL_BUG_CLASSES,
    MUTATION_OPERATORS,
    seeded_bug_metadata,
    benchmark_recovery,
    coverage_challenge_fault_vars,
    run_coverage_challenge_subject,
    priority_challenge_fault_vars,
    run_priority_decoder_challenge_subject,
    high_level_bug_class,
    config_bug_metadata,
    config_bug_class,
    config_is_seeded_bug,
    config_path_sensitive

export DiagnosticContract,
    DiagnosticEvaluation,
    paper_diagnostic_contracts,
    paper_diagnostic_contract_by_name,
    diagnostic_actual_divergence,
    diagnostic_decoder_pair_text,
    diagnostic_recovery_pair_text,
    recovery_action_signature,
    witness_fault_assignment,
    replay_witness_for_subject,
    evaluate_witness_diagnostics,
    evaluate_diagnostic_result

export BitFlipSubject,
    bitflip_fault_vars,
    bitflip_priority_fault_vars,
    run_bitflip_subject,
    reference_bitflip_decoder

export PhaseFlipSubject,
    phaseflip_fault_vars,
    run_phaseflip_subject,
    reference_phaseflip_decoder

export SteaneSubject,
    steane_fault_vars,
    steane_x_fault_vars,
    steane_z_fault_vars,
    steane_y_fault_vars,
    run_steane_subject,
    reference_steane_decoder,
    steane_column_syndrome,
    steane_code_spec

export SurfaceSubject,
    surface_fault_vars,
    surface_x_fault_vars,
    surface_z_fault_vars,
    surface_y_fault_vars,
    run_surface_subject,
    reference_surface_decoder,
    surface_syndrome_from_single_fault,
    surface_all_syndromes,
    surface_code_spec

export RepetitionSubject,
    repetition_fault_vars,
    run_repetition_subject,
    reference_repetition_decoder

export LargeRepetitionSubject,
    large_repetition_fault_vars,
    run_large_repetition_subject,
    large_repetition_reference_decoder

export RoundRepetitionSubject,
    round_repetition_fault_vars,
    round_repetition_syndrome_names,
    run_round_repetition_subject,
    reference_round_repetition_decoder

export LargeDecoderTableSubject,
    large_decoder_table_fault_vars,
    large_decoder_table_budget,
    large_decoder_table_characterization,
    run_large_decoder_table_subject,
    large_decoder_table_reference_decoder

export PublicRepoQECCSubject,
    public_repo_fault_vars,
    public_repo_subject_metadata,
    public_repo_bug_metadata

export DemFaultMechanism,
    DemParityModel,
    parse_dem_text,
    parse_stim_file_as_dem,
    dem_text_from_stim_file,
    dem_stable_index,
    dem_family_from_path,
    dem_path_int,
    dem_fault_vars,
    dem_model_summary,
    dem_parity_key,
    dem_syndrome_bits,
    dem_logical_bits,
    dem_syndrome_exprs,
    dem_logical_exprs,
    dem_encoding_uses_or,
    dem_use_sparse_syndrome_key,
    dem_projected_syndrome_exprs,
    dem_projected_syndrome_bits,
    dem_syndrome_key_encoding,
    dem_observable_key_encoding,
    DemDecoderEntry,
    dem_reference_decoder_table,
    dem_reference_pair_policy,
    dem_reference_entry,
    dem_reference_candidate_entries,
    dem_reference_candidate_count,
    dem_entry_signature,
    DEM_SEMANTIC_TARGET_POLICY_VERSION,
    DEM_UNIFORM_TARGET_POLICY_VERSION,
    DEM_RENDEZVOUS_TARGET_POLICY_VERSION,
    DemSemanticState,
    DemSemanticTargetSelection,
    dem_sha256_hex,
    dem_canonical_candidate_id,
    dem_weight1_semantic_states,
    dem_semantic_target_pool,
    dem_select_semantic_target,
    dem_select_semantic_target_rendezvous,
    dem_rendezvous_target_key,
    dem_visible_proxy_entries,
    dem_semantic_target_metadata,
    dem_seeded_bug_classes,
    DemSeededBugContract,
    dem_seeded_bug_contract,
    dem_seeded_contract_summary,
    DemParitySubject,
    dem_subject_metadata,
    run_dem_parity_subject

end
