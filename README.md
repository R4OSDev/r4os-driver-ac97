# AC97.R4D

`AC97.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.1.12`
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
PCM-out interrupts use MSI when available. INTx requires a valid PCI interrupt
pin and an explicitly supplied board route: `OPTION AC97 intx-gsi=N`, with
one or two decimal digits in the range 0..31. The raw PCI Line is a legacy PIC
assignment and does not establish an APIC GSI. Missing/invalid configuration
or a failed registration refuses admission with an error; no neighboring
GSIs are guessed. MSI does not require this option. If MSI registration fails,
MSI disable must succeed before an INTx fallback is attempted. There is no
automatic ACPI `_PRT` resolver in the current DriverApi.

Supply `N` from the actual board/firmware routing contract. For the qualified
Q35 arrangement with AC97 at 00:03.0, pin A, the observed route is GSI 23;
this is an example for that topology, not a general R4OS/AC97 default. The
driver owns one successful route and retains failed unregister/disable
acknowledgements for retry before resource release. Status
and recovery run as one bounded DriverApi-v20 audio pass with a 10 ms absolute
deadline, stable AC97 key, and at most one successor. Shutdown releases the
stream lock before joining every completion and freeing DMA.

Normal Idle/last-stream Close uses the existing version4/104-byte idle
descriptor and one resident normal Work continuation. It returns Busy while
caller PCM drains, hardware DCH is missing or actual status/continuation Work
has not completed and released. The original2000ms drain budget begins before
submission; confirmed quiet reset starts the original100ms status retirement
budget. Each bounded turn releases the stream owner before returning the
existing continuation wait result. No audio deadline job or caller pointer
is retained across turns. Physical Stop/shutdown keep their own hardware
quiescence and Work joins; a join holds neither stream owner nor reaper gate.

Output id/name remain `AC97`. Accepted new PCM cancels an earlier intention;
invalid/Busy writes cannot cancel it or reuse its completion. Exact output,
reset and PCI identity plus the actual terminal ticket guard success. Status
admission closes before retirement and waits for in-flight submitters. A
cancelled queued status job also releases its Pending bookkeeping only after
the real tickets retire. Genuine reset, deadline and release errors remain
failures with retained resource truth. The existing continuation API is
required; no Kernel, SDK or public Query-table change is needed.

The existing owner step passes27 cases: seven original queue/Work cases,
six drain-state cases, six actual descriptor/Idle/Work/write callback cases
and eight actual IRQ registration/teardown/shared-W1C cases. The original
AC979 source fails five targeted route cases; the explicit-route source passes.
An actual KVM4 comparison uses the identical retained8032-byte Close/master
fixture: the independent master request returns while final Close is pending,
then Close and its IO/connection retirement succeed. Original BEEP and AUDIOD
PCM/master/restart/four-cycle lifecycle plus a client exiting without Close
and actual AUDSVC session reaping pass. No physical hearing or isolated
throughput/latency result is inferred. Details: `Docs/Audio/README.txt`.

Detailed German technical notes are in `DOCUMENTATION.de.txt`.
Source-transfer provenance is recorded in `PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
# Coherent output catalog (0.88.55)

The existing idle backend binds `AudioOutputEpochFn` through DriverApi39.
One immutable connector uses generation1 for this exact Core registration;
shutdown returns Busy and never reasserts availability. A later registration
has a new Core identity. The explicit board INTx option, IRQ/refill/idle paths
and original audio progress/drain oracles are unchanged.

R4OS0.88.59 removes only the unused write/refill duration bookkeeping.
The fixed128-byte AudioBackendStatus duration slots now return the explicit
Contract0.64.61 audio_duration_ticks_unavailable sentinel (UINT64_MAX).
Functional clocks/deadlines, PCM admission, DMA/IRQ progress, errors and
actual terminal Close remain in place. Never treat the sentinel as latency.
