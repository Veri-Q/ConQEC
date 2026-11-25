struct DiagnosticContract
    subject_name::String
    bug_class::String
    expected_bug_found::Bool
    expected_divergence::String
    expected_decoder_actual::Union{Nothing,String}
    expected_decoder_expected::Union{Nothing,String}
    expected_recovery_actual::Union{Nothing,String}
    expected_recovery_expected::Union{Nothing,String}
    expected_oracles::Vector{String}
    required_values::Dict{String,Any}
end

struct DiagnosticEvaluation
    subject_name::String
    bug_class::String
    bug_found::Bool
    expected_divergence::String
    actual_divergence::String
    diagnostic_match::Bool
    replay_consistent::Bool
    decoder_actual_expected::String
    recovery_actual_expected::String
    expected_oracles::String
    actual_oracles::String
    minimized_fault_weight::Union{Nothing,Int}
    witness_path::Union{Nothing,String}
    mismatches::Vector{String}
end

function DiagnosticContract(subject_name::AbstractString, bug_class::AbstractString;
    expected_bug_found::Bool,
    expected_divergence::AbstractString="none",
    expected_decoder_actual=nothing,
    expected_decoder_expected=nothing,
    expected_recovery_actual=nothing,
    expected_recovery_expected=nothing,
    expected_oracles=String[],
    required_values=Dict{String,Any}())

    return DiagnosticContract(
        String(subject_name),
        String(bug_class),
        expected_bug_found,
        String(expected_divergence),
        expected_decoder_actual === nothing ? nothing : String(expected_decoder_actual),
        expected_decoder_expected === nothing ? nothing : String(expected_decoder_expected),
        expected_recovery_actual === nothing ? nothing : String(expected_recovery_actual),
        expected_recovery_expected === nothing ? nothing : String(expected_recovery_expected),
        [String(id) for id in expected_oracles],
        Dict{String,Any}(string(key) => value for (key, value) in required_values),
    )
end

clean_diagnostic_contract(subject_name::AbstractString) =
    DiagnosticContract(
        subject_name,
        "clean";
        expected_bug_found=false,
    )

