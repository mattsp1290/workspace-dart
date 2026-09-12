/// Flutter support for trusted, read-only mobile workspace grants.
library;

import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:workspace/workspace.dart';

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
      {required WorkspaceId id,
      required Uint8List nativeEnvelope,
      required int schemaVersion});
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
  Uint8List takeNativeEnvelope() => Uint8List.fromList(_nativeEnvelope);
}

/// Native authority bridge. No parameter is an absolute filesystem path.
abstract interface class WorkspacePlatformBridge {
  Future<WorkspaceOutcome<WorkspaceSelection>> selectDirectory();
  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(
      WorkspaceId id, Uint8List nativeEnvelope);
  Future<WorkspaceOutcome<WorkspacePage>> list(
      WorkspaceListRequest request, Uint8List nativeEnvelope);
  Future<WorkspaceOutcome<WorkspaceRead>> read(
      WorkspaceReadRequest request, Uint8List nativeEnvelope);
  Future<void> cancelAll();
}

/// Owns crash-safe grant transitions; each successful selection creates a new ID.
final class WorkspaceGrantManager {
  WorkspaceGrantManager(
      {required WorkspaceGrantVault vault, WorkspacePlatformBridge? bridge})
      : _vault = vault,
        _bridge = bridge ?? MethodChannelWorkspaceBridge();
  final WorkspaceGrantVault _vault;
  final WorkspacePlatformBridge _bridge;

  Future<WorkspaceOutcome<WorkspaceId>> selectDirectory() async {
    final selection = await _bridge.selectDirectory();
    if (selection is! WorkspaceSuccess<WorkspaceSelection>)
      return _castFailure(selection);
    final id = WorkspaceId(_newId());
    try {
      await _vault.reservePending(
          id: id,
          nativeEnvelope: selection.value.takeNativeEnvelope(),
          schemaVersion: 1);
      await _vault.activate(id);
      return WorkspaceSuccess(id);
    } catch (_) {
      try {
        await _vault.delete(id);
      } catch (_) {}
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure,
          message: 'The directory grant could not be stored.');
    }
  }

  Future<WorkspaceOutcome<FlutterWorkspaceAccess>> restore(
      WorkspaceId id) async {
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
      await _vault.markDeleting(id);
      await _vault.delete(id);
      return const WorkspaceSuccess(null);
    } catch (_) {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure,
          message: 'The workspace record could not be removed.');
    }
  }

  Future<List<WorkspaceGrantMetadata>> listKnownWorkspaces() async =>
      (await _vault.listMetadata())
          .where((record) => record.state == WorkspaceGrantState.active)
          .toList(growable: false);
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
  Future<Uint8List?> _envelope(WorkspaceId requested) async =>
      _closed || requested != id ? null : _vault.loadNativeEnvelope(id);
  @override
  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(
      WorkspaceId workspaceId) async {
    final envelope = await _envelope(workspaceId);
    if (envelope == null)
      return const WorkspaceFailure(WorkspaceFailureKind.permissionLost);
    return _bridge.restore(id, envelope);
  }

  @override
  Future<WorkspaceOutcome<WorkspacePage>> list(
      WorkspaceListRequest request) async {
    final envelope = await _envelope(request.workspaceId);
    if (envelope == null)
      return const WorkspaceFailure(WorkspaceFailureKind.permissionLost);
    return _bridge.list(request, envelope);
  }

  @override
  Future<WorkspaceOutcome<WorkspaceRead>> read(
      WorkspaceReadRequest request) async {
    final envelope = await _envelope(request.workspaceId);
    if (envelope == null)
      return const WorkspaceFailure(WorkspaceFailureKind.permissionLost);
    return _bridge.read(request, envelope);
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      await _bridge.cancelAll();
    }
  }
}

