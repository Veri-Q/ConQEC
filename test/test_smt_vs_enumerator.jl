if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

function small_registry_subjects_for_smt()
    excluded_benchmark_families = Set([
        "LargeDecoderTable",
        "WeightTwoFaults",
        "RepeatedRoundHistory",
        "FailureAdjacentSiblings",
        "MinimizationStress",
    ])
    return [
        config for config in paper_subject_configs()
        if !(config.subject isa LargeRepetitionSubject) &&
           length(subject_fault_vars(config.subject)) <= 30 &&
           get(subject_metadata(config.subject), "max_fault_weight", 1) <= 1 &&
           !(string(get(subject_metadata(config.subject), "benchmark_family", "")) in excluded_benchmark_families)
    ]
end

@testset "SMT vs local enumerator" begin
    if Sys.which("z3") === nothing
        @warn "z3 not found; skipping SMT/enumerator equivalence"
    else
        configs = small_registry_subjects_for_smt()
        @test !isempty(configs)
        @test all(config -> length(subject_fault_vars(config.subject)) <= 30, configs)
        @test all(config -> get(subject_metadata(config.subject), "max_fault_weight", 1) <= 1, configs)
        for config in configs
            subject = config.subject
            fault_vars = subject_fault_vars(subject)
            zero = zero_assignment(fault_vars)
            trace = run_subject(subject, zero)
            enum = LocalEnumeratorBackend(fault_vars; max_weight=max_fault_weight(trace))
            z3 = Z3Backend(fault_vars; solver_path="z3", max_weight=max_fault_weight(trace))

            @testset "$(subject_name(subject))" begin
                for branch_index in path_branch_indices(trace)
                    avoid = Set([assignment_key(fault_vars, zero)])
                    enum_result = solve_branch_query(enum, trace, branch_index; avoid=avoid)
                    z3_result = solve_branch_query(z3, trace, branch_index; avoid=avoid)

                    @test (enum_result.status == :sat) == (z3_result.status == :sat)
                    @test (enum_result.status == :unsat) == (z3_result.status == :unsat)
                    if z3_result.status == :sat
                        @test all(
                            constraint -> evaluate(constraint, z3_result.model),
                            branch_query_constraints(trace, branch_index),
                        )
                        z3_trace = run_subject(subject, z3_result.model)
                        @test z3_trace isa ConcolicTrace
                    end
                    if enum_result.status == :sat
                        @test all(
                            constraint -> evaluate(constraint, enum_result.model),
                            branch_query_constraints(trace, branch_index),
                        )
                        enum_trace = run_subject(subject, enum_result.model)
                        @test enum_trace isa ConcolicTrace
                    end
                end
            end
        end
    end
end