function _paper_diagnostic_contract_map()
    contracts = Dict{String,DiagnosticContract}(
        "bitflip_clean" => clean_diagnostic_contract("bitflip_clean"),
        "bitflip_syndrome_wiring_bug" => DiagnosticContract(
            "bitflip_syndrome_wiring_bug",
            "syndrome_wiring";
            expected_bug_found=true,
            expected_divergence="syndrome",
            expected_decoder_actual="q3",
            expected_decoder_expected="q2",
            expected_recovery_actual="X@q3",
            expected_recovery_expected="X@q2",
            expected_oracles=[
                "O1_LOGICAL_MISMATCH",
                "O3_RESIDUAL_CORRECTABLE_ERROR",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.syndrome_mismatch" => true,
                "logical_verdicts.decoder_mismatch" => true,
                "metadata.syndrome_diagnostics.observed" => "01",
                "metadata.syndrome_diagnostics.expected" => "11",
                "metadata.syndrome_wiring.observed_s12_expr" => "(x1 xor x3)",
            ),
        ),
        "bitflip_measurement_misuse" => DiagnosticContract(
            "bitflip_measurement_misuse",
            "measurement_misuse";
            expected_bug_found=true,
            expected_divergence="measurement_result",
            expected_decoder_actual="q2",
            expected_decoder_expected="q1",
            expected_recovery_actual="X@q2",
            expected_recovery_expected="X@q1",
            expected_oracles=[
                "O1_LOGICAL_MISMATCH",
                "O3_RESIDUAL_CORRECTABLE_ERROR",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.syndrome_mismatch" => true,
                "logical_verdicts.measurement_misuse" => true,
                "metadata.syndrome_diagnostics.observed" => "11",
                "metadata.syndrome_diagnostics.expected" => "10",
                "metadata.measurement_misuse.misused_observable" =>
                    "s23 reads s12 parity",
            ),
        ),
        "bitflip_buggy_decoder_table" => DiagnosticContract(
            "bitflip_buggy_decoder_table",
            "decoder_table";
            expected_bug_found=true,
            expected_divergence="decoder",
            expected_decoder_actual="q2",
            expected_decoder_expected="q1",
            expected_recovery_actual="X@q2",
            expected_recovery_expected="X@q1",
            expected_oracles=[
                "O1_LOGICAL_MISMATCH",
                "O2_DECODER_MISMATCH",
                "O3_RESIDUAL_CORRECTABLE_ERROR",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.syndrome_mismatch" => false,
                "logical_verdicts.decoder_mismatch" => true,
                "logical_verdicts.recovery_mismatch" => true,
                "metadata.syndrome_diagnostics.observed" => "10",
                "metadata.syndrome_diagnostics.expected" => "10",
            ),
        ),
        "bitflip_priority_decoder_bug" => DiagnosticContract(
            "bitflip_priority_decoder_bug",
            "decoder_table_priority";
            expected_bug_found=true,
            expected_divergence="decoder",
            expected_decoder_actual="q2",
            expected_decoder_expected="q1",
            expected_recovery_actual="X@q2",
            expected_recovery_expected="X@q1",
            expected_oracles=[
                "O1_LOGICAL_MISMATCH",
                "O2_DECODER_MISMATCH",
                "O3_RESIDUAL_CORRECTABLE_ERROR",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.syndrome_mismatch" => false,
                "logical_verdicts.decoder_mismatch" => true,
                "logical_verdicts.recovery_mismatch" => true,
                "metadata.syndrome_diagnostics.observed" => "10",
                "metadata.syndrome_diagnostics.expected" => "10",
                "metadata.fault_model" =>
                    "single Pauli-X data fault plus neutral priority decoy guards",
            ),
        ),
        "bitflip_wrong_recovery_target" => DiagnosticContract(
            "bitflip_wrong_recovery_target",
            "wrong_recovery_target";
            expected_bug_found=true,
            expected_divergence="recovery",
            expected_decoder_actual="q1",
            expected_decoder_expected="q1",
            expected_recovery_actual="X@q2",
            expected_recovery_expected="X@q1",
            expected_oracles=[
                "O1_LOGICAL_MISMATCH",
                "O3_RESIDUAL_CORRECTABLE_ERROR",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.decoder_mismatch" => false,
                "logical_verdicts.recovery_mismatch" => true,
                "logical_verdicts.missing_recovery_branch" => false,
            ),
        ),
        "bitflip_missing_recovery_branch" => DiagnosticContract(
            "bitflip_missing_recovery_branch",
            "missing_recovery_branch";
            expected_bug_found=true,
            expected_divergence="recovery",
            expected_decoder_actual="q1",
            expected_decoder_expected="q1",
            expected_recovery_actual="missing@missing",
            expected_recovery_expected="X@q1",
            expected_oracles=[
                "O1_LOGICAL_MISMATCH",
                "O3_RESIDUAL_CORRECTABLE_ERROR",
                "O4_DEAD_RECOVERY_BRANCH",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.decoder_mismatch" => false,
                "logical_verdicts.recovery_mismatch" => true,
                "logical_verdicts.missing_recovery_branch" => true,
            ),
        ),
        "phaseflip_clean" => clean_diagnostic_contract("phaseflip_clean"),
        "phaseflip_buggy_decoder_table" => DiagnosticContract(
            "phaseflip_buggy_decoder_table",
            "decoder_table";
            expected_bug_found=true,
            expected_divergence="decoder",
            expected_decoder_actual="q2",
            expected_decoder_expected="q1",
            expected_recovery_actual="Z@q2",
            expected_recovery_expected="Z@q1",
            expected_oracles=[
                "O1_LOGICAL_MISMATCH",
                "O2_DECODER_MISMATCH",
                "O3_RESIDUAL_CORRECTABLE_ERROR",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.syndrome_mismatch" => false,
                "logical_verdicts.decoder_mismatch" => true,
                "logical_verdicts.recovery_mismatch" => true,
            ),
        ),
        "steane_css_clean" => clean_diagnostic_contract("steane_css_clean"),
        "steane_css_buggy_decoder_table" => DiagnosticContract(
            "steane_css_buggy_decoder_table",
            "decoder_table";
            expected_bug_found=true,
            expected_divergence="decoder",
            expected_decoder_actual="q2",
            expected_decoder_expected="q1",
            expected_recovery_actual="X@q2",
            expected_recovery_expected="X@q1",
            expected_oracles=[
                "O1_LOGICAL_MISMATCH",
                "O2_DECODER_MISMATCH",
                "O3_RESIDUAL_CORRECTABLE_ERROR",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.decoder_mismatch" => true,
                "metadata.syndrome_diagnostics.observed" => "X=100;Z=000",
                "metadata.syndrome_diagnostics.expected" => "X=100;Z=000",
                "metadata.decoder_diagnostics.x_decoder_buggy_entry" =>
                    "100 -> q2 instead of q1",
            ),
        ),
        "surface_d3_x_memory_clean" =>
            clean_diagnostic_contract("surface_d3_x_memory_clean"),
        "surface_d3_x_memory_buggy_decoder_table" => DiagnosticContract(
            "surface_d3_x_memory_buggy_decoder_table",
            "decoder_table";
            expected_bug_found=true,
            expected_divergence="decoder",
            expected_decoder_actual="q2",
            expected_decoder_expected="q1",
            expected_recovery_actual="X@q2",
            expected_recovery_expected="X@q1",
            expected_oracles=[
                "O1_LOGICAL_MISMATCH",
                "O2_DECODER_MISMATCH",
                "O3_RESIDUAL_CORRECTABLE_ERROR",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.decoder_mismatch" => true,
                "metadata.syndrome_diagnostics.observed" => "X=1000;Z=0000",
                "metadata.syndrome_diagnostics.expected" => "X=1000;Z=0000",
                "metadata.decoder_diagnostics.x_decoder_buggy_entry" =>
                    "1000 -> q2 instead of q1",
            ),
        ),
        "repetition_d5_clean" => clean_diagnostic_contract("repetition_d5_clean"),
        "repetition_d5_decoder_neighbor_bug" => DiagnosticContract(
            "repetition_d5_decoder_neighbor_bug",
            "decoder_neighbor";
            expected_bug_found=true,
            expected_divergence="decoder",
            expected_decoder_actual="q2",
            expected_decoder_expected="q1",
            expected_recovery_actual="X@q2",
            expected_recovery_expected="X@q1",
            expected_oracles=[
                "O1_LOGICAL_MISMATCH",
                "O2_DECODER_MISMATCH",
                "O3_RESIDUAL_CORRECTABLE_ERROR",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.decoder_mismatch" => true,
                "logical_verdicts.recovery_mismatch" => true,
                "metadata.decoder" => "deterministic nearest single-fault syndrome table",
            ),
        ),
        "round_repetition_d3_r2_clean" =>
            clean_diagnostic_contract("round_repetition_d3_r2_clean"),
        "round_repetition_d3_r2_history_drop_bug" => DiagnosticContract(
            "round_repetition_d3_r2_history_drop_bug",
            "repeated_round_history_drop";
            expected_bug_found=true,
            expected_divergence="repeated_round_control",
            expected_decoder_actual="r2_q1",
            expected_decoder_expected="r1_q1",
            expected_recovery_actual="X@q1:round=2",
            expected_recovery_expected="X@q1:round=1",
            expected_oracles=[
                "O2_DECODER_MISMATCH",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.history_mismatch" => true,
                "logical_verdicts.decoder_mismatch" => true,
                "logical_verdicts.logical_mismatch" => false,
                "metadata.decoder_diagnostics.observed_history" => "10|10",
                "metadata.decoder_diagnostics.decoder_history_used" => "00|10",
                "metadata.history_drop_bug.dropped_round" => 1,
            ),
        ),
        "round_repetition_d3_r2_inconsistent_control_bug" => DiagnosticContract(
            "round_repetition_d3_r2_inconsistent_control_bug",
            "repeated_round_inconsistent_control";
            expected_bug_found=true,
            expected_divergence="repeated_round_control",
            expected_decoder_actual="r2_q1",
            expected_decoder_expected="r2_q1",
            expected_recovery_actual="X@q1:round=2",
            expected_recovery_expected="X@q1:round=2",
            expected_oracles=[
                "O5_INCONSISTENT_CONTROL",
            ],
            required_values=Dict{String,Any}(
                "logical_verdicts.inconsistent_control" => true,
                "logical_verdicts.decoder_mismatch" => false,
                "logical_verdicts.recovery_mismatch" => false,
                "relational_counterexample.control_state" =>
                    "latest_syndrome=10;decoder_target=q1",
                "relational_counterexample.prior.trace_index" => 2,
                "relational_counterexample.current.trace_index" => 5,
                "metadata.decoder_state_key" => "latest_syndrome=10;decoder_target=q1",
            ),
        ),
    )
    for config in paper_subject_configs()
        name = subject_name(config.subject)
        get!(contracts, name, diagnostic_contract_from_config(config))
    end
    return contracts
