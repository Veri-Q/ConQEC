struct PublicRepoQECCSubject
    name::String
    repo_name::String
    repo_url::String
    repo_commit::String
    source_path::String
    source_lines::String
    source_motif::String
    code_kind::Symbol
    bug_mode::Symbol
    qubits::Int
    rounds::Int
    public_arms::Int
    neutral_decoys::Int
    trigger_index::Int
    wrong_index::Int
    budget::Int
    tesseract_family::String
    stim_line_count::Int
    stim_byte_count::Int
    stim_detector_count::Int
    stim_observable_count::Int
    stim_tick_count::Int
    arm_branch_mode::Symbol
    priority_arm_policy::String
    priority_arm_indices::Vector{Int}
    trigger_selection_policy::String
    bug_assignment_policy::String
end

function normalize_public_priority_arms(public_arms::Integer,
    priority_arm_indices::AbstractVector{<:Integer})

    public_arms > 0 || error("public_arms must be positive")
    normalized = sort!(unique(Int(idx) for idx in priority_arm_indices))
    for idx in normalized
        1 <= idx <= public_arms || error("priority arm index outside public arms")
    end
    return normalized
end

function PublicRepoQECCSubject(name::AbstractString;
    repo_name::AbstractString,
    repo_url::AbstractString,
    repo_commit::AbstractString,
    source_path::AbstractString,
    source_lines::AbstractString,
    source_motif::AbstractString,
    code_kind::Symbol,
    bug_mode::Symbol,
    qubits::Integer,
    rounds::Integer=1,
    public_arms::Integer,
    neutral_decoys::Integer=public_arms,
    trigger_index::Integer,
    wrong_index::Integer,
    budget::Integer=8,
    tesseract_family::AbstractString="",
    stim_line_count::Integer=0,
    stim_byte_count::Integer=0,
    stim_detector_count::Integer=0,
    stim_observable_count::Integer=0,
    stim_tick_count::Integer=0,
    arm_branch_mode::Symbol=:single_trigger,
    priority_arm_policy::AbstractString="single_trigger",
    priority_arm_indices::AbstractVector{<:Integer}=Int[],
    trigger_selection_policy::AbstractString="fixed_public_motif",
    bug_assignment_policy::AbstractString="fixed_public_motif")

    code_kind in (:qecsim_planar, :qecsim_toric, :stim_detector) ||
        error("unsupported public-repo code kind: $(code_kind)")
    bug_mode in (:syndrome_extraction_wiring, :measurement_result_misuse,
        :decoder_decision_error, :recovery_application_error,
        :unhandled_syndrome, :repeated_round_control_error) ||
        error("unsupported public-repo bug mode: $(bug_mode)")
    public_arms > 0 || error("public_arms must be positive")
    neutral_decoys >= 0 || error("neutral_decoys must be non-negative")
    1 <= trigger_index <= public_arms || error("trigger_index outside public arms")
    1 <= wrong_index <= public_arms || error("wrong_index outside public arms")
    wrong_index != trigger_index || error("wrong_index must differ from trigger_index")
    qubits > 0 || error("qubits must be positive")
    rounds > 0 || error("rounds must be positive")
    budget > 0 || error("budget must be positive")
    stim_line_count >= 0 || error("stim_line_count must be non-negative")
    stim_byte_count >= 0 || error("stim_byte_count must be non-negative")
    stim_detector_count >= 0 || error("stim_detector_count must be non-negative")
    stim_observable_count >= 0 || error("stim_observable_count must be non-negative")
    stim_tick_count >= 0 || error("stim_tick_count must be non-negative")
    arm_branch_mode in (:single_trigger, :expanded_detector_arms) ||
        error("unsupported arm branch mode: $(arm_branch_mode)")
    priority_arms = normalize_public_priority_arms(public_arms, priority_arm_indices)
    if arm_branch_mode == :expanded_detector_arms && isempty(priority_arms)
        error("expanded detector-arm mode requires at least one priority arm")
    end

    return PublicRepoQECCSubject(
        String(name),
        String(repo_name),
        String(repo_url),
        String(repo_commit),
        String(source_path),
        String(source_lines),
        String(source_motif),
        code_kind,
        bug_mode,
        Int(qubits),
        Int(rounds),
        Int(public_arms),
        Int(neutral_decoys),
        Int(trigger_index),
        Int(wrong_index),
        Int(budget),
        String(tesseract_family),
        Int(stim_line_count),
        Int(stim_byte_count),
        Int(stim_detector_count),
        Int(stim_observable_count),
        Int(stim_tick_count),
        arm_branch_mode,
        String(priority_arm_policy),
        priority_arms,
        String(trigger_selection_policy),
        String(bug_assignment_policy),
    )
