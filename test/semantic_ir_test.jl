if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "semantic IR oracle check contract" begin
    trace = SemanticTrace("semantic_ir_guard", fault_vars=[:x1, :x2, :x3],
        fault_assignments=Dict(:x1 => false, :x2 => false, :x3 => true))
    record_oracle_check!(trace, "logical:oracle", :logical_check, bconst(true), true)
    oracle_check = trace.oracle_checks[end]

    @test !oracle_check.path_constraint
    @test !oracle_check.flippable
    @test oracle_check.accepted
end

@testset "semantic IR branch source hygiene" begin
    @test_throws ErrorException SemanticGuard(
        "decoder:oracle_source",
        :decoder,
        FaultVar(:x1),
        true,
    )

    @test_throws ErrorException SemanticGuard(
        "decoder:target_guard",
        :decoder,
        FaultVar(:target_error),
        true,
    )

    @test_throws ErrorException SemanticGuard(
        "decoder:seeded_guard",
        :decoder,
        FaultVar(:seeded_failure),
        true,
    )

    @test_throws ErrorException SemanticGuard(
        "decoder:contract_guard",
        :decoder,
        FaultVar(:contract_violation),
        true,
    )

    @test_throws ErrorException SemanticGuard(
        "decoder:clean_name",
        :decoder,
        FaultVar(:x1),
        true;
        source=:oracle,
    )

    valid = SemanticGuard(
        "decoder:syndrome_stable",
        :decoder,
        ParityExpr(boolvar(:x1), boolvar(:x2)),
        true;
        source=:semantic,
    )
    @test valid.path_constraint
    @test valid.flippable

    @test check_no_oracle_branch(valid)
    @test check_no_target_dependency(boolvar(:syndrome_active))
    @test check_no_seeded_contract_dependency(boolvar(:fault_pattern))
    @test check_branch_source_hygiene(valid) isa SemanticGuard
end