end

function diagnostic_contract_from_config(config)
    name = subject_name(config.subject)
    metadata = config_bug_metadata(config)
    if metadata === nothing
        return clean_diagnostic_contract(name)
    end

    return DiagnosticContract(
        name,
        String(metadata["bug_class"]);
        expected_bug_found=true,
        expected_divergence=String(metadata["expected_earliest_divergence"]),
        expected_decoder_actual=get(metadata, "expected_actual_decoder", nothing),
        expected_decoder_expected=get(metadata, "expected_reference_decoder", nothing),
        expected_recovery_actual=get(metadata, "expected_actual_recovery", nothing),
        expected_recovery_expected=get(metadata, "expected_reference_recovery", nothing),
        expected_oracles=String.(get(metadata, "expected_oracle_classes", String[])),
        required_values=Dict{String,Any}(),
    )
end

function paper_diagnostic_contracts()
    contracts = _paper_diagnostic_contract_map()
    ordered = DiagnosticContract[]
    for config in paper_subject_configs()
        name = subject_name(config.subject)
        push!(ordered, contracts[name])
    end
    return ordered
end

function paper_diagnostic_contract_by_name(name::AbstractString)
    requested = String(name)
    subject = try
        subject_name(paper_subject_config_by_name(requested).subject)
    catch err
        err isa ErrorException || rethrow()
        requested
    end

    contracts = _paper_diagnostic_contract_map()
    haskey(contracts, subject) && return contracts[subject]
    error("unknown diagnostic contract subject: $(name)")
