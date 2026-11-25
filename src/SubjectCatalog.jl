clean_config(label::AbstractString, subject, max_tests::Integer) = (
    label=String(label),
    subject=subject,
    max_tests=Int(max_tests),
    bug_metadata=nothing,
)

bug_config(label::AbstractString, subject, max_tests::Integer, metadata::AbstractDict) = (
    label=String(label),
    subject=subject,
    max_tests=Int(max_tests),
    bug_metadata=metadata,
)

oracle_ids(keys...) = [String(key) for key in keys]
decoder_oracles() =
    oracle_ids("O1_LOGICAL_MISMATCH", "O2_DECODER_MISMATCH", "O3_RESIDUAL_CORRECTABLE_ERROR")
residual_oracles() =
    oracle_ids("O1_LOGICAL_MISMATCH", "O3_RESIDUAL_CORRECTABLE_ERROR")
missing_recovery_oracles() =
    oracle_ids("O1_LOGICAL_MISMATCH", "O3_RESIDUAL_CORRECTABLE_ERROR", "O4_DEAD_RECOVERY_BRANCH")
unhandled_syndrome_oracles() =
    oracle_ids("O1_LOGICAL_MISMATCH", "O2_DECODER_MISMATCH",
        "O3_RESIDUAL_CORRECTABLE_ERROR", "O4_DEAD_RECOVERY_BRANCH")
round_decoder_oracles() = oracle_ids("O2_DECODER_MISMATCH")
relational_oracles() = oracle_ids("O5_INCONSISTENT_CONTROL")

function bug_meta(id, family, size, bug_class, operator, divergence, oracles;
    actual_decoder=nothing,
    reference_decoder=nothing,
    actual_recovery=nothing,
    reference_recovery=nothing,
    expected_min_fault_weight=1,
    path_sensitive=false,
    notes="")

    return seeded_bug_metadata(
        bug_id=id,
        subject_family=family,
        subject_size=size,
        bug_class=bug_class,
        mutation_operator=operator,
        path_sensitive=path_sensitive,
        expected_earliest_divergence=divergence,
        expected_oracle_classes=oracles,
        expected_actual_decoder=actual_decoder,
        expected_reference_decoder=reference_decoder,
        expected_actual_recovery=actual_recovery,
        expected_reference_recovery=reference_recovery,
        expected_min_fault_weight=expected_min_fault_weight,
        notes=notes,
    )
end

function wrapped_bug_subject(label::AbstractString,
    base_subject;
    metadata::AbstractDict,
    trigger_decoder=nothing,
    actual_decoder=nothing,
    recovery_override=nothing,
    verdict_overrides=Dict{String,Any}())

    return BenchmarkSubjectSpec(
        label,
        base_subject;
        mutation_operator=metadata["mutation_operator"],
        trigger_decoder=trigger_decoder,
        actual_decoder=actual_decoder,
        recovery_override=recovery_override,
        divergence=metadata["expected_earliest_divergence"],
        verdict_overrides=verdict_overrides,
        metadata=Dict{String,Any}(
            "subject_family" => metadata["subject_family"],
            "benchmark_family" => "QECCSeededMutations",
            "bug_metadata" => Dict{String,Any}(metadata),
            "path_sensitive" => metadata["path_sensitive"],
        ),
    )
end

function wrapped_bug_config(label::AbstractString,
    base_subject,
    max_tests::Integer,
    metadata::AbstractDict;
    kwargs...)

    subject = wrapped_bug_subject(label, base_subject; metadata=metadata, kwargs...)
    return bug_config(label, subject, max_tests, metadata)
end

function priority_challenge_subject(label::AbstractString; decoys::Integer=7)
    return ConcolicSubjectSpec(
        label,
        priority_challenge_fault_vars(decoys=decoys),
        input -> run_priority_decoder_challenge_subject(input; name=label, decoys=decoys);
        metadata=Dict(
            "subject_family" => "PathSensitiveChallenges",
            "benchmark_family" => "PathSensitiveChallenges",
            "path_sensitive" => true,
            "challenge_kind" => "late_decoder_branch",
            "qubits" => decoys + 1,
            "fault_variables" => decoys + 1,
            "max_fault_weight" => 1,
            "admissible_assignments" => decoys + 2,
            "decoder_arms" => decoys + 2,
            "recovery_actions" => decoys + 2,
            "rounds" => 1,
            "history_states" => 0,
            "recommended_budget" => max(12, decoys + 2),
            "trigger_faults" => ["bug"],
            "interesting_faults" => ["bug"],
            "boring_faults" => ["d$(idx)" for idx in 1:decoys],
        ),
    )
end

coverage_challenge_subject() =
    ConcolicSubjectSpec(
        "coverage_challenge_clean",
        coverage_challenge_fault_vars(),
        run_coverage_challenge_subject;
        metadata=Dict(
            "subject_family" => "PathSensitiveChallenges",
            "benchmark_family" => "PathSensitiveChallenges",
            "path_sensitive" => true,
            "challenge_kind" => "coverage",
            "qubits" => 8,
            "fault_variables" => 8,
            "max_fault_weight" => 1,
            "admissible_assignments" => 9,
            "decoder_arms" => 4,
            "recovery_actions" => 4,
            "rounds" => 1,
            "history_states" => 0,
            "recommended_budget" => 8,
            "interesting_faults" => ["signal1", "signal2", "signal3"],
            "boring_faults" => ["decoy$(idx)" for idx in 1:5],
        ),
    )

decoder_verdicts() = Dict{String,Any}(
    "decoder_mismatch" => true,
    "recovery_mismatch" => true,
    "logical_mismatch" => true,
    "missing_recovery_branch" => false,
    "oracle_verdict" => false,
    "residual_weight" => 1,
)

unhandled_verdicts() = Dict{String,Any}(
    "decoder_mismatch" => true,
    "recovery_mismatch" => true,
    "logical_mismatch" => true,
    "missing_recovery_branch" => true,
    "oracle_verdict" => false,
    "residual_weight" => 1,
)

recovery_verdicts() = Dict{String,Any}(
    "decoder_mismatch" => false,
    "recovery_mismatch" => true,
    "logical_mismatch" => true,
    "missing_recovery_branch" => false,
    "oracle_verdict" => false,
    "residual_weight" => 1,
)

function priority_bug_config(label::AbstractString,
    id::AbstractString;
    decoys::Integer=7,
    notes::AbstractString="late decoder branch challenge")

    metadata = bug_meta(
        id,
        "PathSensitiveChallenges",
        decoys + 1,
        "decoder_decision_error",
        "path_sensitive_late_decoder_branch",
        "decoder",
        decoder_oracles();
        actual_decoder="buggy_arm",
        reference_decoder="none",
        actual_recovery="I@none",
        reference_recovery="I@none",
        path_sensitive=true,
        notes=notes,
    )
    metadata["benchmark_family"] = "PathSensitiveChallenges"
    metadata["max_fault_weight"] = 1
    metadata["recommended_budget"] = max(12, decoys + 2)
    metadata["trigger_faults"] = ["bug"]
    metadata["interesting_faults"] = ["bug"]
    metadata["boring_faults"] = ["d$(idx)" for idx in 1:decoys]
    return bug_config(label, priority_challenge_subject(label; decoys=decoys), 12, metadata)
end

