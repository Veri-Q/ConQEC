if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "SMT solver timeout" begin
    script = tempname()
    write(script, "#!/bin/sh\nsleep 2\n")
    chmod(script, 0o755)
    backend = Z3Backend([:x1]; solver_path=script, args=String[], timeout_ms=50)
    query = build_query([boolvar(:x1)], nothing, [:x1])
    result = solve_query(backend, query)
    @test result.status == :timeout
    @test result.metadata["solver_status"] == "TIMEOUT"
    @test result.metadata["solve_time_ms"] >= 0
    @test result.metadata["query_hash"] == query.query_hash
end