end

function nested_lookup(value, path::AbstractString)
    current = value
    for key in split(path, '.')
        current isa AbstractDict || return false, nothing
        haskey(current, key) || return false, nothing
        current = current[key]
    end
    return true, current
end

function diagnostic_value_text(value)
    value === nothing && return "none"
    value isa Bool && return value ? "true" : "false"
    return String(string(value))
end

function recovery_action_signature(action)
    action === nothing && return "none"
    if action isa AbstractVector
        isempty(action) && return "none"
        return recovery_action_signature(first(action))
    end
    action isa AbstractDict || return diagnostic_value_text(action)

    pauli = diagnostic_value_text(get(action, "pauli", "unknown"))
    target = diagnostic_value_text(get(action, "target", "unknown"))
    signature = string(pauli, "@", target)
    inferred_round = get(action, "inferred_round", nothing)
    inferred_round === nothing && return signature
    return string(signature, ":round=", inferred_round)
end

function diagnostic_actual_divergence(witness)
    witness === nothing && return "none"
    return diagnostic_value_text(get(witness, "earliest_divergence_stage", "none"))
end

function diagnostic_decoder_pair_text(witness)
    witness === nothing && return "none"
    actual = diagnostic_value_text(get(witness, "decoder_output", nothing))
    expected = diagnostic_value_text(get(witness, "expected_decoder_output", nothing))
    return string(actual, "/", expected)
end

function diagnostic_recovery_pair_text(witness)
    witness === nothing && return "none"
    actual = recovery_action_signature(get(witness, "recovery_actually_applied", nothing))
    expected = recovery_action_signature(get(witness, "expected_recovery", nothing))
    return string(actual, "/", expected)
end

function diagnostic_oracle_ids(witness)
    witness === nothing && return String[]
    return stored_triggered_failure_oracle_ids(witness)
end

function diagnostic_oracles_text(witness)
    witness === nothing && return "none"
    ids = diagnostic_oracle_ids(witness)
    return isempty(ids) ? "none" : join(ids, "+")
end

oracles_text(ids::AbstractVector{<:AbstractString}) =
    isempty(ids) ? "none" : join(ids, "+")

function witness_fault_assignment(witness::AbstractDict)
    pattern = get(witness, "fault_pattern", nothing)
    pattern isa AbstractVector ||
        error("witness does not contain a replayable fault_pattern array")

    model = Dict{Symbol,Bool}()
    for item in pattern
        item isa AbstractDict || continue
        haskey(item, "variable") || continue
        model[Symbol(String(item["variable"]))] = Bool(get(item, "active", false))
    end
    isempty(model) && error("witness fault_pattern contains no variables")
    return model
