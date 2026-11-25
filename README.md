# ConQEC

ConQEC uses concolic testing to find and localize faults in implementations of
quantum error-correcting codes. The Julia implementation generates Pauli-fault
inputs, traces the syndrome, decoder decision and recovery, and checks fault
witnesses by concrete replay. The companion paper is
[ConQEC: Concolic Testing for Quantum Error-Correcting Code Implementations](https://arxiv.org/abs/2610.31443v1).

## Quick start

Install Julia and Z3 and put both executables on your `PATH`. The commands below
were prepared for Julia 1.12.6 and Z3 4.12.4. The Julia code uses standard
libraries. Run the commands from the repository root.

```sh
julia --startup-file=no --project=. scripts/run_conqec_smoke_tests.jl \
  --backend z3 --solver-path z3 --witness-dir generated/smoke
julia --startup-file=no --project=. scripts/run_conqec_ae_suite.jl \
  --quick --backend z3 --solver-path z3 --witness-dir generated/ae-quick
```

The first command checks a clean control and detects four expected bugs. It
writes four witness JSON files. The second command exercises 18 subjects.
Run the software test suite with `julia --startup-file=no --project=. test/runtests.jl`.
See `example/` for standalone examples. Run
`julia --project=. scripts/replay_conqec_witness.jl --help` for replay options.

## ICSE 2027 Artifact Evaluation

See the [artifact guide](ae/README.md) for the fixed AE release and archival
record. The software in this repository is suitable for short, local runs.
The full experimental records, paper table and figure commands, and corrected
formal RQ1 experiment are provided by the AE archive. The Zenodo version DOI
has been reserved and public release is pending.

## Development

The `main` branch carries development. The `v0.0-icse27-ae` tag identifies
the fixed Julia software revision for ICSE 2027 Artifact Evaluation.

See [Licensing](RIGHTS.md) for the software and documentation terms.
