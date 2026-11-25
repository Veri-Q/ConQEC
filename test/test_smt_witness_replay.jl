if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "SMT witness replay" begin
    if Sys.which("z3") === nothing
        @warn "z3 not found; skipping SMT witness replay"
    else
        subject = BitFlipSubject(:buggy_decoder)
        result = run_concolic_subject(
            subject;
            solver=Z3Backend(bitflip_fault_vars(); solver_path="z3", max_weight=1),
            max_tests=4,
            max_fault_weight=1,
            witness_dir=mktempdir(),
            stop_on_bug=true,
        )

        @test result.bug_found
        @test result.witness["solver_backend"] == "z3"
        @test result.witness["earliest_divergence_stage"] == "decoder"
        @test haskey(result.witness["metadata"], "input_solver_query")
        @test result.witness["metadata"]["input_solver_query"]["solver_status"] == "SAT"

        replay_assignment = witness_fault_assignment(result.witness)
        replay_trace = run_subject(subject, replay_assignment)
        @test ConQEC.trace_has_bug(replay_trace)
        @test earliest_divergence(replay_trace) == "decoder"
        @test replay_trace.decoder_decisions["actual"] == "q2"
    end
end
