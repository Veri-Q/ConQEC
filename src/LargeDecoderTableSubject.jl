struct LargeDecoderTableSubject
    name::String
    arms::Int
    bug_arm::Int
    wrong_arm::Int
    decoys::Int
    budget::Int
end

function LargeDecoderTableSubject(arms::Integer, bug_arm::Integer;
    wrong_arm::Integer=bug_arm == arms ? bug_arm - 1 : bug_arm + 1,
    decoys::Integer=large_decoder_table_default_decoys(arms),
    budget::Integer=large_decoder_table_budget(arms),
    label::Union{Nothing,AbstractString}=nothing)

    arms in (32, 64, 128, 256, 512, 1024, 2048) ||
        error("large decoder-table subjects support 32, 64, 128, 256, 512, 1024, or 2048 arms")
    1 <= bug_arm <= arms ||
        error("bug_arm $(bug_arm) is outside 1:$(arms)")
    1 <= wrong_arm <= arms ||
        error("wrong_arm $(wrong_arm) is outside 1:$(arms)")
    wrong_arm != bug_arm ||
        error("wrong_arm must differ from bug_arm")
    decoys >= 0 || error("decoys must be non-negative")
    budget > 0 || error("budget must be positive")
    name = label === nothing ?
        "large_decoder_table_a$(arms)_bug$(bug_arm)" :
        String(label)
    return LargeDecoderTableSubject(
        name,
        Int(arms),
        Int(bug_arm),
        Int(wrong_arm),
        Int(decoys),
        Int(budget),
    )
end

large_decoder_table_budget(arms::Integer) =
    arms == 32 ? 16 :
    arms == 64 ? 32 :
    arms in (128, 256) ? 64 :
    arms in (512, 1024, 2048) ? 64 :
    error("unsupported large decoder-table arm count: $(arms)")

large_decoder_table_default_decoys(arms::Integer) =
    max(Int(arms), 4 * large_decoder_table_budget(arms))

large_decoder_table_syndrome_bits(arms::Integer) =
    ceil(Int, log2(Int(arms) + 1))

large_decoder_table_admissible_assignments(subject::LargeDecoderTableSubject) =
    subject.decoys + subject.arms + 1

function large_decoder_table_hardness_bin(budget::Integer, admissible::Integer)
    ratio = Float64(budget) / Float64(admissible)
    ratio > 0.5 && return "easy"
    0.05 <= ratio <= 0.2 && return "medium"
    ratio < 0.01 && return "hard"
    return "transition"
end

large_decoder_table_decoy_var(idx::Integer) =
    Symbol("ldt_decoy_", lpad(string(idx), 4, '0'))

large_decoder_table_arm_var(idx::Integer) =
    Symbol("ldt_arm_", lpad(string(idx), 4, '0'))

function large_decoder_table_fault_vars(subject::LargeDecoderTableSubject)
    decoys = [large_decoder_table_decoy_var(idx) for idx in 1:subject.decoys]
    arms = [large_decoder_table_arm_var(idx) for idx in 1:subject.arms]
    return vcat(decoys, arms)
end

function large_decoder_table_syndrome_names(subject::LargeDecoderTableSubject)
    return ["s$(idx)" for idx in 1:large_decoder_table_syndrome_bits(subject.arms)]
end

function large_decoder_table_bits(value::Integer, width::Integer)
    return [((Int(value) >> (idx - 1)) & 1) == 1 for idx in 1:Int(width)]
end

function large_decoder_table_arm_condition(arm::Integer)
    return boolvar(large_decoder_table_arm_var(arm))
end

large_decoder_table_decoder_label(arm::Integer) =
    "q" * lpad(string(arm), 4, '0')

function large_decoder_table_recovery(decoder_output::AbstractString)
    output = String(decoder_output)
    if output == "none"
        return Dict{String,Any}(
            "pauli" => "I",
            "target" => "none",
            "source" => "large_decoder_table",
        )
    end
    return Dict{String,Any}(
        "pauli" => "X",
        "target" => output,
        "source" => "large_decoder_table",
    )
end

function large_decoder_table_reference_decoder(subject::LargeDecoderTableSubject,
    active_arm::Union{Nothing,Int})

    active_arm === nothing && return "none"
    return large_decoder_table_decoder_label(active_arm)
end