end

public_repo_subject_prefix(subject::PublicRepoQECCSubject) =
    replace(lowercase(subject.name), r"[^a-z0-9]+" => "_")

public_repo_decoy_var(subject::PublicRepoQECCSubject, idx::Integer) =
    Symbol(public_repo_subject_prefix(subject), "_ctrl_", lpad(string(idx), 4, '0'))

public_repo_arm_var(subject::PublicRepoQECCSubject, idx::Integer) =
    Symbol(public_repo_subject_prefix(subject), "_arm_", lpad(string(idx), 4, '0'))

function public_repo_fault_vars(subject::PublicRepoQECCSubject)
    decoys = [public_repo_decoy_var(subject, idx) for idx in 1:subject.neutral_decoys]
    arms = [public_repo_arm_var(subject, idx) for idx in 1:subject.public_arms]
    return vcat(decoys, arms)
end

public_repo_syndrome_bits(subject::PublicRepoQECCSubject) =
    max(1, ceil(Int, log2(subject.public_arms + 1)))

function public_repo_hardness_bin(budget::Integer, admissible::Integer)
    ratio = Float64(budget) / Float64(max(admissible, 1))
    ratio > 0.5 && return "Easy"
    0.05 <= ratio <= 0.2 && return "Medium"
    ratio < 0.01 && return "Hard"
    return "Medium"
end

function public_repo_label(subject::PublicRepoQECCSubject, index::Integer)
    idx = Int(index)
    idx == 0 && return Dict{String,Any}(
        "decoder" => "none",
        "pauli" => "I",
        "target" => "none",
        "round" => nothing,
    )
    if subject.code_kind == :qecsim_planar
        return Dict{String,Any}(
            "decoder" => "planar_site_$(idx)",
            "pauli" => "Y",
            "target" => "p$(idx)",
            "round" => nothing,
        )
    elseif subject.code_kind == :qecsim_toric
        return Dict{String,Any}(
            "decoder" => "toric_plaquette_$(idx)",
            "pauli" => "X",
            "target" => "t$(idx)",
            "round" => nothing,
        )
    end
    round = mod(idx - 1, subject.rounds) + 1
    return Dict{String,Any}(
        "decoder" => "detector_event_$(idx)",
        "pauli" => "X",
        "target" => "d$(idx)",
        "round" => round,
    )
end

function public_repo_recovery_action(label::AbstractDict)
    action = Dict{String,Any}(
        "pauli" => string(label["pauli"]),
        "target" => string(label["target"]),
        "source" => "public_repo_adapter",
    )
    round = get(label, "round", nothing)
    round === nothing || (action["inferred_round"] = round)
    return action
end

function public_repo_action_signature(action::AbstractDict)
    base = string(get(action, "pauli", "unknown"), "@",
        get(action, "target", "unknown"))
    round = get(action, "inferred_round", nothing)
    round === nothing && return base
    return string(base, ":round=", round)
end

function public_repo_active_index(subject::PublicRepoQECCSubject,
    model::AbstractDict)

    for idx in 1:subject.public_arms
        model_bool(model, public_repo_arm_var(subject, idx)) && return idx
    end
    return 0
end

function public_repo_outputs(subject::PublicRepoQECCSubject, active_index::Integer)
    expected_label = public_repo_label(subject, active_index)
    actual_label = expected_label
    failed = active_index == subject.trigger_index
    actual_decoder = string(expected_label["decoder"])
    expected_decoder = string(expected_label["decoder"])
    expected_recovery = public_repo_recovery_action(expected_label)
    actual_recovery = expected_recovery
    if failed && subject.bug_mode == :syndrome_extraction_wiring
        actual_label = public_repo_label(subject, subject.wrong_index)
        actual_decoder = string(actual_label["decoder"])
        actual_recovery = public_repo_recovery_action(actual_label)
    elseif failed && subject.bug_mode == :measurement_result_misuse
        actual_label = public_repo_label(subject, subject.wrong_index)
        actual_decoder = string(actual_label["decoder"])
        actual_recovery = public_repo_recovery_action(actual_label)
    elseif failed && subject.bug_mode == :decoder_decision_error
        actual_label = public_repo_label(subject, subject.wrong_index)
        actual_decoder = string(actual_label["decoder"])
        actual_recovery = public_repo_recovery_action(actual_label)
    elseif failed && subject.bug_mode == :recovery_application_error
        actual_label = public_repo_label(subject, subject.wrong_index)
        actual_recovery = public_repo_recovery_action(actual_label)
    elseif failed && subject.bug_mode == :unhandled_syndrome
        actual_decoder = "missing"
        actual_recovery = Dict{String,Any}(
            "pauli" => "missing",
            "target" => "missing",
            "source" => "public_repo_adapter",
        )
    elseif failed && subject.bug_mode == :repeated_round_control_error
        actual_label = public_repo_label(subject, subject.wrong_index)
        actual_decoder = string(actual_label["decoder"])
        actual_recovery = public_repo_recovery_action(actual_label)
    end
    return actual_decoder, expected_decoder, actual_recovery, expected_recovery, failed
