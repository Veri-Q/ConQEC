if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

mutable struct RecordingBranchSolver <: AbstractConcolicSolver
    delegate::BruteForceBoolSolver
    branches::Vector{Int}
end

ConQEC.solver_name(::RecordingBranchSolver) = "recording-branch-solver"
ConQEC.solver_fault_vars(solver::RecordingBranchSolver) =
    solver_fault_vars(solver.delegate)
ConQEC.solver_max_weight(solver::RecordingBranchSolver) =
    solver_max_weight(solver.delegate)

function ConQEC.solve_branch_query(solver::RecordingBranchSolver,
    trace::ConcolicTrace,
    branch_index::Integer;
    avoid=Set{String}())

    push!(solver.branches, Int(branch_index))
    return solve_branch_query(solver.delegate, trace, branch_index; avoid=avoid)
end

@testset "Solver backend boundary" begin
    vars = [:x1, :x2]
    constraints = [boolvar(:x1), bnot(boolvar(:x2))]
    solver = BruteForceBoolSolver(vars)

    result = solve_model(solver, constraints)
    @test solver isa AbstractConcolicSolver
    @test result isa SolverResult
    @test result.status == :sat
    @test result.backend == "bruteforce-bool"
    @test result.model == Dict(:x1 => true, :x2 => false)
    @test result.query_text === nothing
    @test solver_name(solver) == "bruteforce-bool"
    @test solver_fault_vars(solver) == vars
    @test solver_max_weight(solver) === nothing
    @test solver_query_text(solver, constraints) === nothing

    weighted_solver = BruteForceBoolSolver(vars; max_weight=1)
    @test solver_max_weight(weighted_solver) == 1

    many_vars = [Symbol("x$(idx)") for idx in 1:42]
    many_solver = BruteForceBoolSolver(many_vars; max_weight=1)
    many_result = solve_model(many_solver, [boolvar(:x42)])
    @test many_result.status == :sat
    @test many_result.model[:x42] == true
    @test count(identity, values(many_result.model)) == 1

    unsat = solve_model(solver, [boolvar(:x1), bnot(boolvar(:x1))])
    @test unsat.status == :unsat
    @test unsat.model === nothing

    @test solve(solver, constraints) == Dict(:x1 => true, :x2 => false)
    @test solve(solver, [boolvar(:x1), bnot(boolvar(:x1))]) === nothing

    export_solver = SmtLibExportSolver(vars; include_get_model=false)
    query = solver_query_text(export_solver, constraints)
    exported = solve_model(export_solver, constraints)

    @test export_solver isa AbstractConcolicSolver
    @test solver_name(export_solver) == "smtlib-export"
    @test solver_fault_vars(export_solver) == vars
    @test solver_max_weight(export_solver) === nothing
    @test exported.status == :exported
    @test exported.model === nothing
    @test exported.query_text == query
    @test occursin("(set-logic QF_BV)", query)
    @test occursin("(declare-fun x1 () Bool)", query)
    @test occursin("(declare-fun x2 () Bool)", query)
    @test occursin("(assert x1)", query)
    @test occursin("(assert (not x2))", query)
    @test occursin("(check-sat)", query)
    @test !occursin("(get-model)", query)

    parsed_status, parsed_model = parse_smt_bool_model(
        """
        sat
        (
          (define-fun x1 () Bool
            true)
          (define-fun x2 () Bool
            false)
        )
        """,
        vars,
    )
    @test parsed_status == :sat
    @test parsed_model == Dict(:x1 => true, :x2 => false)

    missing_solver = ExternalSmtSolver(vars; command="__missing_conqec_smt_solver__")
    missing_result = solve_model(missing_solver, constraints)
    @test solver_fault_vars(missing_solver) == vars
    @test missing_result.status == :unavailable
    @test missing_result.model === nothing
    @test occursin("(check-sat)", missing_result.query_text)

    missing_explorer = run_concolic_subject(
        BitFlipSubject(:buggy_decoder);
        max_tests=4,
        solver=ExternalSmtSolver(bitflip_fault_vars(); command="__missing_conqec_smt_solver__"),
        witness_dir=mktempdir(),
        stop_on_bug=true,
    )
    @test !missing_explorer.bug_found
    @test missing_explorer.generated_tests == 1

    bitflip_trace = run_bitflip_subject(
        BitFlipSubject(:clean),
        Dict(:x1 => false, :x2 => false, :x3 => false),
    )
    branch_solver = BruteForceBoolSolver(bitflip_fault_vars(); max_weight=1)
    avoided_zero = Set(["x1=0;x2=0;x3=0"])
    branch_result = solve_branch_query(branch_solver, bitflip_trace, 1; avoid=avoided_zero)
    direct_result = solve_model(
        branch_solver,
        branch_query_constraints(bitflip_trace, 1);
        avoid=avoided_zero,
    )
    @test branch_result.status == :sat
    @test branch_result.model == direct_result.model
    @test all(
        constraint -> evaluate(constraint, branch_result.model),
        branch_query_constraints(bitflip_trace, 1),
    )

    exported_branch = solve_branch_query(
        SmtLibExportSolver(bitflip_fault_vars(); include_get_model=false),
        bitflip_trace,
        1;
        avoid=Set(["x1=1;x2=0;x3=0"]),
    )
    @test exported_branch.status == :exported
    @test exported_branch.model === nothing
    @test occursin("conqec_sigma_s12", exported_branch.query_text)
    @test occursin("conqec_decoder_branch_bv", exported_branch.query_text)
    @test occursin("conqec_recovery_choice_bv", exported_branch.query_text)
    @test occursin("(assert (or (not x1) x2 x3))", exported_branch.query_text)
    @test !occursin("(get-model)", exported_branch.query_text)

    missing_branch = solve_branch_query(
        ExternalSmtSolver(bitflip_fault_vars(); command="__missing_conqec_smt_solver__"),
        bitflip_trace,
        1;
        avoid=Set(["x1=1;x2=0;x3=0"]),
    )
    @test missing_branch.status == :unavailable
    @test missing_branch.model === nothing
    @test occursin("conqec_sigma_s12", missing_branch.query_text)
    @test occursin("conqec_decoder_branch_bv", missing_branch.query_text)
    @test occursin("conqec_recovery_choice_bv", missing_branch.query_text)
    @test occursin("(get-model)", missing_branch.query_text)
    @test occursin("(assert (or (not x1) x2 x3))", missing_branch.query_text)

    recording_solver = RecordingBranchSolver(
        BruteForceBoolSolver(bitflip_fault_vars(); max_weight=1),
        Int[],
    )
    recording_result = run_concolic_subject(
        BitFlipSubject(:clean);
        max_tests=4,
        solver=recording_solver,
        branch_strategy=:trace_order,
        witness_dir=mktempdir(),
    )
    @test !isempty(recording_solver.branches)
    @test all(branch -> branch in path_branch_indices(recording_result.traces[1]),
        recording_solver.branches[1:1])

    if Sys.which("z3") !== nothing
        external_solver = ExternalSmtSolver(vars; command="z3")
        external_result = solve_model(external_solver, constraints)
        @test solver_name(external_solver) == "external-smt:z3"
        @test external_result.status == :sat
        @test external_result.model == Dict(:x1 => true, :x2 => false)
        @test occursin("(get-model)", external_result.query_text)

        avoided = solve_model(
            external_solver,
            [boolvar(:x1)];
            avoid=Set(["x1=1;x2=0"]),
        )
        @test avoided.status == :sat
        @test avoided.model[:x1]
        @test avoided.model[:x2]

        external_branch = solve_branch_query(
            ExternalSmtSolver(bitflip_fault_vars(); command="z3"),
            bitflip_trace,
            1;
            avoid=Set(["x1=1;x2=0;x3=0"]),
        )
        @test external_branch.status == :sat
        @test assignment_key(bitflip_fault_vars(), external_branch.model) !=
            "x1=1;x2=0;x3=0"
        @test all(
            constraint -> evaluate(constraint, external_branch.model),
            branch_query_constraints(bitflip_trace, 1),
        )
        @test occursin("conqec_recovery_choice_bv", external_branch.query_text)

        external_explorer = run_concolic_subject(
            BitFlipSubject(:buggy_decoder);
            max_tests=4,
            solver=ExternalSmtSolver(bitflip_fault_vars(); command="z3"),
            witness_dir=mktempdir(),
            stop_on_bug=true,
        )
        @test external_explorer.bug_found
        @test external_explorer.witness["earliest_divergence_stage"] == "decoder"
        @test external_explorer.witness["decoder_output"] == "q2"
        @test external_explorer.witness["expected_decoder_output"] == "q1"
    end
end