function large_decoder_table_bug_metadata(id::AbstractString,
    subject::LargeDecoderTableSubject)

    actual = large_decoder_table_decoder_label(subject.wrong_arm)
    reference = large_decoder_table_decoder_label(subject.bug_arm)
    metadata = bug_meta(
        id,
        "large_decoder_table",
        subject.arms,
        "decoder_decision_error",
        "decoder_table_entry_swap",
        "decoder",
        decoder_oracles();
        actual_decoder=actual,
        reference_decoder=reference,
        actual_recovery="X@$(actual)",
        reference_recovery="X@$(reference)",
        path_sensitive=true,
        notes=string(
            "sparse decoder-table entry arm ",
            subject.bug_arm,
            " of ",
            subject.arms,
            " is swapped to ",
            subject.wrong_arm,
            "; neutral decoy branches make trace-order and bounded enumeration spend the budget before this decoder arm",
        ),
    )
    for (key, value) in large_decoder_table_characterization(subject)
        metadata[key] = value
    end
    metadata["bug_target_arm"] = subject.bug_arm
    metadata["wrong_target_arm"] = subject.wrong_arm
    metadata["neutral_decoy_faults"] = subject.decoys
    return metadata
end

function large_decoder_table_bug_config(arms::Integer, bug_arm::Integer,
    suffix::AbstractString; decoys=nothing, budget=nothing)

    label = "large_decoder_table_a$(arms)_sparse_$(bug_arm)_$(suffix)"
    subject = LargeDecoderTableSubject(
        arms,
        bug_arm;
        label=label,
        decoys=decoys === nothing ? large_decoder_table_default_decoys(arms) : decoys,
        budget=budget === nothing ? large_decoder_table_budget(arms) : budget,
    )
    id = "LDT-" * lpad(string(arms), 3, '0') * "-" * uppercase(String(suffix))
    metadata = large_decoder_table_bug_metadata(id, subject)
    return bug_config(label, subject, subject.budget, metadata)
end

const LARGE_DECODER_TABLE_BUG_CONFIGS = [
    large_decoder_table_bug_config(32, 29, "a"),
    large_decoder_table_bug_config(32, 31, "b"),
    large_decoder_table_bug_config(64, 59, "a"),
    large_decoder_table_bug_config(64, 63, "b"),
    large_decoder_table_bug_config(128, 113, "a"),
    large_decoder_table_bug_config(128, 127, "b"),
    large_decoder_table_bug_config(256, 241, "a"),
    large_decoder_table_bug_config(256, 255, "b"),
]

const HARD_LARGE_DECODER_TABLE_BUG_CONFIGS = [
    large_decoder_table_bug_config(128, 97, "hard_a"; decoys=128, budget=2),
    large_decoder_table_bug_config(128, 127, "hard_b"; decoys=128, budget=2),
    large_decoder_table_bug_config(256, 193, "hard_a"; decoys=256, budget=4),
    large_decoder_table_bug_config(256, 255, "hard_b"; decoys=256, budget=4),
    large_decoder_table_bug_config(512, 389, "hard_a"; decoys=512, budget=8),
    large_decoder_table_bug_config(512, 511, "hard_b"; decoys=512, budget=8),
]

weight_two_pair_recovery_signature(pair::Tuple{Int,Int}) =
    "X@q$(pair[1])+q$(pair[2])"

function weight_two_wrong_pair_for(subject::WeightTwoSubject)
    first_q, second_q = subject.target_pair
    wrong_second = second_q == subject.qubits ? second_q - 1 : second_q + 1
    wrong_pair = sort!([first_q, wrong_second])
    return (wrong_pair[1], wrong_pair[2])
end

function weight_two_bug_metadata(id::AbstractString, subject::WeightTwoSubject)
    expected_decoder = weight_two_decoder_output(subject.target_pair)
    expected_recovery = weight_two_pair_recovery_signature(subject.target_pair)
    actual_decoder = expected_decoder
    actual_recovery = expected_recovery
    bug_class = subject.mode == :unhandled_pair_bug ?
        "unhandled_syndrome" :
        subject.mode == :recovery_pair_bug ?
            "recovery_application_error" :
            "decoder_decision_error"
    operator = subject.mode == :unhandled_pair_bug ?
        "missing_decoder_arm" :
        subject.mode == :recovery_pair_bug ?
            "wrong_recovery_target" :
            "decoder_table_entry_swap"
    divergence = subject.mode == :recovery_pair_bug ? "recovery" : "decoder"
    oracles = subject.mode == :unhandled_pair_bug ?
        unhandled_syndrome_oracles() :
        subject.mode == :recovery_pair_bug ?
            residual_oracles() :
            decoder_oracles()
    if subject.mode == :decoder_pair_bug
        wrong_pair = weight_two_wrong_pair_for(subject)
        actual_decoder = weight_two_decoder_output(wrong_pair)
        actual_recovery = weight_two_pair_recovery_signature(wrong_pair)
    elseif subject.mode == :recovery_pair_bug
        wrong_pair = weight_two_wrong_pair_for(subject)
        actual_recovery = weight_two_pair_recovery_signature(wrong_pair)
    elseif subject.mode == :unhandled_pair_bug
        actual_decoder = "missing"
        actual_recovery = "missing@missing"
    end

    metadata = bug_meta(
        id,
        "weight_two_correctable_repetition",
        subject.qubits,
        bug_class,
        operator,
        divergence,
        oracles;
        actual_decoder=actual_decoder,
        reference_decoder=expected_decoder,
        actual_recovery=actual_recovery,
        reference_recovery=expected_recovery,
        expected_min_fault_weight=2,
        path_sensitive=true,
        notes="pair-only correctable fault trigger; bounded weight-1 sampling misses this subject",
    )
    for (key, value) in subject_metadata(subject)
        metadata[key] = value
    end
    return metadata
end

function weight_two_bug_config(id::AbstractString, subject::WeightTwoSubject)
    budget = Int(subject_metadata(subject)["recommended_budget"])
    return bug_config(subject.name, subject, budget, weight_two_bug_metadata(id, subject))
end

const WEIGHT_TWO_BUG_CONFIGS = [
    weight_two_bug_config("W2-DEC-025", WeightTwoSubject(25, :decoder_pair_bug; target_pair=(7, 19))),
    weight_two_bug_config("W2-REC-025", WeightTwoSubject(25, :recovery_pair_bug; target_pair=(6, 20))),
    weight_two_bug_config("W2-DEC-050", WeightTwoSubject(50, :decoder_pair_bug; target_pair=(17, 41))),
    weight_two_bug_config("W2-UNH-050", WeightTwoSubject(50, :unhandled_pair_bug; target_pair=(11, 43))),
    weight_two_bug_config("W2-DEC-100", WeightTwoSubject(100, :decoder_pair_bug; target_pair=(23, 79))),
    weight_two_bug_config("W2-REC-100", WeightTwoSubject(100, :recovery_pair_bug; target_pair=(31, 89))),
    weight_two_bug_config("W2-UNH-250", WeightTwoSubject(250, :unhandled_pair_bug; target_pair=(47, 211))),
]

const HARD_WEIGHT_TWO_BUG_CONFIGS = [
    weight_two_bug_config("W2-DEC-055-H", WeightTwoSubject(55, :decoder_pair_bug; target_pair=(13, 47), budget=8)),
    weight_two_bug_config("W2-REC-060-H", WeightTwoSubject(60, :recovery_pair_bug; target_pair=(17, 53), budget=8)),
    weight_two_bug_config("W2-UNH-065-H", WeightTwoSubject(65, :unhandled_pair_bug; target_pair=(11, 59), budget=8)),
    weight_two_bug_config("W2-DEC-075-H", WeightTwoSubject(75, :decoder_pair_bug; target_pair=(19, 67), budget=12)),
    weight_two_bug_config("W2-REC-085-H", WeightTwoSubject(85, :recovery_pair_bug; target_pair=(23, 79), budget=12)),
]

function weight_three_wrong_signature(triple::Tuple{Int,Int,Int})
    return "X@" * join(["q$(idx)" for idx in triple], "+")
end

