import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:workspace/workspace.dart';
import 'package:workspace_flutter/workspace_flutter.dart';

void main() {
  test('selection writes pending state before native acquisition', () async {
    final events = <String>[];
    final vault = _Vault(events);
    final bridge = _Bridge(events);
    final manager = WorkspaceGrantManager(vault: vault, bridge: bridge);

    final outcome = await manager.selectDirectory();

    expect(outcome, isA<WorkspaceSuccess<WorkspaceId>>());
    expect(events, <String>[
      'reconcile',
      'reserve',
      'select',
      'envelope',
      'activate',
      'commit',
    ]);
  });

  test('failed acquisition abandons native and vault pending state', () async {
    final events = <String>[];
    final vault = _Vault(events);
    final bridge = _Bridge(events)..selectionFails = true;
    final manager = WorkspaceGrantManager(vault: vault, bridge: bridge);

    final outcome = await manager.selectDirectory();

    expect(
      (outcome as WorkspaceFailure<WorkspaceId>).kind,
      WorkspaceFailureKind.cancelled,
    );
    expect(events, <String>[
      'reconcile',
      'reserve',
      'select',
      'abandon',
      'forget',
      'delete',
    ]);
  });

  test('failed native commit also releases promoted grant state', () async {
    final events = <String>[];
    final vault = _Vault(events);
    final bridge = _Bridge(events)..commitFails = true;
    final manager = WorkspaceGrantManager(vault: vault, bridge: bridge);

    final outcome = await manager.selectDirectory();

    expect(
      (outcome as WorkspaceFailure<WorkspaceId>).kind,
      WorkspaceFailureKind.providerFailure,
    );
    expect(
      events,
      containsAllInOrder(<String>[
        'activate',
        'commit',
        'abandon',
        'forget',
        'delete',
      ]),
    );
  });

  test('closed access rejects later operations as closed', () async {
    final events = <String>[];
    final vault = _Vault(events);
    final id = WorkspaceId('workspace');
    vault.metadata[id] = WorkspaceGrantMetadata(
      id: id,
      state: WorkspaceGrantState.active,
      schemaVersion: 1,
    );
    vault.envelopes[id] = Uint8List.fromList(<int>[1]);
    final manager = WorkspaceGrantManager(
      vault: vault,
      bridge: _Bridge(events),
    );

    final restored = await manager.restore(id);
    final access = (restored as WorkspaceSuccess<FlutterWorkspaceAccess>).value;
    await access.close();
    final outcome = await access.restore(id);

    expect(
      (outcome as WorkspaceFailure<WorkspaceDirectory>).kind,
      WorkspaceFailureKind.closed,
    );
  });

  test(
    'access rejects a different workspace before loading an envelope',
    () async {
      final events = <String>[];
      final vault = _Vault(events);
      final id = WorkspaceId('workspace');
      vault.metadata[id] = WorkspaceGrantMetadata(
        id: id,
        state: WorkspaceGrantState.active,
        schemaVersion: 1,
      );
      vault.envelopes[id] = Uint8List.fromList(<int>[1]);
      final access =
          (await WorkspaceGrantManager(
                    vault: vault,
                    bridge: _Bridge(events),
                  ).restore(id)
                  as WorkspaceSuccess<FlutterWorkspaceAccess>)
              .value;

      final outcome = await access.restore(WorkspaceId('other-workspace'));

      expect(
        (outcome as WorkspaceFailure<WorkspaceDirectory>).kind,
        WorkspaceFailureKind.invalidReference,
      );
    },
  );

  test('concurrent close callers share the native cleanup barrier', () async {
    final events = <String>[];
    final vault = _Vault(events);
    final id = WorkspaceId('workspace');
    vault.metadata[id] = WorkspaceGrantMetadata(
      id: id,
      state: WorkspaceGrantState.active,
      schemaVersion: 1,
    );
    vault.envelopes[id] = Uint8List.fromList(<int>[1]);
    final bridge = _Bridge(events)..closeBarrier = Completer<void>();
    final manager = WorkspaceGrantManager(vault: vault, bridge: bridge);
    final access =
        (await manager.restore(id) as WorkspaceSuccess<FlutterWorkspaceAccess>)
            .value;

    var secondCompleted = false;
    final first = access.close();
    final second = access.close().then((_) => secondCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(secondCompleted, isFalse);
    bridge.closeBarrier!.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(events.where((event) => event == 'close').length, 1);
  });
}

final class _Vault implements WorkspaceGrantVault {
  _Vault(this.events);
  final List<String> events;
  final Map<WorkspaceId, WorkspaceGrantMetadata> metadata = {};
  final Map<WorkspaceId, Uint8List> envelopes = {};

  @override
  Future<void> reservePending({
    required WorkspaceId id,
    required int schemaVersion,
  }) async {
    events.add('reserve');
    metadata[id] = WorkspaceGrantMetadata(
      id: id,
      state: WorkspaceGrantState.pending,
      schemaVersion: schemaVersion,
    );
  }

  @override
  Future<void> storeNativeEnvelope(
    WorkspaceId id,
    Uint8List nativeEnvelope,
  ) async {
    events.add('envelope');
    envelopes[id] = Uint8List.fromList(nativeEnvelope);
  }

  @override
  Future<void> activate(WorkspaceId id) async {
    events.add('activate');
    metadata[id] = WorkspaceGrantMetadata(
      id: id,
      state: WorkspaceGrantState.active,
      schemaVersion: 1,
    );
  }

  @override
  Future<void> markDeleting(WorkspaceId id) async {
    metadata[id] = WorkspaceGrantMetadata(
      id: id,
      state: WorkspaceGrantState.deleting,
      schemaVersion: 1,
    );
  }

  @override
  Future<void> delete(WorkspaceId id) async {
    events.add('delete');
    metadata.remove(id);
    envelopes.remove(id);
  }

  @override
  Future<Uint8List?> loadNativeEnvelope(WorkspaceId id) async => envelopes[id];

  @override
  Future<WorkspaceGrantMetadata?> loadMetadata(WorkspaceId id) async =>
      metadata[id];

  @override
  Future<List<WorkspaceGrantMetadata>> listMetadata() async =>
      metadata.values.toList(growable: false);
}

final class _Bridge implements WorkspacePlatformBridge {
  _Bridge(this.events);
  final List<String> events;
  bool selectionFails = false;
  bool commitFails = false;
  Completer<void>? closeBarrier;

  @override
  Future<WorkspaceOutcome<WorkspaceSelection>> selectDirectory(
    WorkspaceId id,
  ) async {
    events.add('select');
    return selectionFails
        ? const WorkspaceFailure(WorkspaceFailureKind.cancelled)
        : WorkspaceSuccess(WorkspaceSelection(Uint8List.fromList(<int>[1])));
  }

  @override
  Future<void> reconcileAcquisitions(List<WorkspaceId> activeIds) async {
    events.add('reconcile');
  }

  @override
  Future<void> commitSelection(WorkspaceId id) async {
    events.add('commit');
    if (commitFails) throw StateError('commit failed');
  }

  @override
  Future<void> abandonSelection(WorkspaceId id) async => events.add('abandon');

  @override
  Future<void> forgetWorkspace(WorkspaceId id) async => events.add('forget');

  @override
  Future<void> cancelWorkspace(WorkspaceId id) async {
    events.add('close');
    await closeBarrier?.future;
  }

  @override
  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(
    WorkspaceId id,
    Uint8List nativeEnvelope,
  ) async => WorkspaceSuccess(
    WorkspaceDirectory(
      ref: WorkspaceEntryRef.issued(workspaceId: id, stableId: 'root'),
      displayPath: WorkspaceDisplayPath('root'),
      name: 'root',
    ),
  );

  @override
  Future<WorkspaceOutcome<WorkspacePage>> list(
    WorkspaceListRequest request,
    Uint8List nativeEnvelope,
  ) async => const WorkspaceFailure(WorkspaceFailureKind.unsupported);

  @override
  Future<WorkspaceOutcome<WorkspaceRead>> read(
    WorkspaceReadRequest request,
    Uint8List nativeEnvelope,
  ) async => const WorkspaceFailure(WorkspaceFailureKind.unsupported);
}
