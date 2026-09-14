# Support matrix

| Adapter | Status | Notes |
| --- | --- | --- |
| Deterministic memory | Automated tests pass | Dart 3.13.1; list/read, budgets, opaque references, revision evidence, cancellation, and cursor tests. |
| iOS security-scoped directories | Implementation builds; simulator and synthetic local/iCloud physical restore-read evidence exists | CocoaPods and Flutter SwiftPM consume one production Swift source tree. Detailed automated/physical evidence and deferred qualification gates: [feasibility record](feasibility.md#automated-evidence). |
| Android SAF trees (API 29+) | Implementation builds; emulator, instrumentation, and synthetic physical restore-read evidence exists | Supported from API 29. Detailed automated/physical evidence and deferred qualification gates: [feasibility record](feasibility.md#automated-evidence). |

Both native adapters cap one operation at 1,000 entries and 8 MiB and return
`unverified` when provider coherence cannot be proved. See the
[feasibility record](feasibility.md#physical-evidence-and-remaining-gaps) for
the canonical release-gate status, including cloud-provider, revocation,
process-death, mutation, and resource-balance qualification.