function weight_three_bug_metadata(id::AbstractString, subject::WeightThreeSubject)
    expected_decoder = weight_three_decoder_output(subject.target_triple)
    expected_recovery = weight_three_wrong_signature(subject.target_triple)
    actual_decoder = expected_decoder
    actual_recovery = expected_recovery
    bug_class = subject.mode == :unhandled_triple_bug ?
        "unhandled_syndrome" :
        subject.mode == :recovery_triple_bug ?
            "recovery_application_error" :
            "decoder_decision_error"
    operator = subject.mode == :unhandled_triple_bug ?
        "missing_decoder_arm" :
        subject.mode == :recovery_triple_bug ?
            "wrong_recovery_target" :
            "decoder_table_entry_swap"
    divergence = subject.mode == :recovery_triple_bug ? "recovery" : "decoder"
    oracles = subject.mode == :unhandled_triple_bug ?
        unhandled_syndrome_oracles() :
        subject.mode == :recovery_triple_bug ?
            residual_oracles() :
            decoder_oracles()
    if subject.mode == :decoder_triple_bug
        wrong_triple = weight_three_wrong_triple_for(subject)
        actual_decoder = weight_three_decoder_output(wrong_triple)
        actual_recovery = weight_three_wrong_signature(wrong_triple)
    elseif subject.mode == :recovery_triple_bug
        wrong_triple = weight_three_wrong_triple_for(subject)
        actual_recovery = weight_three_wrong_signature(wrong_triple)
    elseif subject.mode == :unhandled_triple_bug
        actual_decoder = "missing"
        actual_recovery = "missing@missing"
    end

    metadata = bug_meta(
        id,
        "weight_three_correctable_repetition",
        subject.qubits,
        bug_class,
        operator,
        divergence,
        oracles;
        actual_decoder=actual_decoder,
        reference_decoder=expected_decoder,
        actual_recovery=actual_recovery,
        reference_recovery=expected_recovery,
        expected_min_fault_weight=3,
        path_sensitive=true,
        notes="triple-only correctable fault trigger; low-weight bounded sampling spends the budget before this rare triple",
    )
    for (key, value) in subject_metadata(subject)
        metadata[key] = value
    end
    return metadata
end

function weight_three_bug_config(id::AbstractString, subject::WeightThreeSubject)
    budget = Int(subject_metadata(subject)["recommended_budget"])
    return bug_config(subject.name, subject, budget, weight_three_bug_metadata(id, subject))
end

const WEIGHT_THREE_BUG_CONFIGS = [
    weight_three_bug_config("W3-DEC-035-H", WeightThreeSubject(35, :decoder_triple_bug; target_triple=(7, 21, 31), budget=4)),
    weight_three_bug_config("W3-REC-040-H", WeightThreeSubject(40, :recovery_triple_bug; target_triple=(7, 27, 37), budget=4)),
    weight_three_bug_config("W3-UNH-045-H", WeightThreeSubject(45, :unhandled_triple_bug; target_triple=(7, 31, 43), budget=4)),
    weight_three_bug_config("W3-DEC-050-H", WeightThreeSubject(50, :decoder_triple_bug; target_triple=(11, 29, 47), budget=6)),
]

history_recovery_signature(round::Integer, qubit::Integer) =
    "X@q$(qubit):round=$(round)"

function history_bug_metadata(id::AbstractString, subject::HistoryChallengeSubject)
    expected_decoder = "r$(subject.target_round)_q$(subject.target_qubit)"
    expected_recovery =
        history_recovery_signature(subject.target_round, subject.target_qubit)
    actual_decoder = expected_decoder
    actual_recovery = expected_recovery
    operator = "missing_syndrome_history_update"
    oracles = round_decoder_oracles()
    if subject.mode == :history_drop_bug
        actual_round = min(subject.rounds, subject.target_round + 1)
        actual_decoder = "r$(actual_round)_q$(subject.target_qubit)"
        actual_recovery = history_recovery_signature(actual_round, subject.target_qubit)
        operator = "missing_syndrome_history_update"
    elseif subject.mode == :stale_history_reuse_bug
        actual_round = max(1, subject.target_round - 1)
        actual_decoder = "r$(actual_round)_q$(subject.target_qubit)"
        actual_recovery = history_recovery_signature(actual_round, subject.target_qubit)
        operator = "stale_syndrome_history_reuse"
    elseif subject.mode == :off_by_one_round_bug
        actual_round = min(subject.rounds, subject.target_round + 1)
        actual_round == subject.target_round && (actual_round = max(1, subject.target_round - 1))
        actual_decoder = "r$(actual_round)_q$(subject.target_qubit)"
        actual_recovery = history_recovery_signature(actual_round, subject.target_qubit)
        operator = "off_by_one_round_count"
    elseif subject.mode in (:inconsistent_control_bug, :equivalent_current_control_bug)
        operator = "path_sensitive_relational_control"
        oracles = relational_oracles()
    elseif subject.mode == :missing_reset_bug
        actual_decoder = "uncorrectable"
        actual_recovery = "missing@uncorrectable"
        operator = "missing_ancilla_reset"
        oracles = unhandled_syndrome_oracles()
    end

    metadata = bug_meta(
        id,
        "repeated_round_history_challenge",
        subject.qubits * subject.rounds,
        "repeated_round_control_error",
        operator,
        "repeated_round_control",
        oracles;
        actual_decoder=actual_decoder,
        reference_decoder=expected_decoder,
        actual_recovery=actual_recovery,
        reference_recovery=expected_recovery,
        expected_min_fault_weight=1,
        path_sensitive=true,
        notes="failing behavior depends on syndrome history rather than the final current syndrome alone",
    )
    for (key, value) in subject_metadata(subject)
        metadata[key] = value
    end
    return metadata
end

function history_bug_config(id::AbstractString, subject::HistoryChallengeSubject)
    budget = Int(subject_metadata(subject)["recommended_budget"])
    return bug_config(subject.name, subject, budget, history_bug_metadata(id, subject))
end

const HISTORY_CHALLENGE_BUG_CONFIGS = [
    history_bug_config("HIS-DROP-025-R2", HistoryChallengeSubject(25, 2, :history_drop_bug; target_round=1, target_qubit=5)),
    history_bug_config("HIS-STALE-025-R3", HistoryChallengeSubject(25, 3, :stale_history_reuse_bug; target_round=2, target_qubit=10)),
    history_bug_config("HIS-OBO-050-R3", HistoryChallengeSubject(50, 3, :off_by_one_round_bug; target_round=2, target_qubit=23)),
    history_bug_config("HIS-CTRL-050-R4", HistoryChallengeSubject(50, 4, :inconsistent_control_bug; target_round=3, target_qubit=37)),
    history_bug_config("HIS-EQUIV-100-R2", HistoryChallengeSubject(100, 2, :equivalent_current_control_bug; target_round=1, target_qubit=50)),
    history_bug_config("HIS-RESET-100-R4", HistoryChallengeSubject(100, 4, :missing_reset_bug; target_round=2, target_qubit=75)),
]

const HARD_HISTORY_CHALLENGE_BUG_CONFIGS = [
    history_bug_config("HIS-DROP-120-R3-H", HistoryChallengeSubject(120, 3, :history_drop_bug; target_round=2, target_qubit=91, budget=3)),
    history_bug_config("HIS-STALE-130-R3-H", HistoryChallengeSubject(130, 3, :stale_history_reuse_bug; target_round=2, target_qubit=101, budget=3)),
    history_bug_config("HIS-OBO-140-R3-H", HistoryChallengeSubject(140, 3, :off_by_one_round_bug; target_round=2, target_qubit=113, budget=4)),
    history_bug_config("HIS-CTRL-150-R4-H", HistoryChallengeSubject(150, 4, :inconsistent_control_bug; target_round=3, target_qubit=121, budget=5)),
    history_bug_config("HIS-RESET-160-R4-H", HistoryChallengeSubject(160, 4, :missing_reset_bug; target_round=2, target_qubit=137, budget=5)),
]

