if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "SMT backend basic" begin
    vars = [:x1, :x2, :x3]
    backend = Z3Backend(vars; solver_path="z3", timeout_ms=30000, max_weight=1)
    constraints = [boolvar(:x1), bnot(boolvar(:x2))]
    query = build_query(
        add_fault_capacity_constraint(constraints, vars; max_weight=1),
        nothing,
        vars,
        Dict("logic" => "QF_BV", "include_get_model" => true),
    )

    @test backend isa AbstractConstraintBackend
    @test query isa ConstraintQuery
    @test occursin("(set-logic QF_BV)", query.text)
    @test occursin("(declare-fun x1 () Bool)", query.text)
    @test occursin("(check-sat)", query.text)
    @test occursin("(get-model)", query.text)

    exported = solve_query(SMTLibExportBackend(vars), query)
    @test exported.status == :exported
    @test exported.backend == "smtlib-export"
    @test exported.query_text == query.text
    @test exported.metadata["solver_status"] == "EXPORTED"
    @test exported.metadata["query_hash"] == query.query_hash
    export_stats = query_stats(query, exported)
    @test export_stats["backend"] == "smtlib-export"
    @test export_stats["selected_branch_index"] === nothing
    @test export_stats["solver_status"] == "EXPORTED"

    @test_throws ErrorException parse_model("sat\n", vars)
    unknown_status, unknown_model = parse_model("unknown\n", vars)
    @test unknown_status == :unknown
    @test unknown_model === nothing

    fake_dir = mktempdir()
    fake_bitwuzla = joinpath(fake_dir, "fake_bitwuzla.sh")
    write(
        fake_bitwuzla,
        "#!/bin/sh\n" *
        "if [ \"\$1\" = \"--version\" ]; then\n" *
        "  echo \"Bitwuzla fake 0.0\"\n" *
        "  exit 0\n" *
        "fi\n" *
        "printf 'sat\\n(\\n  (define-fun x1 () Bool\\n    true)\\n  (define-fun x2 () Bool\\n    false)\\n  (define-fun x3 () Bool\\n    false)\\n)\\n'\n",
    )
    chmod(fake_bitwuzla, 0o755)
    bitwuzla_result = solve_query(
        BitwuzlaBackend(vars; solver_path=fake_bitwuzla, args=String[], timeout_ms=30000),
        query,
    )
    @test bitwuzla_result.status == :sat
    @test bitwuzla_result.backend == "bitwuzla"
    @test bitwuzla_result.model[:x1]
    @test bitwuzla_result.metadata["solver_version"] == "Bitwuzla fake 0.0"
    @test bitwuzla_result.metadata["solver_args"] == String[]
    @test bitwuzla_result.metadata["timed_out"] == false
    @test bitwuzla_result.metadata["timeout_ms"] == 30000

    if Sys.which("z3") !== nothing
        result = solve_query(backend, query)
        @test result.status == :sat
        @test result.model[:x1]
        @test !result.model[:x2]
        @test result.metadata["backend"] == "z3"
        @test result.metadata["solver_path"] == "z3"
        @test result.metadata["solver_status"] == "SAT"
        @test result.metadata["query_bytes"] == sizeof(query.text)
        @test result.metadata["fault_variable_count"] == 3
        @test haskey(result.metadata, "solve_time_ms")
        @test result.metadata["timed_out"] == false
        @test result.metadata["timeout_ms"] == 30000
        @test result.metadata["solver_args"] == ["-smt2"]
        @test haskey(result.metadata, "parsed_model")
        z3_stats = query_stats(query, result)
        @test z3_stats["solver_status"] == "SAT"
        @test z3_stats["query_hash"] == query.query_hash
    end
end
