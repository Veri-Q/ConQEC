if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "SMT model to fault pattern" begin
    vars = [:x1, :z2, :y3, :x_r2_q4]
    model = Dict(:x1 => true, :z2 => false, :y3 => true, :x_r2_q4 => true)
    pattern = model_to_fault_pattern(model, vars)
    by_var = Dict(item["variable"] => item for item in pattern)

    @test by_var["x1"]["active"]
    @test by_var["x1"]["pauli"] == "X"
    @test by_var["x1"]["location"] == "q1"
    @test !by_var["z2"]["active"]
    @test by_var["z2"]["pauli"] == "Z"
    @test by_var["y3"]["pauli"] == "Y"
    @test by_var["y3"]["label"] == "Y@q3"
    @test by_var["x_r2_q4"]["location"] == "r2:q4"

    registry_pattern = model_to_fault_pattern(
        model,
        Dict("fault_vars" => string.(vars)),
    )
    @test registry_pattern == pattern
end