function stress_oracles_for_class(bug_class::AbstractString)
    class = String(bug_class)
    class == "decoder_decision_error" && return decoder_oracles()
    class == "recovery_application_error" && return residual_oracles()
    class == "unhandled_syndrome" && return unhandled_syndrome_oracles()
    class == "syndrome_extraction_wiring" && return residual_oracles()
    class == "measurement_result_misuse" && return residual_oracles()
    class == "repeated_round_control_error" && return round_decoder_oracles()
    return decoder_oracles()
end

function stress_operator_for_class(bug_class::AbstractString)
    class = String(bug_class)
    class == "decoder_decision_error" && return "decoder_table_entry_swap"
    class == "recovery_application_error" && return "recovery_applied_under_wrong_condition"
    class == "unhandled_syndrome" && return "missing_decoder_arm"
    class == "syndrome_extraction_wiring" && return "wrong_stabilizer_check_support"
    class == "measurement_result_misuse" && return "stale_measurement_value_reuse"
    class == "repeated_round_control_error" && return "stale_syndrome_history_reuse"
    return "decoder_table_entry_swap"
end

function stress_divergence_for_class(bug_class::AbstractString)
    class = String(bug_class)
    class == "recovery_application_error" && return "recovery"
    class == "syndrome_extraction_wiring" && return "syndrome"
    class == "measurement_result_misuse" && return "measurement_result"
    class == "repeated_round_control_error" && return "repeated_round_control"
    return "decoder"
end

function stress_expected_actual(subject::SiblingBugSubject)
    expected = "q$(subject.first_var)"
    class = subject.bug_class
    actual_decoder = class == "decoder_decision_error" ? "q_bug" :
        class == "unhandled_syndrome" ? "missing" : expected
    actual_recovery = class == "recovery_application_error" ? "X@wrong_target" :
        class == "unhandled_syndrome" ? "missing@missing" :
        actual_decoder == "none" ? "I@none" : "X@$(actual_decoder)"
    expected_recovery = expected == "none" ? "I@none" : "X@$(expected)"
    return actual_decoder, expected, actual_recovery, expected_recovery
end

function stress_expected_actual(subject::MinimizationStressSubject)
    expected = "q$(subject.minimal_var)"
    class = subject.bug_class
    actual_decoder = class == "decoder_decision_error" ? "q_bug" :
        class == "unhandled_syndrome" ? "missing" : expected
    actual_recovery = class == "recovery_application_error" ? "X@wrong_target" :
        class == "unhandled_syndrome" ? "missing@missing" :
        actual_decoder == "none" ? "I@none" : "X@$(actual_decoder)"
    expected_recovery = expected == "none" ? "I@none" : "X@$(expected)"
    return actual_decoder, expected, actual_recovery, expected_recovery
end

function sibling_bug_metadata(id::AbstractString, subject::SiblingBugSubject)
    actual_decoder, expected_decoder, actual_recovery, expected_recovery =
        stress_expected_actual(subject)
    metadata = bug_meta(
        id,
        "failure_adjacent_sibling",
        subject.qubits,
        subject.bug_class,
        stress_operator_for_class(subject.bug_class),
        stress_divergence_for_class(subject.bug_class),
        stress_oracles_for_class(subject.bug_class);
        actual_decoder=actual_decoder,
        reference_decoder=expected_decoder,
        actual_recovery=actual_recovery,
        reference_recovery=expected_recovery,
        expected_min_fault_weight=1,
        path_sensitive=true,
        notes="nearby sibling bug used to evaluate failure-adjacent branch prioritization",
    )
    for (key, value) in subject_metadata(subject)
        metadata[key] = value
    end
    return metadata
end

function minimization_bug_metadata(id::AbstractString, subject::MinimizationStressSubject)
    actual_decoder, expected_decoder, actual_recovery, expected_recovery =
        stress_expected_actual(subject)
    metadata = bug_meta(
        id,
        "minimization_stress",
        subject.qubits,
        subject.bug_class,
        stress_operator_for_class(subject.bug_class),
        stress_divergence_for_class(subject.bug_class),
        stress_oracles_for_class(subject.bug_class);
        actual_decoder=actual_decoder,
        reference_decoder=expected_decoder,
        actual_recovery=actual_recovery,
        reference_recovery=expected_recovery,
        expected_min_fault_weight=1,
        path_sensitive=true,
        notes="solver branch initially produces a non-minimal failing fault set; witness minimization should preserve oracle and divergence",
    )
    for (key, value) in subject_metadata(subject)
        metadata[key] = value
    end
    return metadata
end

sibling_bug_config(id::AbstractString, subject::SiblingBugSubject) =
    bug_config(subject.name, subject, 16, sibling_bug_metadata(id, subject))

minimization_bug_config(id::AbstractString, subject::MinimizationStressSubject) =
    bug_config(subject.name, subject, 16, minimization_bug_metadata(id, subject))

const FAILURE_ADJACENT_SIBLING_BUG_CONFIGS = [
    sibling_bug_config("SIB-DEC-025-A", SiblingBugSubject("sibling_decoder_n25_a", 25, 21, 22, "decoder_decision_error")),
    sibling_bug_config("SIB-DEC-025-B", SiblingBugSubject("sibling_decoder_n25_b", 25, 22, 23, "decoder_decision_error")),
    sibling_bug_config("SIB-REC-050-A", SiblingBugSubject("sibling_recovery_n50_a", 50, 43, 44, "recovery_application_error")),
    sibling_bug_config("SIB-REC-050-B", SiblingBugSubject("sibling_recovery_n50_b", 50, 44, 45, "recovery_application_error")),
    sibling_bug_config("SIB-UNH-100-A", SiblingBugSubject("sibling_unhandled_n100_a", 100, 91, 92, "unhandled_syndrome")),
    sibling_bug_config("SIB-UNH-100-B", SiblingBugSubject("sibling_unhandled_n100_b", 100, 92, 93, "unhandled_syndrome")),
]

const MINIMIZATION_STRESS_BUG_CONFIGS = [
    minimization_bug_config("MIN-DEC-025-A", MinimizationStressSubject("min_stress_decoder_n25_a", 25, [21, 22], 21, "decoder_decision_error")),
    minimization_bug_config("MIN-DEC-025-B", MinimizationStressSubject("min_stress_decoder_n25_b", 25, [22, 23, 24], 22, "decoder_decision_error")),
    minimization_bug_config("MIN-REC-050-A", MinimizationStressSubject("min_stress_recovery_n50_a", 50, [41, 42], 41, "recovery_application_error")),
    minimization_bug_config("MIN-REC-050-B", MinimizationStressSubject("min_stress_recovery_n50_b", 50, [42, 43, 44], 42, "recovery_application_error")),
    minimization_bug_config("MIN-UNH-075-A", MinimizationStressSubject("min_stress_unhandled_n75_a", 75, [61, 62], 61, "unhandled_syndrome")),
    minimization_bug_config("MIN-UNH-075-B", MinimizationStressSubject("min_stress_unhandled_n75_b", 75, [62, 63, 64], 62, "unhandled_syndrome")),
    minimization_bug_config("MIN-DEC-100-A", MinimizationStressSubject("min_stress_decoder_n100_a", 100, [91, 92], 91, "decoder_decision_error")),
    minimization_bug_config("MIN-REC-100-A", MinimizationStressSubject("min_stress_recovery_n100_a", 100, [92, 93, 94], 92, "recovery_application_error")),
]

const EXTERNAL_ORIGINS = Dict(
    :quantumse_repetition =>
        "QuantumSE.jl-style repetition decoder/control example adapted from documented symbolic-stabilizer insertion points",
    :steane_css =>
        "Steane CSS Hamming-table example adapted from the repository Steane example and standard CSS parity checks",
    :stim_detector =>
        "Stim detector-style detector-event kernel adapted from documented detector semantics",
)

