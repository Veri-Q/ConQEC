if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "symbolic stabilizer Pauli-frame layer" begin
    x1 = boolvar(:x1)
    x2 = boolvar(:x2)
    x3 = boolvar(:x3)
    state = symbolic_stabilizer_from_faults(
        "three_qubit_bitflip_test",
        3,
        ["s12", "s23"],
        [[1, 2], [2, 3]],
        BoolExpr[x1, x2, x3];
        pauli="X",
        generator_paulis=["Z", "Z"],
    )

    phases = stabilizer_generator_phase_exprs(state)
    @test expr_to_string(phases[1]) == "(x1 xor x2)"
    @test expr_to_string(phases[2]) == "(x2 xor x3)"

    model = Dict(:x1 => true, :x2 => false, :x3 => false)
    @test stabilizer_generator_phase_values(state, model) == [true, false]
    @test symbolic_residual_vector(state, model) == [true, false, false]
    @test symbolic_residual_weight(state, model) == 1
    @test !symbolic_logical_ok(state, model)

    recovered = copy_symbolic_stabilizer_state(state)
    absorb_recovery!(recovered, Dict("pauli" => "X", "target" => "q1"))
    @test symbolic_residual_vector(recovered, model) == [false, false, false]
    @test symbolic_residual_weight(recovered, model) == 0
    @test symbolic_logical_ok(recovered, model)

    trace = run_bitflip_subject(BitFlipSubject(:buggy_decoder), model)
    symbolic = trace.metadata["symbolic_stabilizer"]
    @test symbolic["representation"] ==
        "symbolic Pauli frame with stabilizer generator phases"
    @test symbolic["tracked_pauli"] == "X"
    @test symbolic["pre_recovery_generators"][1]["phase_expr"] == "(x1 xor x2)"
    @test trace.logical_verdicts["residual_error"] ==
        symbolic["post_recovery_residual"]
    @test trace.logical_verdicts["residual_weight"] ==
        symbolic["post_recovery_residual_weight"]

    phase_trace = run_phaseflip_subject(PhaseFlipSubject(:buggy_decoder),
        Dict(:z1 => true, :z2 => false, :z3 => false))
    @test phase_trace.metadata["symbolic_stabilizer"]["tracked_pauli"] == "Z"

    round_subject = RoundRepetitionSubject(3, 2, :clean)
    round_trace = run_round_repetition_subject(
        round_subject,
        Dict(
            :x_r1_q1 => true,
            :x_r1_q2 => false,
            :x_r1_q3 => false,
            :x_r2_q1 => false,
            :x_r2_q2 => false,
            :x_r2_q3 => false,
        ),
    )
    @test round_trace.metadata["symbolic_stabilizer"]["tracked_pauli"] == "X"
    @test round_trace.metadata["symbolic_stabilizer"]["post_recovery_residual_weight"] == 0
end