end

function public_repo_trigger_stage(subject::PublicRepoQECCSubject)
    subject.bug_mode == :syndrome_extraction_wiring && return :syndrome
    subject.bug_mode == :measurement_result_misuse && return :measurement_result
    subject.bug_mode == :recovery_application_error && return :recovery
    subject.bug_mode == :repeated_round_control_error && return :repeated_round_control
    return :decoder
end

public_repo_priority_arm_set(subject::PublicRepoQECCSubject) =
    Set(subject.priority_arm_indices)

function public_repo_arm_branch_stage(subject::PublicRepoQECCSubject,
    idx::Integer,
    priority_arms::AbstractSet)

    idx in priority_arms && return public_repo_trigger_stage(subject)
    return :fault
end

function public_repo_bug_class(subject::PublicRepoQECCSubject)
    subject.bug_mode == :syndrome_extraction_wiring && return "syndrome_extraction_wiring"
    subject.bug_mode == :measurement_result_misuse && return "measurement_result_misuse"
    subject.bug_mode == :decoder_decision_error && return "decoder_decision_error"
    subject.bug_mode == :recovery_application_error && return "recovery_application_error"
    subject.bug_mode == :unhandled_syndrome && return "unhandled_syndrome"
    return "repeated_round_control_error"
end

function public_repo_mutation_operator(subject::PublicRepoQECCSubject)
    subject.bug_mode == :syndrome_extraction_wiring && return "wrong_stabilizer_check_support"
    subject.bug_mode == :measurement_result_misuse && return "stale_measurement_value_reuse"
    subject.bug_mode == :decoder_decision_error && return "decoder_table_entry_swap"
    subject.bug_mode == :recovery_application_error && return "wrong_recovery_target"
    subject.bug_mode == :unhandled_syndrome && return "missing_decoder_arm"
    return "path_sensitive_relational_control"
end

function public_repo_divergence(subject::PublicRepoQECCSubject)
    subject.bug_mode == :syndrome_extraction_wiring && return "syndrome"
    subject.bug_mode == :measurement_result_misuse && return "measurement_result"
    subject.bug_mode == :decoder_decision_error && return "decoder"
    subject.bug_mode == :recovery_application_error && return "recovery"
    subject.bug_mode == :unhandled_syndrome && return "decoder"
    return "repeated_round_control"
end

function public_repo_expected_oracles(subject::PublicRepoQECCSubject)
    subject.bug_mode == :syndrome_extraction_wiring &&
        return ["O1_LOGICAL_MISMATCH", "O3_RESIDUAL_CORRECTABLE_ERROR"]
    subject.bug_mode == :measurement_result_misuse &&
        return ["O1_LOGICAL_MISMATCH", "O3_RESIDUAL_CORRECTABLE_ERROR"]
    subject.bug_mode == :decoder_decision_error &&
        return ["O1_LOGICAL_MISMATCH", "O2_DECODER_MISMATCH",
            "O3_RESIDUAL_CORRECTABLE_ERROR"]
    subject.bug_mode == :recovery_application_error &&
        return ["O1_LOGICAL_MISMATCH", "O3_RESIDUAL_CORRECTABLE_ERROR"]
    subject.bug_mode == :unhandled_syndrome &&
        return ["O1_LOGICAL_MISMATCH", "O2_DECODER_MISMATCH",
            "O3_RESIDUAL_CORRECTABLE_ERROR", "O4_DEAD_RECOVERY_BRANCH"]
    return ["O5_INCONSISTENT_CONTROL"]
end

