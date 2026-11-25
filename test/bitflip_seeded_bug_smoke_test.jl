@testset "bit-flip seeded bug smoke" begin
    dir = mktempdir()
    subject = BitFlipSubject(:buggy_decoder)
    result = run_concolic(
        input -> run_bitflip_subject(subject, input),
        bitflip_fault_vars();
        max_tests=8,
        max_fault_weight=1,
        witness_dir=dir,
    )

    @test result.bug_found
    @test result.generated_tests == 2
    @test result.witness_path !== nothing
    @test isfile(result.witness_path)
    @test result.witness["earliest_divergence_stage"] == "decoder"
    @test result.witness["decoder_output"] == "q2"
    @test result.witness["expected_decoder_output"] == "q1"
end
