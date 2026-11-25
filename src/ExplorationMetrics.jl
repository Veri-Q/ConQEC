metric_traces(result::ExplorationResult) = result.traces
metric_traces(trace::ConcolicTrace) = ConcolicTrace[trace]

function metric_traces(traces)
    out = ConcolicTrace[]
    for trace in traces
        trace isa ConcolicTrace ||
            error("expected ConcolicTrace values, got $(typeof(trace))")
        push!(out, trace)
    end
    return out
end

function branch_ids(result_or_traces)
    ids = Set{String}()
    for trace in metric_traces(result_or_traces)
        for guard in trace.branch_guards
            push!(ids, guard.id)
        end
    end
    return sort!(collect(ids))
end

function stage_counts(result_or_traces)
    counts = Dict{String,Int}(string(stage) => 0 for stage in DIVERGENCE_STAGES)
    for trace in metric_traces(result_or_traces)
        for guard in trace.branch_guards
            stage = string(guard.stage)
            counts[stage] = get(counts, stage, 0) + 1
        end
    end
    return counts
end

function unique_syndrome_count(result::ExplorationResult)
    return length(result.unique_syndromes)
end

function unique_syndrome_count(result_or_traces)
    syndromes = Set{String}()
    for trace in metric_traces(result_or_traces)
        push!(syndromes, syndrome_key(trace))
    end
    return length(syndromes)
end

function first_bug_trace(result_or_traces)
    for trace in metric_traces(result_or_traces)
        trace_has_bug(trace) && return trace
    end
    return nothing
end

function witness_metric_value(witness, key::AbstractString)
    witness === nothing && return nothing
    return get(witness, key, nothing)
end

function witness_minimization_value(witness, key::AbstractString)
    witness === nothing && return nothing
    minimization = get(witness, "minimization", nothing)
    minimization isa AbstractDict || return nothing
    return get(minimization, key, nothing)
end

function witness_fault_pattern_weight(witness)
    pattern = witness_metric_value(witness, "fault_pattern")
    pattern === nothing && return nothing

    weight = 0
    for item in pattern
        item isa AbstractDict || continue
        get(item, "active", false) && (weight += 1)
    end
    return weight
end

function original_witness_fault_weight(result::ExplorationResult)
    weight = witness_minimization_value(result.witness, "original_fault_weight")
    weight !== nothing && return weight

    trace = first_bug_trace(result)
    trace !== nothing && return fault_weight(trace)

    return witness_fault_pattern_weight(result.witness)
end

function minimized_witness_fault_weight(result::ExplorationResult)
    weight = witness_minimization_value(result.witness, "minimized_fault_weight")
    weight !== nothing && return weight

    result.witness === nothing && return nothing
    pattern_weight = witness_fault_pattern_weight(result.witness)
    pattern_weight !== nothing && return pattern_weight

    trace = first_bug_trace(result)
    return trace === nothing ? nothing : fault_weight(trace)
end

function summary_earliest_divergence(result::ExplorationResult)
    stage = witness_metric_value(result.witness, "earliest_divergence_stage")
    stage !== nothing && return stage

    trace = first_bug_trace(result)
    return trace === nothing ? nothing : earliest_divergence(trace)
end

function exploration_summary(result::ExplorationResult)
    ids = branch_ids(result)
    query_statuses = [
        string(get(record, "solver_status", get(record, "status", "UNKNOWN")))
        for record in result.branch_query_results
    ]
    solve_times = Float64[]
    for record in result.branch_query_results
        value = get(record, "solve_time_ms", nothing)
        value === nothing && continue
        parsed = tryparse(Float64, string(value))
        parsed === nothing || push!(solve_times, parsed)
    end
    return Dict{String,Any}(
        "generated_tests" => result.generated_tests,
        "unique_syndromes" => unique_syndrome_count(result),
        "unique_branch_ids" => length(ids),
        "branch_ids" => ids,
        "branch_guard_count" => sum(length(trace.branch_guards) for trace in result.traces),
        "stage_counts" => stage_counts(result),
        "bug_found" => result.bug_found,
        "witness_count" => length(result.witnesses),
        "earliest_divergence" => summary_earliest_divergence(result),
        "witness_fault_weight" => original_witness_fault_weight(result),
        "minimized_fault_weight" => minimized_witness_fault_weight(result),
        "solver_query_count" => length(result.branch_query_results),
        "solver_statuses" => query_statuses,
        "solver_solve_time_ms_total" => sum(solve_times),
        "solver_solve_time_ms_max" => isempty(solve_times) ? 0.0 : maximum(solve_times),
        "solver_query_bytes" => sum(
            parse(Int, string(get(record, "query_bytes", "0")))
            for record in result.branch_query_results;
            init=0,
        ),
    )
end