function public_repo_subject_metadata(subject::PublicRepoQECCSubject)
    vars = public_repo_fault_vars(subject)
    admissible = subject.neutral_decoys + subject.public_arms + 1
    ratio = Float64(subject.budget) / Float64(max(admissible, 1))
    trigger = string(public_repo_arm_var(subject, subject.trigger_index))
    wrong = string(public_repo_arm_var(subject, subject.wrong_index))
    return Dict{String,Any}(
        "subject_family" => "PublicRepoQECC",
        "benchmark_family" => "PublicRepoQECC",
        "public_repo_derived" => true,
        "repo_name" => subject.repo_name,
        "repo_url" => subject.repo_url,
        "repo_commit" => subject.repo_commit,
        "source_path" => subject.source_path,
        "source_lines" => subject.source_lines,
        "source_motif" => subject.source_motif,
        "adapter_mapping" =>
            "public test motif supplies decoder/detector arms; neutral control branches model non-QECC branch-order budget pressure",
        "code_kind" => string(subject.code_kind),
        "bug_mode" => string(subject.bug_mode),
        "path_sensitive" => true,
        "qubits" => subject.qubits,
        "fault_variables" => length(vars),
        "public_decoder_or_detector_arms" => subject.public_arms,
        "neutral_control_branches" => subject.neutral_decoys,
        "max_fault_weight" => 1,
        "admissible_assignments" => admissible,
        "syndrome_bits" => public_repo_syndrome_bits(subject),
        "reachable_syndromes" => subject.public_arms + 1,
        "decoder_arms" => subject.public_arms,
        "recovery_actions" => subject.public_arms + 1,
        "rounds" => subject.rounds,
        "tesseract_family" => subject.tesseract_family,
        "stim_line_count" => subject.stim_line_count,
        "stim_byte_count" => subject.stim_byte_count,
        "stim_detector_count" => subject.stim_detector_count,
        "stim_observable_count" => subject.stim_observable_count,
        "stim_tick_count" => subject.stim_tick_count,
        "arm_branch_mode" => string(subject.arm_branch_mode),
        "priority_arm_policy" => subject.priority_arm_policy,
        "priority_arm_count" => length(subject.priority_arm_indices),
        "trigger_selection_policy" => subject.trigger_selection_policy,
        "bug_assignment_policy" => subject.bug_assignment_policy,
        "history_states" => subject.rounds > 1 ? admissible : 0,
        "failing_assignments" => 1,
        "seeded_failing_assignments" => 1,
        "estimated_bug_probability" => 1.0 / Float64(admissible),
        "bug_hit_probability" => 1.0 / Float64(admissible),
        "budget" => subject.budget,
        "recommended_budget" => subject.budget,
        "exhaustibility_ratio" => ratio,
        "hardness_bin" => public_repo_hardness_bin(subject.budget, admissible),
        "trigger_faults" => [trigger],
        "interesting_faults" => [trigger],
        "wrong_faults" => [wrong],
        "boring_faults" => [
            string(public_repo_decoy_var(subject, idx))
            for idx in 1:min(subject.neutral_decoys, subject.budget)
        ],
    )
end

function public_repo_bug_metadata(id::AbstractString,
    subject::PublicRepoQECCSubject)

    trigger_label = public_repo_label(subject, subject.trigger_index)
    wrong_label = public_repo_label(subject, subject.wrong_index)
    actual_decoder, expected_decoder, actual_recovery, expected_recovery, _ =
        public_repo_outputs(subject, subject.trigger_index)
    metadata = seeded_bug_metadata(
        bug_id=id,
        subject_family="PublicRepoQECC",
        subject_size=subject.qubits,
        bug_class=public_repo_bug_class(subject),
        mutation_operator=public_repo_mutation_operator(subject),
        path_sensitive=true,
        expected_earliest_divergence=public_repo_divergence(subject),
        expected_oracle_classes=public_repo_expected_oracles(subject),
        expected_actual_decoder=actual_decoder,
        expected_reference_decoder=expected_decoder,
        expected_actual_recovery=public_repo_action_signature(actual_recovery),
        expected_reference_recovery=public_repo_action_signature(expected_recovery),
        expected_min_fault_weight=1,
        notes=string(
            "Public-repository RQ1 motif from ",
            subject.repo_name,
            " ",
            subject.repo_commit,
            " ",
            subject.source_path,
            ":",
            subject.source_lines,
            "; trigger ",
            trigger_label["decoder"],
            " maps against ",
            wrong_label["decoder"],
        ),
    )
    for (key, value) in public_repo_subject_metadata(subject)
        metadata[key] = value
    end
    metadata["benchmark_family"] = "PublicRepoQECC"
    metadata["public_repo_derived"] = true
    return metadata
end

function public_repo_record_syndrome!(trace::ConcolicTrace,
    subject::PublicRepoQECCSubject, active_index::Integer)

    width = public_repo_syndrome_bits(subject)
    for bit in 1:width
        terms = BoolExpr[]
        mask = 1 << (bit - 1)
        for idx in 1:subject.public_arms
            (idx & mask) == 0 && continue
            push!(terms, boolvar(public_repo_arm_var(subject, idx)))
        end
        expr = isempty(terms) ? bconst(false) : bor(terms...)
        value = ((Int(active_index) >> (bit - 1)) & 1) == 1
        record_syndrome!(trace, "s$(bit)", value, expr)
        record_branch!(trace, "syndrome:public_repo_s$(bit)", :syndrome,
            expr, value; path_constraint=false)
    end
    return trace