function external_subject(code_kind::Symbol, bug_mode::Symbol, suffix::AbstractString;
    qubits::Integer, rounds::Integer=1, trigger_index::Integer=2,
    wrong_index::Integer=1)

    name = string("external_", code_kind, "_", suffix)
    return ExternalQECCSubject(
        name,
        EXTERNAL_ORIGINS[code_kind],
        code_kind,
        bug_mode;
        qubits=qubits,
        rounds=rounds,
        trigger_index=trigger_index,
        wrong_index=wrong_index,
    )
end

function external_bug_metadata(id::AbstractString, subject::ExternalQECCSubject)
    trigger_label = external_label(subject, subject.trigger_index)
    wrong_label = external_label(subject, subject.wrong_index)
    actual_decoder, expected_decoder, actual_recovery, expected_recovery, _ =
        external_outputs(subject, subject.trigger_index)
    metadata = bug_meta(
        id,
        "ExternalSubjects",
        subject.qubits,
        external_bug_class(subject),
        external_mutation_operator(subject),
        external_divergence(subject),
        external_expected_oracles(subject);
        actual_decoder=actual_decoder,
        reference_decoder=expected_decoder,
        actual_recovery=external_action_signature(actual_recovery),
        reference_recovery=external_action_signature(expected_recovery),
        expected_min_fault_weight=1,
        path_sensitive=subject.bug_mode in
            (:decoder_decision_error, :recovery_application_error,
                :unhandled_syndrome, :repeated_round_control_error),
        notes=string(
            "External/adapted validation subject from ",
            subject.origin,
            "; trigger ",
            trigger_label["decoder"],
            " maps against ",
            wrong_label["decoder"],
        ),
    )
    for (key, value) in external_subject_metadata(subject)
        metadata[key] = value
    end
    metadata["origin"] = subject.origin
    metadata["external_subject"] = true
    metadata["benchmark_family"] = "ExternalSubjects"
    return metadata
end

function external_bug_config(id::AbstractString, subject::ExternalQECCSubject)
    budget = Int(external_subject_metadata(subject)["recommended_budget"])
    return bug_config(subject.name, subject, budget, external_bug_metadata(id, subject))
end

const EXTERNAL_SUBJECT_CONFIGS = [
    external_bug_config(
        "EXT-QSE-DEC-001",
        external_subject(:quantumse_repetition, :decoder_decision_error,
            "decoder_entry_swap"; qubits=7, trigger_index=4, wrong_index=3),
    ),
    external_bug_config(
        "EXT-QSE-REC-001",
        external_subject(:quantumse_repetition, :recovery_application_error,
            "wrong_recovery"; qubits=7, trigger_index=5, wrong_index=6),
    ),
    external_bug_config(
        "EXT-CSS-DEC-001",
        external_subject(:steane_css, :decoder_decision_error,
            "x_decoder_entry"; qubits=7, trigger_index=2, wrong_index=3),
    ),
    external_bug_config(
        "EXT-CSS-UNH-001",
        external_subject(:steane_css, :unhandled_syndrome,
            "z_unhandled"; qubits=7, trigger_index=10, wrong_index=9),
    ),
    external_bug_config(
        "EXT-STIM-REC-001",
        external_subject(:stim_detector, :recovery_application_error,
            "detector_wrong_recovery"; qubits=9, rounds=2,
            trigger_index=6, wrong_index=7),
    ),
    external_bug_config(
        "EXT-STIM-RND-001",
        external_subject(:stim_detector, :repeated_round_control_error,
            "stale_round_control"; qubits=9, rounds=2,
            trigger_index=5, wrong_index=13),
    ),
    external_bug_config(
        "EXT-QSE-SPARSE-002",
        external_subject(:quantumse_repetition, :decoder_decision_error,
            "sparse_decoder_path"; qubits=25, trigger_index=23, wrong_index=2),
    ),
    external_bug_config(
        "EXT-STIM-HIST-002",
        external_subject(:stim_detector, :repeated_round_control_error,
            "history_sparse_control"; qubits=25, rounds=3,
            trigger_index=47, wrong_index=20),
    ),
    external_bug_config(
        "EXT-QSE-DEC-002",
        external_subject(:quantumse_repetition, :decoder_decision_error,
            "sparse_path_challenge"; qubits=120, trigger_index=80, wrong_index=73),
    ),
    external_bug_config(
        "EXT-QSE-REC-002",
        external_subject(:quantumse_repetition, :recovery_application_error,
            "scaled_sparse_recovery"; qubits=140, trigger_index=90, wrong_index=100),
    ),
    external_bug_config(
        "EXT-QSE-DEC-003",
        external_subject(:quantumse_repetition, :decoder_decision_error,
            "scaled_decoder_path"; qubits=60, trigger_index=23, wrong_index=57),
    ),
    external_bug_config(
        "EXT-STIM-RND-003",
        external_subject(:stim_detector, :repeated_round_control_error,
            "round_index_sparse_control"; qubits=80, rounds=4,
            trigger_index=250, wrong_index=120),
    ),
    external_bug_config(
        "EXT-STIM-UNH-002",
        external_subject(:stim_detector, :unhandled_syndrome,
            "large_unhandled_pattern"; qubits=100, rounds=3,
            trigger_index=180, wrong_index=199),
    ),
    external_bug_config(
        "EXT-STIM-RND-004",
        external_subject(:stim_detector, :repeated_round_control_error,
            "medium_round_control_sparse"; qubits=50, rounds=2,
            trigger_index=24, wrong_index=35),
    ),
    external_bug_config(
        "EXT-STIM-RND-005",
        external_subject(:stim_detector, :repeated_round_control_error,
            "stale_round_control_large"; qubits=70, rounds=2,
            trigger_index=44, wrong_index=58),
    ),
]

const HARD_EXTERNAL_SUBJECT_CONFIGS = [
    external_bug_config(
        "EXT-QSE-DEC-H01",
        external_subject(:quantumse_repetition, :decoder_decision_error,
            "hard_sparse_decoder_path"; qubits=900,
            trigger_index=811, wrong_index=407),
    ),
    external_bug_config(
        "EXT-QSE-REC-H01",
        external_subject(:quantumse_repetition, :recovery_application_error,
            "hard_sparse_recovery_path"; qubits=950,
            trigger_index=877, wrong_index=113),
    ),
    external_bug_config(
        "EXT-CSS-DEC-H01",
        external_subject(:steane_css, :decoder_decision_error,
            "hard_css_adapter_path"; qubits=7,
            trigger_index=13, wrong_index=4),
    ),
    external_bug_config(
        "EXT-STIM-RND-H01",
        external_subject(:stim_detector, :repeated_round_control_error,
            "hard_detector_history_path"; qubits=320, rounds=4,
            trigger_index=997, wrong_index=511),
    ),
]

const ALL_EXTERNAL_SUBJECT_CONFIGS = [
    EXTERNAL_SUBJECT_CONFIGS...,
    HARD_EXTERNAL_SUBJECT_CONFIGS...,
]

const BASE_CLEAN_CONFIGS = [
    clean_config("bitflip_clean", BitFlipSubject(:clean), 8),
    clean_config("phaseflip_clean", PhaseFlipSubject(:clean), 8),
    clean_config("steane_css_clean", SteaneSubject(:clean), 40),
    clean_config("surface_d3_x_memory_clean", SurfaceSubject(:clean), 50),
    clean_config("repetition_d5_clean", RepetitionSubject(5, :clean), 12),
    clean_config("round_repetition_d3_r2_clean", RoundRepetitionSubject(3, 2, :clean), 8),
    clean_config("coverage_challenge_clean", coverage_challenge_subject(), 8),
]

