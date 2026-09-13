# workspace-dart

Read-only, capability-bounded workspace access for Dart. The repository now
contains the pure-Dart `workspace` package, a deterministic memory adapter, and
the `workspace_flutter` plugin for iOS security-scoped directories and Android
Storage Access Framework trees. It deliberately exposes neither path-based
authority nor write operations.

The native adapters compile on the repository's current Flutter toolchain, and
the registered Kotlin handler passes an on-device smoke test. Full picker,
process-death, provider, revocation, and cancellation evidence is still a
release gate. See [the consumer guide](docs/consumer-guide.md),
[security boundary](docs/security.md), and [support matrix](docs/support-matrix.md).
