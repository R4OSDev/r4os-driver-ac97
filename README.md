# AC97.R4D

`AC97.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.1.5`
- Image target: `/R4OS/DRIVERS/AC97.R4D`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

The driver publishes source writes atomically into a bounded eight-buffer
queue backed by the controller's 32-entry descriptor ring. Busy is reported
before conversion when that queue lacks space, so retries neither reset nor
duplicate retained resampler progress. CIV/CELV refresh the current queue
fill; normal LVBCI and DCH completion states are not reported as underruns.
PCM-out interrupts use MSI when available and routed INTx otherwise. Status
and recovery run as one bounded DriverApi-v20 audio pass with a 10 ms absolute
deadline, stable AC97 key, and at most one successor. Shutdown releases the
stream lock before joining every completion and freeing DMA.

Detailed German technical notes are in `DOCUMENTATION.de.txt`.
Source-transfer provenance is recorded in `PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