end

function public_repo_record_verdicts!(trace::ConcolicTrace,
    subject::PublicRepoQECCSubject, failed::Bool)

    class = public_repo_bug_class(subject)
    record_logical_verdict!(trace, "syndrome_mismatch",
        failed && class == "syndrome_extraction_wiring")
    record_logical_verdict!(trace, "measurement_misuse",
        failed && class == "measurement_result_misuse")
    record_logical_verdict!(trace, "decoder_mismatch",
        failed && class in ("decoder_decision_error", "unhandled_syndrome"))
    record_logical_verdict!(trace, "recovery_mismatch",
        failed && class in ("decoder_decision_error", "recovery_application_error",
            "unhandled_syndrome", "syndrome_extraction_wiring",
            "measurement_result_misuse"))
    record_logical_verdict!(trace, "missing_recovery_branch",
        failed && class == "unhandled_syndrome")
    record_logical_verdict!(trace, "history_mismatch",
        failed && class == "repeated_round_control_error")
    record_logical_verdict!(trace, "inconsistent_control",
        failed && class == "repeated_round_control_error")
    record_logical_verdict!(trace, "logical_mismatch",
        failed && class != "repeated_round_control_error")
    record_logical_verdict!(trace, "residual_weight",
        failed && class != "repeated_round_control_error" ? 1 : 0)
    record_logical_verdict!(trace, "oracle_verdict", !failed)
    return trace
end

subject_name(subject::PublicRepoQECCSubject) = subject.name
subject_fault_vars(subject::PublicRepoQECCSubject) = public_repo_fault_vars(subject)
subject_metadata(subject::PublicRepoQECCSubject) = public_repo_subject_metadata(subject)

function run_subject(subject::PublicRepoQECCSubject, input::AbstractDict)
    vars = public_repo_fault_vars(subject)
    model = normalize_assignment(vars, input)
    trace = ConcolicTrace(
        subject.name;
        code_size=subject.qubits,
        distance=subject.code_kind == :stim_detector ? subject.rounds + 2 : 3,
        fault_vars=vars,
        fault_assignments=model,
        metadata=public_repo_subject_metadata(subject),
    )
    active = public_repo_active_index(subject, model)
    public_repo_record_syndrome!(trace, subject, active)

    for idx in 1:subject.neutral_decoys
        var = public_repo_decoy_var(subject, idx)
        record_branch!(trace, "fault:public_repo_control_decoy_$(idx)", :fault,
            boolvar(var), model[var];
            description="public-repo adapter neutral control branch",
            path_constraint=idx <= min(subject.neutral_decoys, subject.budget))
    end
    if subject.arm_branch_mode == :expanded_detector_arms
        priority_arms = public_repo_priority_arm_set(subject)
        for idx in 1:subject.public_arms
            var = public_repo_arm_var(subject, idx)
            priority_arm = idx in priority_arms
            stage = public_repo_arm_branch_stage(subject, idx, priority_arms)
            prefix = priority_arm ? string(stage, ":public_repo_priority_arm_") :
                "fault:public_repo_arm_"
            record_branch!(trace, string(prefix, lpad(string(idx), 4, '0')), stage,
                boolvar(var), model[var];
                description=priority_arm ?
                    "public-repo adapter observable/final-round detector arm" :
                    "public-repo adapter detector arm",
                path_constraint=true)
        end
    else
        trigger = public_repo_arm_var(subject, subject.trigger_index)
        record_branch!(trace, "decoder:public_repo_trigger",
            public_repo_trigger_stage(subject),
            boolvar(trigger), model[trigger];
            description="public-repo motif bug-triggering semantic branch")
    end

    actual, expected, actual_recovery, expected_recovery, failed =
        public_repo_outputs(subject, active)
    record_decoder_decision!(trace, "actual", actual)
    record_decoder_decision!(trace, "expected", expected)
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    trace.metadata["expected_recovery_signature"] =
        public_repo_action_signature(expected_recovery)
    trace.metadata["actual_recovery_signature"] =
        public_repo_action_signature(actual_recovery)
    failed && (trace.metadata["earliest_divergence_stage"] =
        public_repo_divergence(subject))
    public_repo_record_verdicts!(trace, subject, failed)
    return trace
end