end

function snapshot_fault_assignment(snapshot::AbstractDict)
    assignments = get(snapshot, "fault_assignments", nothing)
    assignments isa AbstractDict || error("relational snapshot is missing fault_assignments")
    return Dict{Symbol,Bool}(
        Symbol(String(key)) => Bool(value)
        for (key, value) in assignments
    )
end

function replay_witness_for_subject(subject, witness::AbstractDict)
    relational = get(witness, "relational_counterexample", nothing)
    if relational isa AbstractDict
        prior = get(relational, "prior", nothing)
        prior isa AbstractDict ||
            error("relational witness is missing prior counterexample snapshot")
        state = RelationalOracleState()
        prior_trace = run_subject(subject, snapshot_fault_assignment(prior))
        apply_relational_oracles!(state, prior_trace, Int(get(prior, "trace_index", 1)))
        current_trace = run_subject(subject, witness_fault_assignment(witness))
        apply_relational_oracles!(
            state,
            current_trace,
            Int(get(get(relational, "current", Dict{String,Any}()), "trace_index", 2)),
        )
        return build_witness(current_trace)
    end
    model = witness_fault_assignment(witness)
    trace = run_subject(subject, model)
    return build_witness(trace)
end

const DIAGNOSTIC_REPLAY_PATHS = [
    "earliest_divergence_stage",
    "decoder_output",
    "expected_decoder_output",
    "logical_verdicts.syndrome_mismatch",
    "logical_verdicts.measurement_misuse",
    "logical_verdicts.decoder_mismatch",
    "logical_verdicts.recovery_mismatch",
    "logical_verdicts.logical_mismatch",
    "logical_verdicts.missing_recovery_branch",
    "logical_verdicts.history_mismatch",
    "logical_verdicts.inconsistent_control",
    "oracle_summary.summary",
    "oracle_summary.triggered_count",
    "relational_counterexample.control_state",
    "metadata.syndrome_diagnostics.observed",
    "metadata.syndrome_diagnostics.expected",
    "metadata.decoder_diagnostics.observed_history",
    "metadata.decoder_diagnostics.decoder_history_used",
]

function diagnostic_replay_signature(witness::AbstractDict)
    signature = Dict{String,Any}()
    for path in DIAGNOSTIC_REPLAY_PATHS
        found, value = nested_lookup(witness, path)
        found && (signature[path] = value)
    end
    signature["recovery_actual"] =
        recovery_action_signature(get(witness, "recovery_actually_applied", nothing))
    signature["recovery_expected"] =
        recovery_action_signature(get(witness, "expected_recovery", nothing))
    signature["stored_triggered_oracles"] = diagnostic_oracles_text(witness)
    return signature
end

function replay_consistency_mismatches(witness::AbstractDict, replay_witness::AbstractDict)
    original = diagnostic_replay_signature(witness)
    replayed = diagnostic_replay_signature(replay_witness)
    keys_to_check = sort!(collect(union(keys(original), keys(replayed))), by=string)
    mismatches = String[]
    for key in keys_to_check
        original_value = get(original, key, nothing)
        replayed_value = get(replayed, key, nothing)
        original_value == replayed_value && continue
        push!(
            mismatches,
            string(
                "replay ",
                key,
                " expected ",
                diagnostic_value_text(original_value),
                " got ",
                diagnostic_value_text(replayed_value),
            ),
        )
    end
    return mismatches
end

function required_value_mismatches(witness::AbstractDict, contract::DiagnosticContract)
    mismatches = String[]
    for path in sort!(collect(keys(contract.required_values)), by=string)
        expected = contract.required_values[path]
        found, actual = nested_lookup(witness, path)
        if !found
            push!(mismatches, "missing required diagnostic value $(path)")
        elseif actual != expected
            push!(
                mismatches,
                string(
                    path,
                    " expected ",
                    diagnostic_value_text(expected),
                    " got ",
                    diagnostic_value_text(actual),
                ),
            )
        end
    end
    return mismatches
end