function large_decoder_table_actual_decoder(subject::LargeDecoderTableSubject,
    active_arm::Union{Nothing,Int})

    active_arm === nothing && return "none"
    active_arm == subject.bug_arm &&
        return large_decoder_table_decoder_label(subject.wrong_arm)
    return large_decoder_table_decoder_label(active_arm)
end

function large_decoder_table_active_arm(subject::LargeDecoderTableSubject,
    model::AbstractDict)

    active = Int[]
    for arm in 1:subject.arms
        var = large_decoder_table_arm_var(arm)
        model_bool(model, var) && push!(active, arm)
    end
    isempty(active) && return nothing
    return first(active)
end

function large_decoder_table_syndrome_exprs(subject::LargeDecoderTableSubject)
    width = large_decoder_table_syndrome_bits(subject.arms)
    exprs = BoolExpr[]
    for bit in 1:width
        terms = BoolExpr[]
        for arm in 1:subject.arms
            large_decoder_table_bits(arm, width)[bit] || continue
            push!(terms, large_decoder_table_arm_condition(arm))
        end
        push!(exprs, isempty(terms) ? bconst(false) : bor(terms...))
    end
    return exprs
end

function large_decoder_table_decoder_order(subject::LargeDecoderTableSubject)
    preferred = [subject.bug_arm]
    for arm in 1:subject.arms
        arm == subject.bug_arm && continue
        push!(preferred, arm)
    end
    return preferred
end

function large_decoder_table_decoder_recovery_semantics(subject::LargeDecoderTableSubject)
    names = large_decoder_table_syndrome_names(subject)
    width = length(names)
    rows = Dict{String,Any}[]
    for arm in 1:subject.arms
        actual = large_decoder_table_actual_decoder(subject, arm)
        bits = large_decoder_table_bits(arm, width)
        pattern = Dict(name => bits[idx] for (idx, name) in enumerate(names))
        push!(
            rows,
            decoder_recovery_semantics_row(
                "decoder:arm_" * lpad(string(arm), 4, '0'),
                pattern,
                actual,
                large_decoder_table_recovery(actual),
            ),
        )
    end
    return rows
end

function large_decoder_table_recovery_output_conditions(subject::LargeDecoderTableSubject)
    by_output = Dict{String,Vector{BoolExpr}}("none" => BoolExpr[])
    for arm in 1:subject.arms
        output = large_decoder_table_actual_decoder(subject, arm)
        get!(by_output, output, BoolExpr[])
        push!(by_output[output], large_decoder_table_arm_condition(arm))
    end
    conditions = Tuple{String,BoolExpr}[]
    push!(conditions, ("none", band([bnot(large_decoder_table_arm_condition(arm))
                                     for arm in 1:subject.arms]...)))
    for output in sort!(collect(keys(by_output)))
        output == "none" && continue
        terms = by_output[output]
        push!(conditions, (output, length(terms) == 1 ? terms[1] : bor(terms...)))
    end
    return conditions
end

function large_decoder_table_characterization(subject::LargeDecoderTableSubject)
    budget = subject.budget
    admissible = large_decoder_table_admissible_assignments(subject)
    ratio = Float64(budget) / Float64(admissible)
    return Dict{String,Any}(
        "subject_family" => "large_decoder_table",
        "benchmark_family" => "LargeDecoderTable",
        "qubits" => subject.arms,
        "fault_variables" => subject.decoys + subject.arms,
        "max_fault_weight" => 1,
        "admissible_assignments" => admissible,
        "syndrome_bits" => large_decoder_table_syndrome_bits(subject.arms),
        "reachable_syndromes" => subject.arms + 1,
        "decoder_arms" => subject.arms,
        "recovery_actions" => subject.arms + 1,
        "repeated_rounds" => 1,
        "round_history_states" => 0,
        "seeded_failing_assignments" => 1,
        "failing_assignments" => 1,
        "estimated_bug_probability" => 1.0 / Float64(admissible),
        "bug_hit_probability" => 1.0 / Float64(admissible),
        "budget" => budget,
        "exhaustibility_ratio" => ratio,
        "hardness_bin" => large_decoder_table_hardness_bin(budget, admissible),
        "path_decoy_branches" => min(subject.decoys, budget),
        "path_sensitive" => true,
        "trigger_faults" => [string(large_decoder_table_arm_var(subject.bug_arm))],
        "interesting_faults" => [
            string(large_decoder_table_arm_var(arm))
            for arm in 1:min(subject.arms, budget)
        ],
        "boring_faults" => [
            string(large_decoder_table_decoy_var(idx))
            for idx in 1:min(subject.decoys, budget)
        ],
        "qec_first_failure_trial" => 2,
        "trace_first_failure_trial" => budget + 1,
        "bounded_first_failure_trial" => "none",
    )
