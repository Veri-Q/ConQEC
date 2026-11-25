if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "SMT-LIB export" begin
    expr = band(bxor(boolvar(:x1), boolvar(:x2)), bnot(boolvar(:x3)))

    @test smt_symbol(:x1) == "x1"
    @test smt_symbol(Symbol("x 1")) == "|x 1|"
    @test expr_to_smt2(expr) == "(and (xor x1 x2) (not x3))"

    query = constraints_to_smt2([expr], [:x1, :x2, :x3]; include_get_model=false)
    @test occursin("(set-logic QF_BV)", query)
    @test occursin("(declare-fun x1 () Bool)", query)
    @test occursin("(assert (and (xor x1 x2) (not x3)))", query)
    @test occursin("(check-sat)", query)
    @test !occursin("(get-model)", query)

    capacity = fault_capacity_constraint([:x1, :x2, :x3], 1)
    capacity_text = expr_to_smt2(capacity)
    @test capacity_text ==
        "(and (or (not x1) (not x2)) (or (not x1) (not x3)) (or (not x2) (not x3)))"
    @test evaluate(capacity, Dict(:x1 => true, :x2 => false, :x3 => false))
    @test !evaluate(capacity, Dict(:x1 => true, :x2 => true, :x3 => false))

    trace = run_bitflip_subject(BitFlipSubject(:clean), zero_assignment(bitflip_fault_vars()))
    semantic_rows = decoder_recovery_semantics(trace)
    @test length(semantic_rows) == 4
    clean_syndrome_10 = only([
        row for row in semantic_rows
        if row["syndrome_pattern"] == Dict{String,Any}("s12" => true, "s23" => false)
    ])
    @test clean_syndrome_10["branch_id"] == "decoder:syndrome_10"
    @test clean_syndrome_10["decoder_output"] == "q1"
    @test clean_syndrome_10["recovery"]["target"] == "q1"

    buggy_trace = run_bitflip_subject(
        BitFlipSubject(:buggy_decoder),
        zero_assignment(bitflip_fault_vars()),
    )
    buggy_syndrome_10 = only([
        row for row in decoder_recovery_semantics(buggy_trace)
        if row["syndrome_pattern"] == Dict{String,Any}("s12" => true, "s23" => false)
    ])
    @test buggy_syndrome_10["decoder_output"] == "q2"
    @test buggy_syndrome_10["recovery"]["target"] == "q2"

    wrong_recovery_trace = run_bitflip_subject(
        BitFlipSubject(:wrong_recovery_target),
        zero_assignment(bitflip_fault_vars()),
    )
    wrong_recovery_syndrome_10 = only([
        row for row in decoder_recovery_semantics(wrong_recovery_trace)
        if row["syndrome_pattern"] == Dict{String,Any}("s12" => true, "s23" => false)
    ])
    @test wrong_recovery_syndrome_10["decoder_output"] == "q1"
    @test wrong_recovery_syndrome_10["recovery"]["target"] == "q2"

    history_drop_trace = run_round_repetition_subject(
        RoundRepetitionSubject(3, 2, :history_drop_bug),
        zero_assignment(round_repetition_fault_vars(3, 2)),
    )
    history_drop_rows = decoder_recovery_semantics(history_drop_trace)
    @test !any(row -> row["branch_id"] == "decoder:history_10_10", history_drop_rows)
    history_drop_00_10 = only([
        row for row in history_drop_rows
        if row["branch_id"] == "decoder:history_00_10"
    ])
    @test history_drop_00_10["decoder_output"] == "r2_q1"
    @test history_drop_00_10["syndrome_pattern"] == Dict{String,Any}(
        "r2_s12" => true,
        "r2_s23" => false,
    )
    @test !haskey(history_drop_00_10["syndrome_pattern"], "r1_s12")

    branch_query = branch_query_smt2(trace, 1; include_get_model=true)
    @test occursin("(set-logic QF_BV)", branch_query)
    @test occursin("(declare-fun x1 () Bool)", branch_query)
    @test occursin("(check-sat)", branch_query)
    @test occursin("(get-model)", branch_query)
    @test occursin("(assert", branch_query)
    @test occursin("(assert (not (and (not (xor x1 x2)) (not (xor x2 x3)))))", branch_query)
    @test occursin("(assert (and (or (not x1) (not x2))", branch_query)
    @test occursin("(_ BitVec", branch_query)
    @test occursin("conqec_decoder_branch_bv", branch_query)
    @test occursin("conqec_recovery_choice_bv", branch_query)
    @test occursin("(assert (bvule conqec_decoder_branch_bv", branch_query)
    for snippet in [
        "(declare-fun conqec_sigma_s12 () Bool)",
        "(assert (= conqec_sigma_s12 (xor x1 x2)))",
        "(declare-fun conqec_sigma_s23 () Bool)",
        "(assert (= conqec_sigma_s23 (xor x2 x3)))",
        "(assert (=> (and (not conqec_sigma_s12) (not conqec_sigma_s23)) (= conqec_decoder_branch_bv #b00)))",
        "(assert (=> (and conqec_sigma_s12 (not conqec_sigma_s23)) (= conqec_decoder_branch_bv #b01)))",
        "(assert (=> (and conqec_sigma_s12 conqec_sigma_s23) (= conqec_decoder_branch_bv #b10)))",
        "(assert (=> (and (not conqec_sigma_s12) conqec_sigma_s23) (= conqec_decoder_branch_bv #b11)))",
        "(assert (=> (and (not conqec_sigma_s12) (not conqec_sigma_s23)) (= conqec_decoder_choice_bv #b00)))",
        "(assert (=> (and conqec_sigma_s12 (not conqec_sigma_s23)) (= conqec_decoder_choice_bv #b01)))",
        "(assert (=> (and conqec_sigma_s12 conqec_sigma_s23) (= conqec_decoder_choice_bv #b10)))",
        "(assert (=> (and (not conqec_sigma_s12) conqec_sigma_s23) (= conqec_decoder_choice_bv #b11)))",
        "(assert (=> (and (not conqec_sigma_s12) (not conqec_sigma_s23)) (= conqec_recovery_choice_bv #b00)))",
        "(assert (=> (and conqec_sigma_s12 (not conqec_sigma_s23)) (= conqec_recovery_choice_bv #b01)))",
        "(assert (=> (and conqec_sigma_s12 conqec_sigma_s23) (= conqec_recovery_choice_bv #b10)))",
        "(assert (=> (and (not conqec_sigma_s12) conqec_sigma_s23) (= conqec_recovery_choice_bv #b11)))",
        "(assert (=> (= conqec_decoder_choice_bv #b00) (= conqec_recovery_choice_bv #b00)))",
        "(assert (=> (= conqec_decoder_choice_bv #b01) (= conqec_recovery_choice_bv #b01)))",
        "(assert (=> (= conqec_decoder_choice_bv #b10) (= conqec_recovery_choice_bv #b10)))",
        "(assert (=> (= conqec_decoder_choice_bv #b11) (= conqec_recovery_choice_bv #b11)))",
    ]
        @test occursin(snippet, branch_query)
    end

    no_bv_query = branch_query_smt2(
        trace,
        1;
        include_get_model=false,
        include_bv_annotations=false,
    )
    @test !occursin("(_ BitVec", no_bv_query)
    @test !occursin("conqec_sigma_", no_bv_query)
    @test !occursin("conqec_decoder_branch_bv", no_bv_query)
    @test !occursin("conqec_decoder_choice_bv", no_bv_query)
    @test !occursin("conqec_recovery_choice_bv", no_bv_query)

    if Sys.which("z3") !== nothing
        z3_query = branch_query_smt2(trace, 1; include_get_model=false)
        z3_query_path = tempname() * ".smt2"
        write(z3_query_path, z3_query)
        try
            @test strip(read(`z3 -smt2 $z3_query_path`, String)) == "sat"
        finally
            rm(z3_query_path; force=true)
        end
    end

    no_capacity_query = branch_query_smt2(
        trace,
        1;
        include_get_model=false,
        include_capacity=false,
    )
    @test !occursin("(or (not x1) (not x2))", no_capacity_query)
end