function contract_mismatches(witness, contract::DiagnosticContract; bug_found::Bool)
    mismatches = String[]
    if bug_found != contract.expected_bug_found
        push!(
            mismatches,
            string(
                "bug_found expected ",
                contract.expected_bug_found,
                " got ",
                bug_found,
            ),
        )
    end

    if !contract.expected_bug_found
        witness === nothing || push!(mismatches, "clean contract produced a witness")
        return mismatches
    end

    if witness === nothing
        push!(mismatches, "expected a failing witness")
        return mismatches
    end

    actual_divergence = diagnostic_actual_divergence(witness)
    actual_divergence == contract.expected_divergence ||
        push!(mismatches, string(
            "earliest_divergence expected ",
            contract.expected_divergence,
            " got ",
            actual_divergence,
        ))

    decoder_actual = diagnostic_value_text(get(witness, "decoder_output", nothing))
    if contract.expected_decoder_actual !== nothing &&
            decoder_actual != contract.expected_decoder_actual
        push!(mismatches, string(
            "decoder actual expected ",
            contract.expected_decoder_actual,
            " got ",
            decoder_actual,
        ))
    end

    decoder_expected = diagnostic_value_text(get(witness, "expected_decoder_output", nothing))
    if contract.expected_decoder_expected !== nothing &&
            decoder_expected != contract.expected_decoder_expected
        push!(mismatches, string(
            "decoder expected expected ",
            contract.expected_decoder_expected,
            " got ",
            decoder_expected,
        ))
    end

    recovery_actual =
        recovery_action_signature(get(witness, "recovery_actually_applied", nothing))
    if contract.expected_recovery_actual !== nothing &&
            recovery_actual != contract.expected_recovery_actual
        push!(mismatches, string(
            "recovery actual expected ",
            contract.expected_recovery_actual,
            " got ",
            recovery_actual,
        ))
    end

    recovery_expected =
        recovery_action_signature(get(witness, "expected_recovery", nothing))
    if contract.expected_recovery_expected !== nothing &&
            recovery_expected != contract.expected_recovery_expected
        push!(mismatches, string(
            "recovery expected expected ",
            contract.expected_recovery_expected,
            " got ",
            recovery_expected,
        ))
    end

    append!(mismatches, required_value_mismatches(witness, contract))

    actual_oracles = diagnostic_oracle_ids(witness)
    if actual_oracles != contract.expected_oracles
        push!(
            mismatches,
            string(
                "triggered_oracles expected ",
                oracles_text(contract.expected_oracles),
                " got ",
                oracles_text(actual_oracles),
            ),
        )
    end

    computed_oracles = triggered_failure_oracle_ids(witness)
    if actual_oracles != computed_oracles
        push!(
            mismatches,
            string(
                "stored triggered_oracles disagree with logical verdicts: stored ",
                oracles_text(actual_oracles),
                " computed ",
                oracles_text(computed_oracles),
            ),
        )
    end

    return mismatches
end

function evaluate_witness_diagnostics(witness, contract::DiagnosticContract;
    bug_found::Bool=(witness !== nothing),
    replay_witness=nothing,
    minimized_fault_weight=nothing,
    witness_path=nothing)

    mismatches = contract_mismatches(witness, contract; bug_found=bug_found)
    replay_mismatches = String[]
    if witness !== nothing && replay_witness !== nothing
        append!(replay_mismatches, replay_consistency_mismatches(witness, replay_witness))
    end

    return DiagnosticEvaluation(
        contract.subject_name,
        contract.bug_class,
        bug_found,
        contract.expected_divergence,
        diagnostic_actual_divergence(witness),
        isempty(mismatches),
        isempty(replay_mismatches),
        diagnostic_decoder_pair_text(witness),
        diagnostic_recovery_pair_text(witness),
        oracles_text(contract.expected_oracles),
        diagnostic_oracles_text(witness),
        minimized_fault_weight,
        witness_path,
        vcat(mismatches, replay_mismatches),
    )
end

function evaluate_diagnostic_result(result::ExplorationResult, contract::DiagnosticContract;
    subject=nothing)

    replay_witness = nothing
    if subject !== nothing && result.witness !== nothing
        replay_witness = replay_witness_for_subject(subject, result.witness)
    end

    return evaluate_witness_diagnostics(
        result.witness,
        contract;
        bug_found=result.bug_found,
        replay_witness=replay_witness,
        minimized_fault_weight=minimized_witness_fault_weight(result),
        witness_path=result.witness_path,
    )
end
