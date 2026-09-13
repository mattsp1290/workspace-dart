part of workspace_flutter;

/// Publicly queryable lifecycle metadata. It never contains a native grant.
final class WorkspaceGrantMetadata {
  const WorkspaceGrantMetadata(
      {required this.id, required this.state, required this.schemaVersion});
  final WorkspaceId id;
  final WorkspaceGrantState state;
  final int schemaVersion;
}

enum WorkspaceGrantState { pending, active, deleting }

/// Trusted host-private storage for opaque envelopes. Its envelope methods are
/// only for the plugin manager's restore path—not for models, logs, or UI.
abstract interface class WorkspaceGrantVault {
  Future<void> reservePending(
      {required WorkspaceId id, required int schemaVersion});
  Future<void> storeNativeEnvelope(WorkspaceId id, Uint8List nativeEnvelope);
  Future<void> activate(WorkspaceId id);
  Future<void> markDeleting(WorkspaceId id);
  Future<void> delete(WorkspaceId id);
  Future<Uint8List?> loadNativeEnvelope(WorkspaceId id);
  Future<WorkspaceGrantMetadata?> loadMetadata(WorkspaceId id);
  Future<List<WorkspaceGrantMetadata>> listMetadata();
}

/// Picker result whose envelope can only be copied by the trusted manager.
final class WorkspaceSelection {
  WorkspaceSelection(Uint8List nativeEnvelope)
      : _nativeEnvelope = Uint8List.fromList(nativeEnvelope);
  final Uint8List _nativeEnvelope;

  /// Only the trusted grant manager may copy this into its host vault.
  Uint8List _takeNativeEnvelope() => Uint8List.fromList(_nativeEnvelope);
}

/// Native authority bridge. No parameter is an absolute filesystem path.
abstract interface class WorkspacePlatformBridge {
  Future<WorkspaceOutcome<WorkspaceSelection>> selectDirectory(WorkspaceId id);
  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(
      WorkspaceId id, Uint8List nativeEnvelope);
  Future<WorkspaceOutcome<WorkspacePage>> list(
      WorkspaceListRequest request, Uint8List nativeEnvelope);
  Future<WorkspaceOutcome<WorkspaceRead>> read(
      WorkspaceReadRequest request, Uint8List nativeEnvelope);
  Future<void> cancelWorkspace(WorkspaceId id);
  Future<void> commitSelection(WorkspaceId id);
  Future<void> abandonSelection(WorkspaceId id);
  Future<void> forgetWorkspace(WorkspaceId id);
  Future<void> reconcileAcquisitions(List<WorkspaceId> activeIds);
}

/// Owns crash-safe grant transitions; each successful selection creates a new ID.
final class WorkspaceGrantManager {
  WorkspaceGrantManager(
      {required WorkspaceGrantVault vault, WorkspacePlatformBridge? bridge})
      : _vault = vault,
        _bridge = bridge ?? MethodChannelWorkspaceBridge();
  final WorkspaceGrantVault _vault;
  final WorkspacePlatformBridge _bridge;
  Future<void>? _reconciliation;

