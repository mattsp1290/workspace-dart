/// Flutter integration is intentionally unavailable until native feasibility
/// and device-process-death requirements are demonstrated.
library;

import 'package:workspace/workspace.dart';

/// Trusted host-private storage boundary for opaque native grant envelopes.
/// Implementations must not expose or log [WorkspaceGrantRecord.envelope].
abstract interface class WorkspaceGrantVault {
  Future<void> reservePending(WorkspaceGrantRecord record);
  Future<void> activate(WorkspaceId id);
  Future<WorkspaceGrantRecord?> load(WorkspaceId id);
  Future<List<WorkspaceGrantRecord>> listRecords();
  Future<void> markDeleting(WorkspaceId id);
  Future<void> delete(WorkspaceId id);
}

enum WorkspaceGrantState { pending, active, deleting }

final class WorkspaceGrantRecord {
  const WorkspaceGrantRecord(
      {required this.id,
      required this.envelope,
      required this.state,
      required this.schemaVersion});
  final WorkspaceId id;
  final List<int> envelope;
  final WorkspaceGrantState state;
  final int schemaVersion;
  @override
  String toString() => 'WorkspaceGrantRecord(${id.value}, $state, <redacted>)';
}

/// This package is a deliberate fail-closed placeholder, not a path adapter.
/// Native selection, restoration, and I/O are unavailable pending platform
/// feasibility evidence on the mandated physical devices.
final class WorkspaceGrantManager {
  const WorkspaceGrantManager();
  Future<WorkspaceOutcome<WorkspaceId>> selectDirectory() async =>
      const WorkspaceFailure(WorkspaceFailureKind.unsupported,
          message: 'Native workspace selection is not implemented.');
}
