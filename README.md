# HWDIAG.R4X

`HWDIAG.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.1.6`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/HWDIAG.R4X`
- Image scope: `test`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

API migration 0.90.82
--------------------
The normal App2/Query2 consumer captures one complete copied device inventory. Every filtered section and the full record list use that same snapshot; an incomplete or changed-capacity result fails instead of hiding missing rows. MIN/STD/FULL/EXPORT keep their existing format and priority. The bounded report uses64KB of heap storage (16KB overflowed the original FULL report in the ordinary KVM guest). EXPORT retains C:\HWDIAG.TXT and verifies full metadata2/stream contents byte for byte.

Local source, artifact and runtime evidence: Research/API-ABI/Migration/0.90.82/
in the coordinating workspace. Physical hardware and Windows are separate qualifications.
