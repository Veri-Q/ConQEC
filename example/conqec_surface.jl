include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
using .ConQEC

subject = SurfaceSubject(:buggy_decoder)
fault_vars = surface_fault_vars()
witness_dir = get(
    ENV,
    "CONQEC_WITNESS_DIR",
    joinpath(@__DIR__, "..", "artifacts", "witnesses"),
)

result = run_concolic(
    input -> run_surface_subject(subject, input),
    fault_vars;
    max_tests=8,
    max_fault_weight=1,
    witness_dir=witness_dir,
)

println("ConQEC surface-code kernel example")
println("subject: ", subject.name)
println("code: distance-3 X-memory syndrome kernel")
println("generated tests: ", result.generated_tests)
println("unique syndromes covered: ", length(result.unique_syndromes))
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
    println("  syndrome: ", trace.decoder_decisions["syndrome"])
    println("  decoder actual/expected: ",
        trace.decoder_decisions["actual"], " / ", trace.decoder_decisions["expected"])
    println("  recovery: ",
        trace.recovery_actions[1]["pauli"], "@", trace.recovery_actions[1]["target"])
    println("  oracle verdict: ", trace.logical_verdicts["oracle_verdict"])
end
