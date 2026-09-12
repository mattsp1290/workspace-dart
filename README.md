# workspace-dart
# workspace-dart

Read-only, capability-bounded workspace access for Dart. The repository now
contains the pure-Dart `workspace` package and a deterministic memory adapter
for contract testing. It deliberately does not expose path-based access or any
write operation.

Mobile iOS/Android grants and Flutter integration are not yet implemented:
they require the physical-device feasibility gates in the accompanying plan.
See [the consumer guide](docs/consumer-guide.md) and [support matrix](docs/support-matrix.md).
