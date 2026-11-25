"""
    ConcolicSubjectSpec(name, fault_vars, runner; metadata=Dict{String,Any}())

Lightweight subject wrapper for paper/AE runners. `runner` is any callable that
accepts an input assignment and returns a `ConcolicTrace`.
"""
struct ConcolicSubjectSpec{Runner}
    name::String
    fault_vars::Vector{Symbol}
    runner::Runner
    metadata::Dict{String,Any}
end

function normalize_subject_metadata(metadata::AbstractDict)
    return Dict{String,Any}(string(key) => value for (key, value) in metadata)
end

function ConcolicSubjectSpec(name::AbstractString, fault_vars, runner;
    metadata=Dict{String,Any}())

    return ConcolicSubjectSpec(
        String(name),
        normalize_fault_vars(fault_vars),
        runner,
        normalize_subject_metadata(metadata),
    )
end

subject_name(subject) =
    error("subject_name is not implemented for $(typeof(subject))")

subject_fault_vars(subject) =
    error("subject_fault_vars is not implemented for $(typeof(subject))")

run_subject(subject, input) =
    error("run_subject is not implemented for $(typeof(subject))")

subject_metadata(subject) = Dict{String,Any}()

subject_name(subject::ConcolicSubjectSpec) = subject.name

subject_fault_vars(subject::ConcolicSubjectSpec) = copy(subject.fault_vars)

subject_metadata(subject::ConcolicSubjectSpec) = copy(subject.metadata)

run_subject(subject::ConcolicSubjectSpec, input) = subject.runner(input)

subject_name(subject::BitFlipSubject) = subject.name

subject_fault_vars(subject::BitFlipSubject) = bitflip_fault_vars(subject)

function subject_metadata(subject::BitFlipSubject)
    return Dict{String,Any}(
        "subject_family" => "three_qubit_bitflip",
        "mode" => string(subject.mode),
        "fault_model" => subject.mode == :priority_decoder_bug ?
            "single Pauli-X data fault plus neutral priority decoy guards" :
            "single Pauli-X data fault",
        "max_fault_weight" => 1,
    )
end

run_subject(subject::BitFlipSubject, input::AbstractDict) =
    run_bitflip_subject(subject, input)

subject_name(subject::PhaseFlipSubject) = subject.name

subject_fault_vars(::PhaseFlipSubject) = phaseflip_fault_vars()

function subject_metadata(subject::PhaseFlipSubject)
    return Dict{String,Any}(
        "subject_family" => "three_qubit_phaseflip",
        "mode" => string(subject.mode),
        "fault_model" => "single Pauli-Z data fault",
        "max_fault_weight" => 1,
        "css_orientation" => "X-check repetition syndrome for Z data faults",
    )
end

run_subject(subject::PhaseFlipSubject, input::AbstractDict) =
    run_phaseflip_subject(subject, input)

subject_name(subject::SteaneSubject) = subject.name

subject_fault_vars(::SteaneSubject) = steane_fault_vars()

function subject_metadata(subject::SteaneSubject)
    return Dict{String,Any}(
        "subject_family" => "steane_css_code",
        "mode" => string(subject.mode),
        "code" => "[[7,1,3]] Steane CSS code",
        "fault_model" => "single Pauli-X/Y/Z data fault",
        "max_fault_weight" => 1,
        "css_orientation" =>
            "six CSS checks: Z checks decode X faults; X checks decode Z faults",
    )
end

run_subject(subject::SteaneSubject, input::AbstractDict) =
    run_steane_subject(subject, input)

subject_name(subject::SurfaceSubject) = subject.name

subject_fault_vars(::SurfaceSubject) = surface_fault_vars()

function subject_metadata(subject::SurfaceSubject)
    return Dict{String,Any}(
        "subject_family" => "surface_code_kernel",
        "mode" => string(subject.mode),
        "code" => "distance-3 surface-code CSS patch kernel",
        "fault_model" => "single Pauli-X/Y/Z data fault",
        "max_fault_weight" => 1,
    )
end

run_subject(subject::SurfaceSubject, input::AbstractDict) =
    run_surface_subject(subject, input)

subject_name(subject::RepetitionSubject) = subject.name

subject_fault_vars(subject::RepetitionSubject) = repetition_fault_vars(subject.distance)