  Future<WorkspaceOutcome<WorkspaceId>> selectDirectory() async {
    final id = WorkspaceId(_newId());
    try {
      await _ensureReconciled();
      await _vault.reservePending(id: id, schemaVersion: 1);
      final selection = await _bridge.selectDirectory(id);
      if (selection is! WorkspaceSuccess<WorkspaceSelection>) {
        await _discardSelection(id);
        return _castFailure(selection);
      }
      await _vault.storeNativeEnvelope(
          id, selection.value._takeNativeEnvelope());
      await _vault.activate(id);
      await _bridge.commitSelection(id);
      return WorkspaceSuccess(id);
    } catch (_) {
      await _discardSelection(id);
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure,
          message: 'The directory grant could not be stored.');
    }
  }

  Future<WorkspaceOutcome<FlutterWorkspaceAccess>> restore(
      WorkspaceId id) async {
    try {
      await _ensureReconciled();
    } catch (_) {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure,
          message: 'Workspace grants could not be reconciled.');
    }
    final metadata = await _vault.loadMetadata(id);
    if (metadata == null || metadata.state != WorkspaceGrantState.active)
      return const WorkspaceFailure(WorkspaceFailureKind.notFound);
    final envelope = await _vault.loadNativeEnvelope(id);
    if (envelope == null)
      return const WorkspaceFailure(WorkspaceFailureKind.permissionLost);
    final root = await _bridge.restore(id, envelope);
    if (root is! WorkspaceSuccess<WorkspaceDirectory>)
      return _castFailure(root);
    return WorkspaceSuccess(FlutterWorkspaceAccess._(
        id: id, root: root.value, vault: _vault, bridge: _bridge));
  }

  Future<WorkspaceOutcome<void>> forget(WorkspaceId id) async {
    try {
      await _ensureReconciled();
      await _vault.markDeleting(id);
      await _bridge.forgetWorkspace(id);
      await _vault.delete(id);
      return const WorkspaceSuccess(null);
    } catch (_) {
      _reconciliation = null;
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure,
          message: 'The workspace record could not be removed.');
    }
  }

  Future<List<WorkspaceGrantMetadata>> listKnownWorkspaces() async {
    await _ensureReconciled();
    return (await _vault.listMetadata())
        .where((record) => record.state == WorkspaceGrantState.active)
        .toList(growable: false);
  }

  Future<void> _ensureReconciled() {
    return _reconciliation ??= _reconcile().catchError((Object error) {
      _reconciliation = null;
      throw error;
    });
  }

  Future<void> _reconcile() async {
    final records = await _vault.listMetadata();
    final active = records
        .where((record) => record.state == WorkspaceGrantState.active)
        .map((record) => record.id)
        .toList(growable: false);
    await _bridge.reconcileAcquisitions(active);
    for (final record in records) {
      if (record.state != WorkspaceGrantState.active) {
        await _vault.delete(record.id);
      }
    }
  }

  Future<void> _discardSelection(WorkspaceId id) async {
    try {
      await _bridge.abandonSelection(id);
    } catch (_) {}
    try {
      await _bridge.forgetWorkspace(id);
    } catch (_) {}
    try {
      await _vault.delete(id);
    } catch (_) {}
  }

  String _newId() => List<String>.generate(
      32, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
}

/// Root-bound adapter that obtains an opaque envelope only through its vault.
final class FlutterWorkspaceAccess implements WorkspaceAdapter {
  FlutterWorkspaceAccess._(
      {required this.id,
      required this.root,
      required WorkspaceGrantVault vault,
      required WorkspacePlatformBridge bridge})
      : _vault = vault,
        _bridge = bridge;
  final WorkspaceId id;
  final WorkspaceDirectory root;
  final WorkspaceGrantVault _vault;
  final WorkspacePlatformBridge _bridge;
  bool _closed = false;
  Future<void>? _closeFuture;
  Future<Uint8List?> _envelope() => _vault.loadNativeEnvelope(id);
  @override
  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(
      WorkspaceId workspaceId) async {
    if (_closed) return const WorkspaceFailure(WorkspaceFailureKind.closed);
    if (workspaceId != id) {
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    }
    final envelope = await _envelope();
    if (envelope == null)
      return const WorkspaceFailure(WorkspaceFailureKind.permissionLost);
    return _bridge.restore(id, envelope);
  }

  @override
  Future<WorkspaceOutcome<WorkspacePage>> list(
      WorkspaceListRequest request) async {
    if (_closed) return const WorkspaceFailure(WorkspaceFailureKind.closed);
    if (request.workspaceId != id) {
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    }
    final envelope = await _envelope();
    if (envelope == null)
      return const WorkspaceFailure(WorkspaceFailureKind.permissionLost);
    return _bridge.list(request, envelope);
  }

  @override
  Future<WorkspaceOutcome<WorkspaceRead>> read(
      WorkspaceReadRequest request) async {
    if (_closed) return const WorkspaceFailure(WorkspaceFailureKind.closed);
    if (request.workspaceId != id) {
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    }
    final envelope = await _envelope();
    if (envelope == null)
      return const WorkspaceFailure(WorkspaceFailureKind.permissionLost);
    return _bridge.read(request, envelope);
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    await _bridge.cancelWorkspace(id);
  }
}

WorkspaceFailure<T> _castFailure<T, S>(WorkspaceOutcome<S> result) =>
    result is WorkspaceFailure<S>
        ? WorkspaceFailure<T>(result.kind, message: result.message)
        : const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
