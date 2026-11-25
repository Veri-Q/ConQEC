if !isdefined(Main, :ConQEC)
    include(joinpath(@__DIR__, "..", "src", "ConQEC.jl"))
    using .ConQEC
end

using Test

@testset "paper subject catalog" begin
    configs = paper_subject_configs()
    names = paper_subject_names()

    @test length(names) == length(configs)
    @test length(configs) == 85
    @test length(unique(names)) == length(names)
    legacy_term = "cali" * "bration"
    @test all(config -> !occursin(legacy_term, lowercase(config.label)), configs)
    @test all(name -> !occursin(legacy_term, lowercase(name)), names)
    @test count(config_is_seeded_bug, configs) >= 60
    @test count(config_path_sensitive, configs) >= 20
    medium_hard_path_sensitive_bugs = [
        config for config in configs
        if config_is_seeded_bug(config) && config_path_sensitive(config) &&
           lowercase(string(get(
               config_bug_metadata(config),
               "hardness_bin",
               get(subject_metadata(config.subject), "hardness_bin", "easy"),
           ))) in ("medium", "hard")
    ]
    @test length(medium_hard_path_sensitive_bugs) >= 20
    @test count(config -> get(subject_metadata(config.subject), "benchmark_family", "") ==
        "WeightTwoFaults", configs) >= 7
    @test count(config -> get(subject_metadata(config.subject), "benchmark_family", "") ==
        "WeightThreeFaults", configs) == 0
    extended = extended_challenge_subject_configs()
    @test count(config -> get(subject_metadata(config.subject), "benchmark_family", "") ==
        "WeightThreeFaults", extended) >= 4
    @test count(config -> get(subject_metadata(config.subject), "benchmark_family", "") ==
        "RepeatedRoundHistory", configs) >= 6

    class_counts = Dict(class => 0 for class in HIGH_LEVEL_BUG_CLASSES)
    for config in configs
        config_is_seeded_bug(config) || continue
        class = config_bug_class(config)
        @test haskey(class_counts, class)
        class_counts[class] += 1
    end
    @test all(count >= 6 for count in values(class_counts))
    characterization_by_subject = Dict(
        string(row["subject"]) => row for row in benchmark_characterization_rows(configs)
    )
    for config in configs
        meta = config_is_seeded_bug(config) ? config_bug_metadata(config) :
            subject_metadata(config.subject)
        expected_bin = get(characterization_by_subject[config.label], "hardness_bin", "unknown")
        actual_bin = get(meta, "hardness_bin", expected_bin)
        @test lowercase(string(actual_bin)) == lowercase(string(expected_bin))
    end
    @test length(paper_diagnostic_contracts()) == length(configs)
    generated_contract = paper_diagnostic_contract_by_name("syndrome_wrong_support_bitflip_q1")
    @test generated_contract.bug_class == "syndrome_extraction_wiring"
    @test generated_contract.expected_decoder_actual == "q3"
    @test generated_contract.expected_decoder_expected == "q2"
    @test paper_subject_config_by_name("bitflip_buggy_decoder").subject.mode ==
        :buggy_decoder
    @test paper_subject_config_by_name("bitflip_buggy_decoder_table").label ==
        "bitflip_buggy_decoder"
    @test paper_subject_config_by_name(
        "round_repetition_d3_r2_history_drop_bug",
    ).subject.rounds == 2
    @test supported_subject_families() ==
        [
            :bitflip,
            :phaseflip,
            :steane,
            :surface,
            :repetition,
            :round_repetition,
            :large_decoder_table,
            :weight_two,
            :weight_three,
            :history_challenge,
            :failure_adjacent_sibling,
            :minimization_stress,
            :path_sensitive_challenges,
            :external_subjects,
        ]
    @test supported_subject_modes(:bitflip)["buggy_decoder_table"] == :buggy_decoder
    @test supported_subject_modes(:bitflip)["measurement_misuse"] ==
        :measurement_misuse
    @test supported_subject_modes(:bitflip)["priority_decoder_bug"] ==
        :priority_decoder_bug
    @test supported_subject_modes(:phaseflip)["wrong_recovery_target"] ==
        :wrong_recovery_target
    @test supported_subject_modes(:steane)["buggy_decoder_table"] == :buggy_decoder
    @test supported_subject_modes(:steane)["z_decoder_bug"] == :z_decoder_bug
    @test supported_subject_modes(:surface)["buggy_decoder_table"] == :buggy_decoder
    @test supported_subject_modes(:surface)["z_decoder_bug"] == :z_decoder_bug
    @test supported_subject_mode_names(:round_repetition) ==
        ["clean", "history_drop_bug", "inconsistent_control_bug"]
    @test supported_subject_modes(:large_decoder_table)["sparse_decoder_table_bug"] ==
        :sparse_decoder_table_bug
    @test supported_subject_modes(:weight_two)["decoder_pair_bug"] ==
        :decoder_pair_bug
    @test supported_subject_modes(:weight_three)["decoder_triple_bug"] ==
        :decoder_triple_bug
    @test supported_subject_modes(:history_challenge)["missing_reset_bug"] ==
        :missing_reset_bug
    large_decoder = paper_subject_config_by_name("large_decoder_table_a256_sparse_255_b")
    @test config_bug_metadata(large_decoder)["decoder_arms"] == 256
    @test config_bug_metadata(large_decoder)["reachable_syndromes"] == 257
    @test config_bug_metadata(large_decoder)["hardness_bin"] == "medium"
    weight_two = paper_subject_config_by_name("weight2_repetition_n250_unhandled_pair_bug_q47_q211")
    @test config_bug_metadata(weight_two)["expected_min_fault_weight"] == 2
    @test config_bug_metadata(weight_two)["max_fault_weight"] == 2
    @test config_bug_metadata(weight_two)["admissible_fault_assignments"] ==
        250 + div(250 * 249, 2)
    weight_three = only([
        config for config in extended
        if config.label == "weight3_repetition_n45_unhandled_triple_bug_q7_q31_q43"
    ])
    @test config_bug_metadata(weight_three)["expected_min_fault_weight"] == 3
    @test config_bug_metadata(weight_three)["max_fault_weight"] == 3
    history = paper_subject_config_by_name("history_challenge_n100_r4_missing_reset_bug_r2_q75")
    @test config_bug_metadata(history)["rounds"] == 4
    @test config_bug_metadata(history)["history_states"] == 401
    @test_throws ErrorException paper_subject_config_by_name("not_a_subject")
    @test_throws ErrorException supported_subject_modes(:surface_code)
end
