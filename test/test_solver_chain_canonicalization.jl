if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "Solver-chain query canonicalization" begin
    vars = [:x1, :x2, :x3]
    q1 = normalize_query(
        [boolvar(:x1), bxor(boolvar(:x3), boolvar(:x2))],
        vars;
        subject="bitflip_clean",
        max_fault_weight=2,
        construct_cache=false,
        metadata=Dict{String,Any}(
            "subject_id" => "subject-A",
            "bug_id" => "none",
            "baseline" => "paper",
            "seed" => "1",
            "normalized_from_constraint_query" => false,
        ),
    )
    q2 = normalize_query(
        [bxor(boolvar(:x2), boolvar(:x3)), boolvar(:x1)],
        vars;
        subject="bitflip_clean",
        max_fault_weight=2,
        construct_cache=false,
        metadata=Dict{String,Any}(
            "subject_id" => "subject-A",
            "bug_id" => "none",
            "baseline" => "paper",
            "seed" => "1",
            "normalized_from_constraint_query" => false,
        ),
    )
    @test q1.hashes["full_query_hash"] == q2.hashes["full_query_hash"]

    q3 = normalize_query(
        [boolvar(:x1), bxor(boolvar(:x3), boolvar(:x2))],
        vars;
        subject="bitflip_clean",
        avoid=Set(["x1=1;x2=0;x3=0"]),
        max_fault_weight=2,
        construct_cache=false,
    )
    @test q1.hashes["full_query_hash"] != q3.hashes["full_query_hash"]

    simplified = normalize_query(
        [bxor(boolvar(:x1), boolvar(:x1)), boolvar(:x2), boolvar(:x2)],
        vars;
        construct_cache=false,
    )
    @test simplified.canonical_constraints == ["const:false", "var:x2"]

    q4 = normalize_query(
        [boolvar(:x1)],
        vars;
        subject="bitflip_clean",
        construct_cache=false,
        metadata=Dict{String,Any}(
            "subject_id" => "subject-B",
            "bug_id" => "bug-001",
            "baseline" => "paper",
            "seed" => "seed-1",
        ),
    )
    @test haskey(ConQEC.solver_chain_hash_components(q4), "subject_id_hash")
    @test ConQEC.solver_chain_hash_components(q4)["subject_id_hash"] !=
        ConQEC.solver_chain_hash_components(q1)["subject_id_hash"]

    components = ConQEC.solver_chain_hash_components(q1)
    @test components["schema_version"] == ConQEC.SOLVER_CHAIN_QUERY_CANONICALIZER_VERSION
    @test haskey(components, "full_query_hash")
    @test haskey(components, "branch_flip_hash")

    @test haskey(q1.metadata, "schema_version")
    @test q1.hashes["capacity_hash"] == ConQEC.stable_hash("capacity", "2")
end