function subject_metadata(subject::RepetitionSubject)
    return Dict{String,Any}(
        "subject_family" => "repetition_code",
        "mode" => string(subject.mode),
        "distance" => subject.distance,
        "fault_model" => "single Pauli-X data fault",
        "max_fault_weight" => 1,
    )
end

run_subject(subject::RepetitionSubject, input::AbstractDict) =
    run_repetition_subject(subject, input)

subject_name(subject::LargeRepetitionSubject) = subject.name

subject_fault_vars(subject::LargeRepetitionSubject) =
    large_repetition_fault_vars(subject)

function subject_metadata(subject::LargeRepetitionSubject)
    return Dict{String,Any}(
        "subject_family" => "large_repetition_code",
        "mode" => string(subject.mode),
        "qubits" => subject.qubits,
        "syndrome_bits" => subject.qubits - 1,
        "fault_model" => "single Pauli-X data fault over n data qubits",
        "max_fault_weight" => 1,
        "scalability_profile" => "large_100_to_1000_qubits",
    )
end

run_subject(subject::LargeRepetitionSubject, input::AbstractDict) =
    run_large_repetition_subject(subject, input)

subject_name(subject::RoundRepetitionSubject) = subject.name

subject_fault_vars(subject::RoundRepetitionSubject) =
    round_repetition_fault_vars(subject)

function subject_metadata(subject::RoundRepetitionSubject)
    return Dict{String,Any}(
        "subject_family" => "round_repetition_code",
        "mode" => string(subject.mode),
        "distance" => subject.distance,
        "rounds" => subject.rounds,
        "fault_model" => "single Pauli-X data fault over all round/qubit locations",
        "max_fault_weight" => 1,
        "fault_locations" =>
            round_repetition_fault_metadata(subject.distance, subject.rounds),
    )
end

run_subject(subject::RoundRepetitionSubject, input::AbstractDict) =
    run_round_repetition_subject(subject, input)

subject_name(subject::LargeDecoderTableSubject) = subject.name

subject_fault_vars(subject::LargeDecoderTableSubject) =
    large_decoder_table_fault_vars(subject)

function subject_metadata(subject::LargeDecoderTableSubject)
    return merge(
        Dict{String,Any}(
            "mode" => "sparse_decoder_table_bug",
            "bug_arm" => subject.bug_arm,
            "wrong_arm" => subject.wrong_arm,
            "neutral_decoy_faults" => subject.decoys,
            "fault_model" => "single decoder-arm or neutral decoy fault location",
        ),
        large_decoder_table_characterization(subject),
    )
end

run_subject(subject::LargeDecoderTableSubject, input::AbstractDict) =
    run_large_decoder_table_subject(subject, input)

subject_name(subject::WeightTwoSubject) = subject.name

subject_fault_vars(subject::WeightTwoSubject) =
    weight_two_fault_vars(subject)

subject_metadata(subject::WeightTwoSubject) =
    weight_two_subject_metadata(subject)

run_subject(subject::WeightTwoSubject, input::AbstractDict) =
    run_weight_two_subject(subject, input)

subject_name(subject::WeightThreeSubject) = subject.name

subject_fault_vars(subject::WeightThreeSubject) =
    weight_three_fault_vars(subject)

subject_metadata(subject::WeightThreeSubject) =
    weight_three_subject_metadata(subject)

run_subject(subject::WeightThreeSubject, input::AbstractDict) =
    run_weight_three_subject(subject, input)

subject_name(subject::HistoryChallengeSubject) = subject.name

subject_fault_vars(subject::HistoryChallengeSubject) =
    history_challenge_fault_vars(subject)

subject_metadata(subject::HistoryChallengeSubject) =
    history_challenge_metadata(subject)

run_subject(subject::HistoryChallengeSubject, input::AbstractDict) =
    run_history_challenge_subject(subject, input)

subject_name(subject::DemParitySubject) = subject.name

subject_fault_vars(subject::DemParitySubject) =
    dem_fault_vars(subject.model)

subject_metadata(subject::DemParitySubject) =
    dem_subject_metadata(subject)

run_subject(subject::DemParitySubject, input::AbstractDict) =
    run_dem_parity_subject(subject, input)

function run_concolic_subject(subject; kwargs...)
    return run_concolic(
        input -> run_subject(subject, input),
        subject_fault_vars(subject);
        kwargs...,
    )
end