/// Typed method-channel bridge. Native code owns grant resolution and I/O.
final class MethodChannelWorkspaceBridge implements WorkspacePlatformBridge {
  MethodChannelWorkspaceBridge({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('workspace_flutter/read_only');
  final MethodChannel _channel;
  @override
  Future<WorkspaceOutcome<WorkspaceSelection>> selectDirectory() async {
    try {
      final envelope =
          await _channel.invokeMethod<Uint8List>('selectDirectory');
      return envelope == null
          ? const WorkspaceEmpty()
          : WorkspaceSuccess(WorkspaceSelection(envelope));
    } on PlatformException catch (error) {
      return WorkspaceFailure(_failureKind(error.code));
    }
  }

  @override
  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(
      WorkspaceId id, Uint8List nativeEnvelope) async {
    final response = await _call(
        'restore', {'workspaceId': id.value, 'envelope': nativeEnvelope});
    if (response is WorkspaceFailure<Map<Object?, Object?>>)
      return WorkspaceFailure(response.kind, message: response.message);
    return _directory(
        id, (response as WorkspaceSuccess<Map<Object?, Object?>>).value);
  }

  @override
  Future<WorkspaceOutcome<WorkspacePage>> list(
      WorkspaceListRequest request, Uint8List nativeEnvelope) async {
    if (!request.budget.isValid)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidRequest);
    final response = await _call('list', {
      'workspaceId': request.workspaceId.value,
      'envelope': nativeEnvelope,
      'directoryToken': request.directory.token,
      'maxEntries': request.budget.maxEntries,
      'maxBytes': request.budget.maxBytes,
      'cursor': request.cursor?.token
    });
    if (response is WorkspaceFailure<Map<Object?, Object?>>)
      return WorkspaceFailure(response.kind, message: response.message);
    try {
      final value = (response as WorkspaceSuccess<Map<Object?, Object?>>).value;
      final rawEntries =
          value['entries'] as List<Object?>? ?? const <Object?>[];
      final entries = rawEntries
          .map((entry) => _entry(
              request.workspaceId, Map<Object?, Object?>.from(entry! as Map)))
          .toList();
      final completion = switch (value['completion']) {
        'hasMore' => ListCompletion.hasMore,
        'budgetExhausted' => ListCompletion.budgetExhausted,
        _ => ListCompletion.complete
      };
      final consistency = switch (value['consistency']) {
        'verified' => ListConsistency.verified,
        'changed' => ListConsistency.changed,
        _ => ListConsistency.unverified
      };
      final cursor = value['cursor'] as String?;
      return WorkspaceSuccess(WorkspacePage(
          entries: entries,
          completion: completion,
          consistency: consistency,
          usage: BudgetUsage(
              entries: value['usedEntries'] as int? ?? entries.length,
              bytes: value['usedBytes'] as int? ?? 0),
          cursor: cursor == null
              ? null
              : WorkspacePageCursor(
                  workspaceId: request.workspaceId, token: cursor)));
    } on FormatException {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    }
  }

  @override
  Future<WorkspaceOutcome<WorkspaceRead>> read(
      WorkspaceReadRequest request, Uint8List nativeEnvelope) async {
    if (!request.budget.isValid || !request.range.isValid)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidRequest);
    final response = await _call('read', {
      'workspaceId': request.workspaceId.value,
      'envelope': nativeEnvelope,
      'fileToken': request.file.token,
      'offset': request.range.offset,
      'count': request.range.count,
      'maxBytes': request.budget.maxBytes,
      'expectedRevision': request.expectedRevision?.value
    });
    if (response is WorkspaceFailure<Map<Object?, Object?>>)
      return WorkspaceFailure(response.kind, message: response.message);
    final value = (response as WorkspaceSuccess<Map<Object?, Object?>>).value;
    final bytes = value['bytes'] as Uint8List?;
    if (bytes == null)
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    final stability = switch (value['stability']) {
      'verified' => RevisionStability.verified,
      'changed' => RevisionStability.changed,
      _ => RevisionStability.unverified
    };
    return WorkspaceSuccess(WorkspaceRead(
        bytes: bytes,
        offset: value['offset'] as int? ?? request.range.offset,
        eof: value['eof'] as bool? ?? false,
        actualRevision: ContentRevision(
            value['actualRevision'] as String? ?? 'native-unverified'),
        expectedRevision: request.expectedRevision,
        stability: stability,
        usage: BudgetUsage(bytes: bytes.length)));
  }

  @override
  Future<void> cancelAll() => _channel.invokeMethod<void>('cancelAll');

  Future<WorkspaceOutcome<Map<Object?, Object?>>> _call(
      String method, Map<String, Object?> arguments) async {
    try {
      final response =
          await _channel.invokeMapMethod<Object?, Object?>(method, arguments);
      return WorkspaceSuccess(
          Map<Object?, Object?>.from(response ?? const <Object?, Object?>{}));
    } on PlatformException catch (error) {
      return WorkspaceFailure(_failureKind(error.code));
    }
  }

  WorkspaceOutcome<WorkspaceDirectory> _directory(
      WorkspaceId id, Map<Object?, Object?> map) {
    try {
      return WorkspaceSuccess(WorkspaceDirectory(
          ref: WorkspaceEntryRef(
              workspaceId: id, token: map['token']! as String),
          displayPath: WorkspaceDisplayPath(map['name']! as String),
          name: map['name']! as String));
    } on FormatException {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    }
  }

  WorkspaceEntry _entry(WorkspaceId id, Map<Object?, Object?> map) {
    final ref =
        WorkspaceEntryRef(workspaceId: id, token: map['token']! as String);
    final name = map['name']! as String;
    final display = WorkspaceDisplayPath(name);
    return map['type'] == 'directory'
        ? WorkspaceDirectory(ref: ref, displayPath: display, name: name)
        : WorkspaceFile(
            ref: ref,
            displayPath: display,
            name: name,
            byteLength: map['byteLength'] as int? ?? 0);
  }
}

WorkspaceFailure<T> _castFailure<T, S>(WorkspaceOutcome<S> result) =>
    result is WorkspaceFailure<S>
        ? WorkspaceFailure<T>(result.kind, message: result.message)
        : const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
WorkspaceFailureKind _failureKind(String code) => switch (code) {
      'cancelled' => WorkspaceFailureKind.cancelled,
      'permissionLost' => WorkspaceFailureKind.permissionLost,
      'unavailable' => WorkspaceFailureKind.unavailable,
      'notFound' => WorkspaceFailureKind.notFound,
      'unsupported' => WorkspaceFailureKind.unsupported,
      _ => WorkspaceFailureKind.providerFailure,
    };