const SYNDROME_BUG_CONFIGS = [
    bug_config(
        "bitflip_syndrome_wiring_bug",
        BitFlipSubject(:syndrome_wiring_bug),
        8,
        bug_meta("SYN-001", "three_qubit_bitflip", 3, "syndrome_extraction_wiring",
            "swapped_syndrome_bit", "syndrome", residual_oracles();
            actual_decoder="q3", reference_decoder="q2",
            actual_recovery="X@q3", reference_recovery="X@q2",
            notes="s12 observes x1 xor x3 instead of the reference check"),
    ),
    wrapped_bug_config("syndrome_wrong_support_bitflip_q1", BitFlipSubject(:syndrome_wiring_bug), 8,
        bug_meta("SYN-002", "three_qubit_bitflip", 3, "syndrome_extraction_wiring",
            "wrong_stabilizer_check_support", "syndrome", residual_oracles();
            actual_decoder="q3", reference_decoder="q2",
            actual_recovery="X@q3", reference_recovery="X@q2")),
    wrapped_bug_config("syndrome_swapped_bitflip_q1", BitFlipSubject(:syndrome_wiring_bug), 8,
        bug_meta("SYN-003", "three_qubit_bitflip", 3, "syndrome_extraction_wiring",
            "swapped_syndrome_bit", "syndrome", residual_oracles();
            actual_decoder="q3", reference_decoder="q2",
            actual_recovery="X@q3", reference_recovery="X@q2")),
    wrapped_bug_config("syndrome_wrong_support_phaseflip_q1", BitFlipSubject(:syndrome_wiring_bug), 8,
        bug_meta("SYN-004", "three_qubit_phaseflip", 3, "syndrome_extraction_wiring",
            "wrong_stabilizer_check_support", "syndrome", residual_oracles();
            actual_decoder="q3", reference_decoder="q2",
            actual_recovery="X@q3", reference_recovery="X@q2")),
    wrapped_bug_config("syndrome_swapped_repetition_edge", BitFlipSubject(:syndrome_wiring_bug), 8,
        bug_meta("SYN-005", "repetition_code", 5, "syndrome_extraction_wiring",
            "swapped_syndrome_bit", "syndrome", residual_oracles();
            actual_decoder="q3", reference_decoder="q2",
            actual_recovery="X@q3", reference_recovery="X@q2")),
    wrapped_bug_config("syndrome_scaled_support_n25", BitFlipSubject(:syndrome_wiring_bug), 8,
        bug_meta("SYN-006", "scaled_repetition_control", 25, "syndrome_extraction_wiring",
            "wrong_stabilizer_check_support", "syndrome", residual_oracles();
            actual_decoder="q3", reference_decoder="q2",
            actual_recovery="X@q3", reference_recovery="X@q2",
            notes="scaled benchmark instance for class-balance coverage")),
    wrapped_bug_config("syndrome_scaled_swap_n50", BitFlipSubject(:syndrome_wiring_bug), 8,
        bug_meta("SYN-007", "scaled_repetition_control", 50, "syndrome_extraction_wiring",
            "swapped_syndrome_bit", "syndrome", residual_oracles();
            actual_decoder="q3", reference_decoder="q2",
            actual_recovery="X@q3", reference_recovery="X@q2",
            notes="scaled benchmark instance for class-balance coverage")),
]

