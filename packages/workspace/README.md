# workspace

`workspace` defines a pure-Dart contract for bounded, read-only access to a
user-selected directory. Entry references are opaque and bound to their
workspace, reads are byte-limited, pagination cursors are single-use, and
failures are represented by typed outcomes.

The package also includes a deterministic in-memory adapter for tests. Native
iOS and Android adapters live in the sibling `workspace_flutter` package.

See the [repository documentation](https://github.com/mattsp1290/workspace-dart)
for the consumer guide, security boundary, and current platform evidence.
