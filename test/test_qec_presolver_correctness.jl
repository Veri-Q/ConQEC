if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "QECC presolver correctness" begin
    vars = [:x1, :x2, :x3]
    small = normalize_query(
        [bxor(boolvar(:x1), boolvar(:x2)), boolvar(:x1)],
        vars;
        max_fault_weight=1,
        construct_cache=false,
    )
    presolve_small = ConQEC.run_qecc_presolve(ConQEC.no_slice_query(small))
    @test presolve_small.status == :sat
    @test presolve_small.reason == "qec-presolve-sat"
    @test presolve_small.metadata["presolver_status"] == "SAT"

    unsat = normalize_query(
        [boolvar(:x1), bnot(boolvar(:x1))],
        vars;
        max_fault_weight=1,
        construct_cache=false,
    )
    presolve_unsat = ConQEC.run_qecc_presolve(ConQEC.no_slice_query(unsat))
    @test presolve_unsat.status in (:unsat, :unsupported)
    if presolve_unsat.status == :unsat
        @test presolve_unsat.metadata["presolver_status"] == "UNSAT"
        @test startswith(presolve_unsat.reason, "qec-presolve-")
    else
        @test startswith(presolve_unsat.reason, "qec-presolve-")
    end

    big = [Symbol("x$(i)") for i in 1:23]
    large_query = normalize_query([boolvar(:x1)], big; max_fault_weight=1, construct_cache=false)
    presolve_large = ConQEC.run_qecc_presolve(ConQEC.no_slice_query(large_query))
    @test presolve_large.status in (:sat, :unsupported)

    @test ConQEC.qec_presolve_supported(small)
    @test ConQEC.qec_presolve_supported(unsat)
end
