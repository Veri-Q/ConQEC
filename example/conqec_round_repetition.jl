include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
using .ConQEC

subject = RoundRepetitionSubject(3, 2, :history_drop_bug)
witness_dir = get(
    ENV,
    "CONQEC_WITNESS_DIR",
    joinpath(@__DIR__, "..", "artifacts", "witnesses"),
)

result = run_concolic_subject(
    subject;
    max_tests=8,
    max_fault_weight=1,
    witness_dir=witness_dir,
)

println("ConQEC repeated-round repetition-code example")
println("subject: ", subject.name)
println("distance: ", subject.distance)
println("rounds: ", subject.rounds)
println("generated tests: ", result.generated_tests)
println("unique syndrome histories covered: ", length(result.unique_syndromes))
println("bug found: ", result.bug_found)
println("witness file: ", result.witness_path === nothing ? "none" : result.witness_path)

if result.generated_tests >= 2
    first_trace = result.traces[1]
    second_trace = result.traces[2]
    println("exploration: started at ",
        assignment_key(first_trace.fault_vars, first_trace.fault_assignments),
        " and branch-flipped into ",
        assignment_key(second_trace.fault_vars, second_trace.fault_assignments))
end

for (idx, trace) in enumerate(result.traces)
    println()
    println("test #", idx)
    println("  faults: ", assignment_key(trace.fault_vars, trace.fault_assignments))
    println("  observed history: ", trace.decoder_decisions["observed_history"])
    println("  decoder history used: ", trace.decoder_decisions["decoder_history_used"])
    println("  decoder actual/expected: ",
        trace.decoder_decisions["actual"], " / ", trace.decoder_decisions["expected"])
    println("  oracle verdict: ", trace.logical_verdicts["oracle_verdict"])
end