end

function run_large_decoder_table_subject(subject::LargeDecoderTableSubject, input::AbstractDict)
    fault_vars = large_decoder_table_fault_vars(subject)
    model = normalize_assignment(fault_vars, input)
    characterization = large_decoder_table_characterization(subject)
    trace = ConcolicTrace(
        subject.name;
        code_size=subject.arms,
        distance=3,
        fault_vars=fault_vars,
        fault_assignments=model,
        metadata=merge(
            Dict{String,Any}(
                "mode" => "sparse_decoder_table_bug",
                "fault_model" =>
                    "single active decoder-arm or neutral decoy fault location",
                "bug_arm" => subject.bug_arm,
                "wrong_arm" => subject.wrong_arm,
                "neutral_decoy_faults" => subject.decoys,
            ),
            characterization,
        ),
    )

    for idx in 1:subject.decoys
        var = large_decoder_table_decoy_var(idx)
        record_branch!(
            trace,
            "fault:large_decoder_decoy_" * lpad(string(idx), 4, '0'),
            :fault,
            boolvar(var),
            model[var];
            description="neutral decoder-table decoy fault location $(idx)",
            path_constraint=idx <= subject.budget,
        )
    end

    syndrome_names = large_decoder_table_syndrome_names(subject)
    syndrome_exprs = large_decoder_table_syndrome_exprs(subject)
    active_arm = large_decoder_table_active_arm(subject, model)
    active_bits = large_decoder_table_bits(active_arm === nothing ? 0 : active_arm,
        length(syndrome_names))
    for (idx, name) in enumerate(syndrome_names)
        record_syndrome!(trace, name, active_bits[idx], syndrome_exprs[idx])
    end
    record_syndrome_bit_branches!(
        trace,
        syndrome_names,
        active_bits,
        syndrome_exprs;
        id_prefix="syndrome:large_decoder_table",
        path_constraint=false,
    )

    for arm in large_decoder_table_decoder_order(subject)
        condition = large_decoder_table_arm_condition(arm)
        taken = active_arm === arm
        record_branch!(
            trace,
            "decoder:arm_" * lpad(string(arm), 4, '0'),
            :decoder,
            condition,
            taken;
            description="large decoder-table arm $(arm) of $(subject.arms)",
            path_constraint=true,
        )
    end
    no_arm_condition = band([bnot(large_decoder_table_arm_condition(arm))
                             for arm in 1:subject.arms]...)
    record_branch!(
        trace,
        "decoder:none",
        :decoder,
        no_arm_condition,
        active_arm === nothing;
        description="large decoder-table no-op arm",
        path_constraint=false,
    )

    expected_decoder = large_decoder_table_reference_decoder(subject, active_arm)
    actual_decoder = large_decoder_table_actual_decoder(subject, active_arm)
    expected_recovery = large_decoder_table_recovery(expected_decoder)
    actual_recovery = large_decoder_table_recovery(actual_decoder)

    record_decoder_decision!(
        trace,
        "syndrome",
        join([bit ? "1" : "0" for bit in active_bits]),
    )
    record_decoder_decision!(trace, "actual", actual_decoder)
    record_decoder_decision!(trace, "expected", expected_decoder)
    record_decoder_decision!(trace, "bug_arm", subject.bug_arm)
    record_decoder_decision!(trace, "wrong_arm", subject.wrong_arm)
    record_recovery_action!(trace, actual_recovery)
    trace.metadata["expected_recovery"] = expected_recovery
    set_decoder_recovery_semantics!(
        trace,
        large_decoder_table_decoder_recovery_semantics(subject),
    )

    bug_triggered = active_arm === subject.bug_arm
    record_logical_verdict!(trace, "decoder_mismatch", bug_triggered)
    record_logical_verdict!(trace, "recovery_mismatch", bug_triggered)
    record_logical_verdict!(trace, "logical_mismatch", bug_triggered)
    record_logical_verdict!(trace, "missing_recovery_branch", false)
    record_logical_verdict!(trace, "oracle_verdict", !bug_triggered)
    record_logical_verdict!(trace, "residual_weight", bug_triggered ? 1 : 0)
    bug_triggered && (trace.metadata["earliest_divergence_stage"] = "decoder")
    return trace
end