const MEASUREMENT_BUG_CONFIGS = [
    bug_config(
        "bitflip_measurement_misuse",
        BitFlipSubject(:measurement_misuse),
        8,
        bug_meta("MEA-001", "three_qubit_bitflip", 3, "measurement_result_misuse",
            "wrong_measurement_register_read", "measurement_result", residual_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1"),
    ),
    wrapped_bug_config("measurement_stale_s23_bitflip", BitFlipSubject(:measurement_misuse), 8,
        bug_meta("MEA-002", "three_qubit_bitflip", 3, "measurement_result_misuse",
            "stale_measurement_value_reuse", "measurement_result", residual_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1")),
    wrapped_bug_config("measurement_overwrite_bitflip", BitFlipSubject(:measurement_misuse), 8,
        bug_meta("MEA-003", "three_qubit_bitflip", 3, "measurement_result_misuse",
            "overwritten_measurement_result", "measurement_result", residual_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1")),
    wrapped_bug_config("measurement_wrong_register_round", BitFlipSubject(:measurement_misuse), 8,
        bug_meta("MEA-004", "round_repetition_code", 6, "measurement_result_misuse",
            "wrong_measurement_register_read", "measurement_result", residual_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1")),
    wrapped_bug_config("measurement_stale_history_n25", BitFlipSubject(:measurement_misuse), 8,
        bug_meta("MEA-005", "scaled_repetition_control", 25, "measurement_result_misuse",
            "stale_measurement_value_reuse", "measurement_result", residual_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1",
            notes="scaled benchmark instance for class-balance coverage")),
    wrapped_bug_config("measurement_overwrite_history_n50", BitFlipSubject(:measurement_misuse), 8,
        bug_meta("MEA-006", "scaled_repetition_control", 50, "measurement_result_misuse",
            "overwritten_measurement_result", "measurement_result", residual_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1",
            notes="scaled benchmark instance for class-balance coverage")),
]

const DECODER_BUG_CONFIGS = [
    bug_config("bitflip_buggy_decoder", BitFlipSubject(:buggy_decoder), 8,
        bug_meta("DEC-001", "three_qubit_bitflip", 3, "decoder_decision_error",
            "decoder_table_entry_swap", "decoder", decoder_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1")),
    bug_config("bitflip_priority_decoder_bug", BitFlipSubject(:priority_decoder_bug), 8,
        bug_meta("DEC-012", "three_qubit_bitflip", 5, "decoder_decision_error",
            "decoder_table_entry_swap", "decoder", decoder_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1",
            notes="priority-order decoder variant with neutral decoy guards")),
    bug_config("phaseflip_buggy_decoder", PhaseFlipSubject(:buggy_decoder), 8,
        bug_meta("DEC-002", "three_qubit_phaseflip", 3, "decoder_decision_error",
            "decoder_table_entry_swap", "decoder", decoder_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="Z@q2", reference_recovery="Z@q1")),
    bug_config("steane_css_buggy_decoder", SteaneSubject(:buggy_decoder), 8,
        bug_meta("DEC-003", "steane_css_code", 7, "decoder_decision_error",
            "decoder_table_entry_swap", "decoder", decoder_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1")),
    bug_config("steane_css_z_decoder_bug", SteaneSubject(:z_decoder_bug), 8,
        bug_meta("DEC-004", "steane_css_code", 7, "decoder_decision_error",
            "decoder_table_entry_swap", "decoder", decoder_oracles();
            actual_decoder="Z:q2", reference_decoder="Z:q1",
            actual_recovery="Z@q2", reference_recovery="Z@q1")),
    bug_config("surface_d3_x_memory_buggy_decoder", SurfaceSubject(:buggy_decoder), 8,
        bug_meta("DEC-005", "surface_code_kernel", 9, "decoder_decision_error",
            "decoder_table_entry_swap", "decoder", decoder_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1")),
    bug_config("surface_d3_z_memory_buggy_decoder", SurfaceSubject(:z_decoder_bug), 8,
        bug_meta("DEC-006", "surface_code_kernel", 9, "decoder_decision_error",
            "decoder_table_entry_swap", "decoder", decoder_oracles();
            actual_decoder="Z:q2", reference_decoder="Z:q1",
            actual_recovery="Z@q2", reference_recovery="Z@q1")),
    bug_config("repetition_d5_decoder_neighbor_bug", RepetitionSubject(5, :decoder_neighbor_bug), 8,
        bug_meta("DEC-007", "repetition_code", 5, "decoder_decision_error",
            "decoder_neighbor_mapping", "decoder", decoder_oracles();
            actual_decoder="q2", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1")),
    priority_bug_config("priority_decoder_challenge", "DEC-008"; decoys=7),
    priority_bug_config("path_sensitive_decoder_challenge_a", "DEC-009"; decoys=8),
    priority_bug_config("path_sensitive_decoder_challenge_b", "DEC-010"; decoys=9),
    priority_bug_config("path_sensitive_decoder_challenge_c", "DEC-011"; decoys=10),
    priority_bug_config("path_sensitive_decoder_challenge_d", "DEC-013"; decoys=11),
    priority_bug_config("path_sensitive_decoder_challenge_e", "DEC-014"; decoys=12),
    LARGE_DECODER_TABLE_BUG_CONFIGS...,
]

const UNHANDLED_BUG_CONFIGS = [
    wrapped_bug_config("bitflip_unhandled_syndrome_q1", BitFlipSubject(:clean), 8,
        bug_meta("UNH-001", "three_qubit_bitflip", 3, "unhandled_syndrome",
            "missing_decoder_arm", "decoder", unhandled_syndrome_oracles();
            actual_decoder="missing", reference_decoder="q1",
            actual_recovery="missing@missing", reference_recovery="X@q1"),
        trigger_decoder="q1", actual_decoder="missing",
        recovery_override=benchmark_recovery("missing", "missing"),
        verdict_overrides=unhandled_verdicts()),
    wrapped_bug_config("phaseflip_unhandled_syndrome_q1", PhaseFlipSubject(:clean), 8,
        bug_meta("UNH-002", "three_qubit_phaseflip", 3, "unhandled_syndrome",
            "missing_decoder_arm", "decoder", unhandled_syndrome_oracles();
            actual_decoder="missing", reference_decoder="q1",
            actual_recovery="missing@missing", reference_recovery="Z@q1"),
        trigger_decoder="q1", actual_decoder="missing",
        recovery_override=benchmark_recovery("missing", "missing"),
        verdict_overrides=unhandled_verdicts()),
    wrapped_bug_config("repetition_d5_unhandled_edge", RepetitionSubject(5, :clean), 8,
        bug_meta("UNH-003", "repetition_code", 5, "unhandled_syndrome",
            "missing_decoder_arm", "decoder", unhandled_syndrome_oracles();
            actual_decoder="uncorrectable", reference_decoder="q1",
            actual_recovery="missing@uncorrectable", reference_recovery="X@q1"),
        trigger_decoder="q1", actual_decoder="uncorrectable",
        recovery_override=benchmark_recovery("missing", "uncorrectable"),
        verdict_overrides=unhandled_verdicts()),
    wrapped_bug_config("path_sensitive_unhandled_syndrome_challenge", BitFlipSubject(:clean), 8,
        bug_meta("UNH-004", "PathSensitiveChallenges", 3, "unhandled_syndrome",
            "missing_decoder_arm", "decoder", unhandled_syndrome_oracles();
            actual_decoder="missing", reference_decoder="q1",
            actual_recovery="missing@missing", reference_recovery="X@q1",
            path_sensitive=true),
        trigger_decoder="q1", actual_decoder="missing",
        recovery_override=benchmark_recovery("missing", "missing"),
        verdict_overrides=unhandled_verdicts()),
]

const RECOVERY_BUG_CONFIGS = [
    bug_config("bitflip_wrong_recovery_target", BitFlipSubject(:wrong_recovery_target), 8,
        bug_meta("REC-001", "three_qubit_bitflip", 3, "recovery_application_error",
            "wrong_recovery_target", "recovery", residual_oracles();
            actual_decoder="q1", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1")),
    bug_config("bitflip_missing_recovery_branch", BitFlipSubject(:missing_recovery_branch), 8,
        bug_meta("REC-002", "three_qubit_bitflip", 3, "recovery_application_error",
            "missing_recovery_branch", "recovery", missing_recovery_oracles();
            actual_decoder="q1", reference_decoder="q1",
            actual_recovery="missing@missing", reference_recovery="X@q1")),
    bug_config("phaseflip_wrong_recovery_target", PhaseFlipSubject(:wrong_recovery_target), 8,
        bug_meta("REC-003", "three_qubit_phaseflip", 3, "recovery_application_error",
            "wrong_recovery_target", "recovery", residual_oracles();
            actual_decoder="q1", reference_decoder="q1",
            actual_recovery="Z@q2", reference_recovery="Z@q1")),
    bug_config("repetition_d5_wrong_recovery_target", RepetitionSubject(5, :wrong_recovery_target), 8,
        bug_meta("REC-004", "repetition_code", 5, "recovery_application_error",
            "wrong_recovery_target", "recovery", residual_oracles();
            actual_decoder="q1", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1")),
    wrapped_bug_config("bitflip_wrong_pauli_recovery", BitFlipSubject(:clean), 8,
        bug_meta("REC-005", "three_qubit_bitflip", 3, "recovery_application_error",
            "wrong_pauli_recovery", "recovery", residual_oracles();
            actual_decoder="q1", reference_decoder="q1",
            actual_recovery="Z@q1", reference_recovery="X@q1"),
        trigger_decoder="q1",
        recovery_override=benchmark_recovery("Z", "q1"),
        verdict_overrides=recovery_verdicts()),
    wrapped_bug_config("path_sensitive_recovery_condition_challenge", RepetitionSubject(5, :clean), 8,
        bug_meta("REC-006", "PathSensitiveChallenges", 5, "recovery_application_error",
            "recovery_applied_under_wrong_condition", "recovery", residual_oracles();
            actual_decoder="q1", reference_decoder="q1",
            actual_recovery="X@q2", reference_recovery="X@q1",
            path_sensitive=true),
        trigger_decoder="q1",
        recovery_override=benchmark_recovery("X", "q2"),
        verdict_overrides=recovery_verdicts()),
]

const ROUND_BUG_CONFIGS = [
    bug_config("round_repetition_d3_r2_history_drop_bug", RoundRepetitionSubject(3, 2, :history_drop_bug), 8,
        bug_meta("RND-001", "round_repetition_code", 6, "repeated_round_control_error",
            "missing_syndrome_history_update", "repeated_round_control", round_decoder_oracles();
            actual_decoder="r2_q1", reference_decoder="r1_q1",
            actual_recovery="X@q1:round=2", reference_recovery="X@q1:round=1")),
    bug_config("round_repetition_d3_r2_inconsistent_control_bug", RoundRepetitionSubject(3, 2, :inconsistent_control_bug), 8,
        bug_meta("RND-002", "round_repetition_code", 6, "repeated_round_control_error",
            "path_sensitive_relational_control", "repeated_round_control", relational_oracles();
            actual_decoder="r2_q1", reference_decoder="r2_q1",
            actual_recovery="X@q1:round=2", reference_recovery="X@q1:round=2",
            path_sensitive=true)),
    wrapped_bug_config("relational_round_challenge", RoundRepetitionSubject(3, 2, :inconsistent_control_bug), 8,
        bug_meta("RND-003", "PathSensitiveChallenges", 6, "repeated_round_control_error",
            "path_sensitive_relational_control", "repeated_round_control", relational_oracles();
            actual_decoder="r2_q1", reference_decoder="r2_q1",
            actual_recovery="X@q1:round=2", reference_recovery="X@q1:round=2",
            path_sensitive=true)),
    wrapped_bug_config("round_repetition_d5_r2_history_drop_bug", RoundRepetitionSubject(5, 2, :history_drop_bug), 10,
        bug_meta("RND-004", "round_repetition_code", 10, "repeated_round_control_error",
            "off_by_one_round_count", "repeated_round_control", round_decoder_oracles();
            actual_decoder="r2_q1", reference_decoder="r1_q1",
            actual_recovery="X@q1:round=2", reference_recovery="X@q1:round=1")),
    wrapped_bug_config("round_repetition_d3_r3_stale_history_bug", RoundRepetitionSubject(3, 2, :history_drop_bug), 8,
        bug_meta("RND-005", "round_repetition_code", 9, "repeated_round_control_error",
            "stale_syndrome_history_reuse", "repeated_round_control", round_decoder_oracles();
            actual_decoder="r2_q1", reference_decoder="r1_q1",
            actual_recovery="X@q1:round=2", reference_recovery="X@q1:round=1")),
    wrapped_bug_config("path_sensitive_round_history_challenge", RoundRepetitionSubject(3, 2, :history_drop_bug), 8,
        bug_meta("RND-006", "PathSensitiveChallenges", 6, "repeated_round_control_error",
            "missing_syndrome_history_update", "repeated_round_control", round_decoder_oracles();
            actual_decoder="r2_q1", reference_decoder="r1_q1",
            actual_recovery="X@q1:round=2", reference_recovery="X@q1:round=1",
            path_sensitive=true)),
]

const PAPER_SUBJECT_CONFIGS = [
    BASE_CLEAN_CONFIGS...,
    SYNDROME_BUG_CONFIGS...,
    MEASUREMENT_BUG_CONFIGS...,
    DECODER_BUG_CONFIGS...,
    UNHANDLED_BUG_CONFIGS...,
    RECOVERY_BUG_CONFIGS...,
    WEIGHT_TWO_BUG_CONFIGS...,
    ROUND_BUG_CONFIGS...,
    HISTORY_CHALLENGE_BUG_CONFIGS...,
    FAILURE_ADJACENT_SIBLING_BUG_CONFIGS...,
    MINIMIZATION_STRESS_BUG_CONFIGS...,
]

const EXTENDED_CHALLENGE_SUBJECT_CONFIGS = [
    PAPER_SUBJECT_CONFIGS...,
    HARD_LARGE_DECODER_TABLE_BUG_CONFIGS...,
    HARD_WEIGHT_TWO_BUG_CONFIGS...,
    WEIGHT_THREE_BUG_CONFIGS...,
    HARD_HISTORY_CHALLENGE_BUG_CONFIGS...,
]

const ALL_SUBJECT_CONFIGS = [
    EXTENDED_CHALLENGE_SUBJECT_CONFIGS...,
    ALL_EXTERNAL_SUBJECT_CONFIGS...,
]

const SUPPORTED_SUBJECT_MODES = Dict{Symbol,Dict{String,Symbol}}(
    :bitflip => Dict(
        "clean" => :clean,
        "syndrome_wiring_bug" => :syndrome_wiring_bug,
        "measurement_misuse" => :measurement_misuse,
        "buggy_decoder" => :buggy_decoder,
        "buggy_decoder_table" => :buggy_decoder,
        "priority_decoder_bug" => :priority_decoder_bug,
        "wrong_recovery_target" => :wrong_recovery_target,
        "missing_recovery_branch" => :missing_recovery_branch,
    ),
    :phaseflip => Dict(
        "clean" => :clean,
        "buggy_decoder" => :buggy_decoder,
        "buggy_decoder_table" => :buggy_decoder,
        "wrong_recovery_target" => :wrong_recovery_target,
    ),
    :steane => Dict(
        "clean" => :clean,
        "buggy_decoder" => :buggy_decoder,
        "buggy_decoder_table" => :buggy_decoder,
        "z_decoder_bug" => :z_decoder_bug,
        "z_decoder_bug_table" => :z_decoder_bug,
    ),
    :surface => Dict(
        "clean" => :clean,
        "buggy_decoder" => :buggy_decoder,
        "buggy_decoder_table" => :buggy_decoder,
        "z_decoder_bug" => :z_decoder_bug,
        "z_decoder_bug_table" => :z_decoder_bug,
    ),
    :repetition => Dict(
        "clean" => :clean,
        "decoder_neighbor_bug" => :decoder_neighbor_bug,
        "wrong_recovery_target" => :wrong_recovery_target,
    ),
    :round_repetition => Dict(
        "clean" => :clean,
        "history_drop_bug" => :history_drop_bug,
        "inconsistent_control_bug" => :inconsistent_control_bug,
    ),
    :large_decoder_table => Dict(
        "sparse_decoder_table_bug" => :sparse_decoder_table_bug,
    ),
    :weight_two => Dict(
        "clean" => :clean,
        "decoder_pair_bug" => :decoder_pair_bug,
        "recovery_pair_bug" => :recovery_pair_bug,
        "unhandled_pair_bug" => :unhandled_pair_bug,
    ),
    :weight_three => Dict(
        "clean" => :clean,
        "decoder_triple_bug" => :decoder_triple_bug,
        "recovery_triple_bug" => :recovery_triple_bug,
        "unhandled_triple_bug" => :unhandled_triple_bug,
    ),
    :history_challenge => Dict(
        "clean" => :clean,
        "history_drop_bug" => :history_drop_bug,
        "stale_history_reuse_bug" => :stale_history_reuse_bug,
        "off_by_one_round_bug" => :off_by_one_round_bug,
        "inconsistent_control_bug" => :inconsistent_control_bug,
        "equivalent_current_control_bug" => :equivalent_current_control_bug,
        "missing_reset_bug" => :missing_reset_bug,
    ),
    :failure_adjacent_sibling => Dict(
        "decoder" => :decoder_decision_error,
        "recovery" => :recovery_application_error,
        "unhandled" => :unhandled_syndrome,
    ),
    :minimization_stress => Dict(
        "decoder" => :decoder_decision_error,
        "recovery" => :recovery_application_error,
        "unhandled" => :unhandled_syndrome,
    ),
    :path_sensitive_challenges => Dict(
        "coverage_challenge_clean" => :coverage_challenge_clean,
        "priority_decoder_challenge" => :priority_decoder_challenge,
        "relational_round_challenge" => :relational_round_challenge,
    ),
    :external_subjects => Dict(
        "decoder_decision_error" => :decoder_decision_error,
        "recovery_application_error" => :recovery_application_error,
        "unhandled_syndrome" => :unhandled_syndrome,
        "repeated_round_control_error" => :repeated_round_control_error,
    ),
)

"""
    paper_subject_configs()

Return the formal 85-configuration paper/AE benchmark registry. External or
extra hard stress rows are intentionally kept in separate accessors so generated
registry tables and external-validation claims do not mix evaluation
populations.
"""
paper_subject_configs() = PAPER_SUBJECT_CONFIGS

"""
    external_subject_configs()

Return the 15 external/adapted QECC validation subjects reported separately
from the generated paper registry.
"""
external_subject_configs() = EXTERNAL_SUBJECT_CONFIGS

"""
    extended_challenge_subject_configs()

Return optional hard generated stress subjects in addition to the formal paper
registry. These rows are useful for follow-up hard-only pilots but are not
counted in the paper's 85-configuration registry.
"""
extended_challenge_subject_configs() = EXTENDED_CHALLENGE_SUBJECT_CONFIGS

"""
    hard_external_subject_configs()

Return optional hard external/adapted subjects for follow-up stress runs.
"""
hard_external_subject_configs() = HARD_EXTERNAL_SUBJECT_CONFIGS

"""
    all_subject_configs()

Return every built-in subject configuration: formal registry rows, optional
hard generated stress rows, and optional external/adapted rows.
"""
all_subject_configs() = ALL_SUBJECT_CONFIGS

paper_subject_names() =
    [subject_name(config.subject) for config in paper_subject_configs()]

function paper_subject_config_by_name(name::AbstractString)
    requested = String(name)
    for config in paper_subject_configs()
        if config.label == requested || subject_name(config.subject) == requested
            return config
        end
    end
    error("unknown paper subject: $(name)")
end

supported_subject_families() =
    [:bitflip, :phaseflip, :steane, :surface, :repetition, :round_repetition,
        :large_decoder_table, :weight_two, :weight_three, :history_challenge,
        :failure_adjacent_sibling, :minimization_stress,
        :path_sensitive_challenges, :external_subjects]

function supported_subject_modes(family::Symbol)
    haskey(SUPPORTED_SUBJECT_MODES, family) ||
        error("unknown subject family: $(family)")
    return copy(SUPPORTED_SUBJECT_MODES[family])
end

supported_subject_mode_names(family::Symbol) =
    sort!(collect(keys(supported_subject_modes(family))))
