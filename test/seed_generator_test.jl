@testset "fault seed generation" begin
    vars = bitflip_fault_vars()
    expected_single_fault_keys = [
        "x1=0;x2=0;x3=0",
        "x1=1;x2=0;x3=0",
        "x1=0;x2=1;x3=0",
        "x1=0;x2=0;x3=1",
    ]

    seeds = generate_fault_seeds(vars; max_fault_weight=1)
    @test length(seeds) == 4
    @test [assignment_key(vars, seed) for seed in seeds] == expected_single_fault_keys
    @test [fault_weight(seed, vars) for seed in seeds] == [0, 1, 1, 1]

    no_zero = generate_fault_seeds(vars; max_fault_weight=1, include_zero=false)
    @test [assignment_key(vars, seed) for seed in no_zero] == expected_single_fault_keys[2:end]

    weight_two = generate_fault_seeds(vars; max_fault_weight=2)
    @test [assignment_key(vars, seed) for seed in weight_two] == [
        "x1=0;x2=0;x3=0",
        "x1=1;x2=0;x3=0",
        "x1=0;x2=1;x3=0",
        "x1=0;x2=0;x3=1",
        "x1=1;x2=1;x3=0",
        "x1=1;x2=0;x3=1",
        "x1=0;x2=1;x3=1",
    ]
    @test [fault_weight(seed, vars) for seed in weight_two] == [0, 1, 1, 1, 2, 2, 2]
end

@testset "repetition-code fault seed generation" begin
    vars = repetition_fault_vars(5)
    seeds = generate_fault_seeds(vars; max_fault_weight=1)
    @test length(seeds) == 6
    @test first(seeds) == zero_assignment(vars)
    @test [fault_weight(seed, vars) for seed in seeds] == [0, 1, 1, 1, 1, 1]
end

@testset "seeded concolic explorer initialization" begin
    vars = bitflip_fault_vars()
    seeds = generate_fault_seeds(vars; max_fault_weight=1)
    expected_keys = [assignment_key(vars, seed) for seed in seeds]

    explorer = ConcolicExplorer(vars; seeds=seeds, max_tests=8, max_fault_weight=1)
    @test [assignment_key(vars, seed) for seed in explorer.worklist] == expected_keys
    @test length(explorer.seen_inputs) == length(seeds)

    initial_list_explorer = ConcolicExplorer(vars; initial=seeds, max_tests=8, max_fault_weight=1)
    @test [assignment_key(vars, seed) for seed in initial_list_explorer.worklist] == expected_keys

    duplicate_explorer = ConcolicExplorer(vars; seeds=[seeds[1], seeds[1], seeds[2]])
    @test [assignment_key(vars, seed) for seed in duplicate_explorer.worklist] == expected_keys[1:2]
    @test length(duplicate_explorer.seen_inputs) == 2

    clean = BitFlipSubject(:clean)
    result = run_concolic(
        input -> run_bitflip_subject(clean, input),
        vars;
        seeds=seeds,
        max_tests=8,
        max_fault_weight=1,
        witness_dir=mktempdir(),
    )

    @test !result.bug_found
    @test result.generated_tests == 4
    @test length(result.unique_syndromes) == 4
    @test [assignment_key(vars, trace.fault_assignments) for trace in result.traces] == expected_keys
end
