import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workspace/workspace.dart';
import 'package:workspace_flutter/workspace_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('workspace_flutter/test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('picker dismissal is a typed cancellation', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'selectDirectory');
      return null;
    });
    final bridge = MethodChannelWorkspaceBridge(channel: channel);
    final outcome = await bridge.selectDirectory(WorkspaceId('workspace'));
    expect(outcome, isA<WorkspaceFailure<WorkspaceSelection>>());
    expect((outcome as WorkspaceFailure<WorkspaceSelection>).kind,
        WorkspaceFailureKind.cancelled);
  });

  test('list registers per-operation cancellation before settlement', () async {
    final listReply = Completer<Map<String, Object?>>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'list') return listReply.future;
      if (call.method == 'cancel') return null;
      fail('Unexpected method ${call.method}');
    });
    final token = CancellationToken();
    final id = WorkspaceId('workspace');
    final bridge = MethodChannelWorkspaceBridge(channel: channel);
    final pending = bridge.list(
      WorkspaceListRequest(
        workspaceId: id,
        directory: WorkspaceEntryRef.issued(workspaceId: id, stableId: 'root'),
        budget: OperationBudget(
          maxEntries: 2,
          maxBytes: 128,
          deadline: DateTime.now().add(const Duration(minutes: 1)),
          cancellationToken: token,
        ),
      ),
      Uint8List.fromList(<int>[1]),
    );
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await Future<void>.delayed(Duration.zero);

    expect(calls.map((call) => call.method),
        containsAllInOrder(['list', 'cancel']));
    final listArguments = calls.first.arguments! as Map<Object?, Object?>;
    final cancelArguments = calls.last.arguments! as Map<Object?, Object?>;
    expect(listArguments['operationId'], cancelArguments['operationId']);
    expect(listArguments['directoryId'], 'root');
    expect(listArguments['remainingMillis'], isA<int>());
    expect(listArguments['protocolVersion'], 1);

    listReply.complete(<String, Object?>{
      'entries': <Object?>[],
      'completion': 'complete',
      'consistency': 'unverified',
      'usedEntries': 0,
      'usedBytes': 0,
    });
    final outcome = await pending;
    expect((outcome as WorkspaceFailure<WorkspacePage>).kind,
        WorkspaceFailureKind.cancelled);
  });

  test('already-cancelled operations never dispatch', () async {
    var invoked = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      invoked = true;
      return null;
    });
    final token = CancellationToken()..cancel();
    final id = WorkspaceId('workspace');
    final bridge = MethodChannelWorkspaceBridge(channel: channel);
    final outcome = await bridge.read(
      WorkspaceReadRequest(
        workspaceId: id,
        file: WorkspaceEntryRef.issued(workspaceId: id, stableId: 'file'),
        range: const ByteRange(offset: 0, count: 1),
        budget: OperationBudget(
          maxEntries: 0,
          maxBytes: 1,
          deadline: DateTime.now().add(const Duration(minutes: 1)),
          cancellationToken: token,
        ),
      ),
      Uint8List.fromList(<int>[1]),
    );
    expect(invoked, isFalse);
    expect((outcome as WorkspaceFailure<WorkspaceRead>).kind,
        WorkspaceFailureKind.cancelled);
  });

  test('native verified claim without revision evidence is downgraded',
      () async {
    messenger.setMockMethodCallHandler(
        channel,
        (call) async => <String, Object?>{
              'bytes': Uint8List.fromList(<int>[1]),
              'offset': 0,
              'eof': true,
              'actualRevision': null,
              'stability': 'verified',
            });
    final id = WorkspaceId('workspace');
    final bridge = MethodChannelWorkspaceBridge(channel: channel);
    final outcome = await bridge.read(
      WorkspaceReadRequest(
        workspaceId: id,
        file: WorkspaceEntryRef.issued(workspaceId: id, stableId: 'file'),
        range: const ByteRange(offset: 0, count: 1),
        budget: OperationBudget(
          maxEntries: 0,
          maxBytes: 1,
          deadline: DateTime.now().add(const Duration(minutes: 1)),
          cancellationToken: CancellationToken(),
        ),
      ),
      Uint8List.fromList(<int>[1]),
    );
    expect((outcome as WorkspaceSuccess<WorkspaceRead>).value.stability,
        RevisionStability.unverified);
  });

  test('all documented native failure codes retain their typed meaning',
      () async {
    const expected = <String, WorkspaceFailureKind>{
      'cancelled': WorkspaceFailureKind.cancelled,
      'permissionLost': WorkspaceFailureKind.permissionLost,
      'unavailable': WorkspaceFailureKind.unavailable,
      'notFound': WorkspaceFailureKind.notFound,
      'unsupported': WorkspaceFailureKind.unsupported,
      'invalidReference': WorkspaceFailureKind.invalidReference,
      'invalidCursor': WorkspaceFailureKind.invalidCursor,
      'invalidRequest': WorkspaceFailureKind.invalidRequest,
      'budgetExceeded': WorkspaceFailureKind.budgetExceeded,
      'closed': WorkspaceFailureKind.closed,
    };
    final id = WorkspaceId('workspace');
    for (final entry in expected.entries) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: entry.key);
      });
      final outcome = await MethodChannelWorkspaceBridge(channel: channel)
          .restore(id, Uint8List.fromList(<int>[1]));
      expect(
          (outcome as WorkspaceFailure<WorkspaceDirectory>).kind, entry.value);
    }
  });

  test('malformed native list success fails closed', () async {
    messenger.setMockMethodCallHandler(
        channel,
        (call) async => <String, Object?>{
              'entries': <Object?>[],
              'completion': 'hasMore',
              'consistency': 'unverified',
              'usedEntries': 0,
              'usedBytes': 0,
            });
    final id = WorkspaceId('workspace');
    final outcome = await MethodChannelWorkspaceBridge(channel: channel).list(
      WorkspaceListRequest(
        workspaceId: id,
        directory: WorkspaceEntryRef.issued(workspaceId: id, stableId: 'root'),
        budget: OperationBudget(
          maxEntries: 1,
          maxBytes: 1,
          deadline: DateTime.now().add(const Duration(minutes: 1)),
          cancellationToken: CancellationToken(),
        ),
      ),
      Uint8List.fromList(<int>[1]),
    );
    expect((outcome as WorkspaceFailure<WorkspacePage>).kind,
        WorkspaceFailureKind.providerFailure);
  });

  test('malformed native read success fails closed', () async {
    messenger.setMockMethodCallHandler(
        channel,
        (call) async => <String, Object?>{
              'bytes': Uint8List.fromList(<int>[1]),
              // A successful read must not substitute a requested offset.
              'offset': 1,
              'eof': true,
              'actualRevision': null,
              'stability': 'unverified',
            });
    final id = WorkspaceId('workspace');
    final outcome = await MethodChannelWorkspaceBridge(channel: channel).read(
      WorkspaceReadRequest(
        workspaceId: id,
        file: WorkspaceEntryRef.issued(workspaceId: id, stableId: 'file'),
        range: const ByteRange(offset: 0, count: 1),
        budget: OperationBudget(
          maxEntries: 0,
          maxBytes: 1,
          deadline: DateTime.now().add(const Duration(minutes: 1)),
          cancellationToken: CancellationToken(),
        ),
      ),
      Uint8List.fromList(<int>[1]),
    );
    expect((outcome as WorkspaceFailure<WorkspaceRead>).kind,
        WorkspaceFailureKind.providerFailure);
  });

  test('unknown native entry types fail closed rather than escaping', () async {
    messenger.setMockMethodCallHandler(
        channel,
        (call) async => <String, Object?>{
              'entries': <Object?>[
                <String, Object?>{
                  'entryId': 'entry',
                  'name': 'file',
                  'type': 'symlink',
                  'byteLength': 0,
                },
              ],
              'completion': 'complete',
              'consistency': 'unverified',
              'usedEntries': 1,
              'usedBytes': 0,
            });
    final id = WorkspaceId('workspace');
    final outcome = await MethodChannelWorkspaceBridge(channel: channel).list(
      WorkspaceListRequest(
        workspaceId: id,
        directory: WorkspaceEntryRef.issued(workspaceId: id, stableId: 'root'),
        budget: OperationBudget(
          maxEntries: 1,
          maxBytes: 1,
          deadline: DateTime.now().add(const Duration(minutes: 1)),
          cancellationToken: CancellationToken(),
        ),
      ),
      Uint8List.fromList(<int>[1]),
    );
    expect((outcome as WorkspaceFailure<WorkspacePage>).kind,
        WorkspaceFailureKind.providerFailure);
  });

  test('lifecycle calls always carry the protocol-v1 envelope', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final id = WorkspaceId('workspace');
    final bridge = MethodChannelWorkspaceBridge(channel: channel);
    await bridge.cancelWorkspace(id);
    await bridge.commitSelection(id);
    await bridge.abandonSelection(id);
    await bridge.forgetWorkspace(id);
    await bridge.reconcileAcquisitions(<WorkspaceId>[id]);

    for (final call in calls) {
      final values = call.arguments! as Map<Object?, Object?>;
      expect(values['protocolVersion'], 1, reason: call.method);
    }
  });

  test('operation deadlines are capped to the v1 maximum', () async {
    late Map<Object?, Object?> request;
    messenger.setMockMethodCallHandler(channel, (call) async {
      request = call.arguments! as Map<Object?, Object?>;
      return <String, Object?>{
        'entries': <Object?>[],
        'completion': 'complete',
        'consistency': 'unverified',
        'usedEntries': 0,
        'usedBytes': 0,
      };
    });
    final id = WorkspaceId('workspace');
    await MethodChannelWorkspaceBridge(channel: channel).list(
      WorkspaceListRequest(
        workspaceId: id,
        directory: WorkspaceEntryRef.issued(workspaceId: id, stableId: 'root'),
        budget: OperationBudget(
          maxEntries: 1,
          maxBytes: 1,
          deadline: DateTime.now().add(const Duration(days: 2)),
          cancellationToken: CancellationToken(),
        ),
      ),
      Uint8List.fromList(<int>[1]),
    );
    expect(request['remainingMillis'], 86400000);
  });
}
