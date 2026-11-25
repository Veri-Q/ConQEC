if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "model-to-fault-pattern mapping" begin
    vars = bitflip_fault_vars()
    model = Dict(:x1 => false, :x2 => true, :x3 => false)
    pattern = model_to_fault_pattern(vars, model)

    @test length(pattern) == 3
    @test pattern[2]["variable"] == "x2"
    @test pattern[2]["location"] == "q2"
    @test pattern[2]["site"] == "data"
    @test pattern[2]["label"] == "X@q2"
    @test pattern[2]["pauli"] == "X"
    @test pattern[2]["active"] == true

    string_keyed_model = Dict("x1" => false, "x2" => true, "x3" => false)
    string_keyed_pattern = model_to_fault_pattern(vars, string_keyed_model)

    @test assignment_key(vars, string_keyed_model) == "x1=0;x2=1;x3=0"
    @test string_keyed_pattern[2]["active"] == true

    trace = ConcolicTrace(
        "string-keyed";
        fault_vars=["x1", "x2"],
        fault_assignments=Dict("x1" => true, "x2" => false),
    )

    @test trace.fault_vars == [:x1, :x2]
    @test assignment_key(trace.fault_vars, trace.fault_assignments) == "x1=1;x2=0"

    round_vars = [:x_r1_q1, :z_r2_q3]
    round_model = Dict(:x_r1_q1 => true, :z_r2_q3 => false)
    round_pattern = model_to_fault_pattern(round_vars, round_model)

    @test round_pattern[1]["location"] == "r1:q1"
    @test round_pattern[1]["label"] == "X@r1:q1"
    @test round_pattern[2]["location"] == "r2:q3"
    @test round_pattern[2]["label"] == "Z@r2:q3"
end
