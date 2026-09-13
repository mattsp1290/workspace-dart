import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:workspace/workspace.dart';

OperationBudget budget({int entries = 10, int bytes = 1024}) => OperationBudget(
      maxEntries: entries,
      maxBytes: bytes,
      deadline: DateTime.now().add(const Duration(minutes: 1)),
      cancellationToken: CancellationToken(),
    );

void main() {
  test('platform revision values follow the native v1 byte limits', () {
    expect(
      PlatformContentRevision(
        namespace: 'provider_1',
        value: List<String>.filled(4096, 'a').join(),
      ).value.length,
      4096,
    );
    expect(
      () => PlatformContentRevision(namespace: 'bad namespace', value: 'v'),
      throwsFormatException,
    );
    expect(
      () => PlatformContentRevision(
        namespace: 'provider',
        value: List<String>.filled(4097, 'a').join(),
      ),
      throwsFormatException,
    );
  });

  final id = WorkspaceId('test-workspace');
  late MemoryWorkspaceAdapter adapter;
  late WorkspaceEntryRef root;
  setUp(() {
    adapter = MemoryWorkspaceAdapter(
      workspaceId: id,
      root: MemoryDirectoryNode('root', [
        MemoryFileNode('notes.txt', [1, 2, 3])
      ]),
    );
    root =
        WorkspaceEntryRef.issued(workspaceId: id, stableId: adapter.rootToken);
  });

  test('list returns root-bound opaque file references', () async {
    final result = await adapter.list(WorkspaceListRequest(
        workspaceId: id, directory: root, budget: budget()));
    expect(result, isA<WorkspaceSuccess<WorkspacePage>>());
    final page = (result as WorkspaceSuccess<WorkspacePage>).value;
    expect(page.completion, ListCompletion.complete);
    expect(page.entries.single, isA<WorkspaceFile>());
    expect(page.entries.single.ref.workspaceId, id);
  });

  test('read returns the exact requested slice and slice digest', () async {
    final page = (await adapter.list(WorkspaceListRequest(
            workspaceId: id,
            directory: root,
            budget: budget())) as WorkspaceSuccess<WorkspacePage>)
        .value;
    final file = page.entries.single as WorkspaceFile;
    final result = await adapter.read(WorkspaceReadRequest(
        workspaceId: id,
        file: file.ref,
        range: const ByteRange(offset: 1, count: 8),
        budget: budget()));
    final read = (result as WorkspaceSuccess<WorkspaceRead>).value;
    expect(read.bytes, Uint8List.fromList([2, 3]));
    expect(read.offset, 1);
    expect(read.eof, isTrue);
    expect(read.sliceSha256, isNotEmpty);
  });

  test('cross-workspace references fail closed', () async {
    final result = await adapter.list(WorkspaceListRequest(
        workspaceId: WorkspaceId('other'), directory: root, budget: budget()));
    expect((result as WorkspaceFailure<WorkspacePage>).kind,
        WorkspaceFailureKind.invalidReference);
  });

  test('expected revision mismatch retains bytes with changed stability',
      () async {
    final page = (await adapter.list(WorkspaceListRequest(
            workspaceId: id,
            directory: root,
            budget: budget())) as WorkspaceSuccess<WorkspacePage>)
        .value;
    final file = page.entries.single as WorkspaceFile;
    final result = await adapter.read(WorkspaceReadRequest(
        workspaceId: id,
        file: file.ref,
        range: const ByteRange(offset: 0, count: 3),
        budget: budget(),
        expectedRevision: WholeContentSha256(
            '0000000000000000000000000000000000000000000000000000000000000000')));
    expect((result as WorkspaceSuccess<WorkspaceRead>).value.stability,
        RevisionStability.changed);
  });

  test('page cursors are opaque, single-use, and invalid after close',
      () async {
    adapter = MemoryWorkspaceAdapter(
      workspaceId: id,
      pageSize: 1,
      root: MemoryDirectoryNode(
          'root', [MemoryFileNode('a', []), MemoryFileNode('b', [])]),
    );
    root =
        WorkspaceEntryRef.issued(workspaceId: id, stableId: adapter.rootToken);
    final pageBudget = budget();
    final first = (await adapter.list(WorkspaceListRequest(
            workspaceId: id,
            directory: root,
            budget: pageBudget)) as WorkspaceSuccess<WorkspacePage>)
        .value;
    expect(first.completion, ListCompletion.hasMore);
    final second = await adapter.list(WorkspaceListRequest(
        workspaceId: id,
        directory: root,
        cursor: first.cursor,
        budget: pageBudget));
    expect(
        (second as WorkspaceSuccess<WorkspacePage>).value.entries.single.name,
        'b');
    await adapter.close();
    final afterClose = await adapter.list(WorkspaceListRequest(
        workspaceId: id, directory: root, budget: budget()));
    expect((afterClose as WorkspaceFailure<WorkspacePage>).kind,
        WorkspaceFailureKind.closed);
  });

  test('cursor cannot be replayed against another directory', () async {
    adapter = MemoryWorkspaceAdapter(
      workspaceId: id,
      pageSize: 1,
      root: MemoryDirectoryNode('root', [
        MemoryDirectoryNode(
            'first', [MemoryFileNode('a', []), MemoryFileNode('b', [])]),
        MemoryDirectoryNode('second', [MemoryFileNode('c', [])]),
      ]),
    );
    root =
        WorkspaceEntryRef.issued(workspaceId: id, stableId: adapter.rootToken);
    final rootBudget = budget();
    final rootPage = (await adapter.list(WorkspaceListRequest(
            workspaceId: id,
            directory: root,
            budget: rootBudget)) as WorkspaceSuccess<WorkspacePage>)
        .value;
    final firstDirectory = rootPage.entries.first as WorkspaceDirectory;
    final directoryBudget = budget();
    final page = (await adapter.list(WorkspaceListRequest(
            workspaceId: id,
            directory: firstDirectory.ref,
            budget: directoryBudget)) as WorkspaceSuccess<WorkspacePage>)
        .value;
    final replay = await adapter.list(WorkspaceListRequest(
        workspaceId: id,
        directory: root,
        cursor: page.cursor,
        budget: directoryBudget));
    expect((replay as WorkspaceFailure<WorkspacePage>).kind,
        WorkspaceFailureKind.invalidCursor);
  });

  test('malformed requests and pre-first-entry exhaustion are typed failures',
      () async {
    final invalidBudget = await adapter.list(WorkspaceListRequest(
        workspaceId: id,
        directory: root,
        budget: OperationBudget(
            maxEntries: -1,
            maxBytes: 1,
            deadline: DateTime.now(),
            cancellationToken: CancellationToken())));
    expect((invalidBudget as WorkspaceFailure<WorkspacePage>).kind,
        WorkspaceFailureKind.invalidRequest);
    final noEntries = await adapter.list(WorkspaceListRequest(
        workspaceId: id, directory: root, budget: budget(entries: 0)));
    expect((noEntries as WorkspaceFailure<WorkspacePage>).kind,
        WorkspaceFailureKind.budgetExceeded);
  });

  test('cancelled work never becomes an empty directory', () async {
    final token = CancellationToken()..cancel();
    final result = await adapter.list(WorkspaceListRequest(
      workspaceId: id,
      directory: root,
      budget: OperationBudget(
          maxEntries: 1,
          maxBytes: 1,
          deadline: DateTime.now().add(const Duration(minutes: 1)),
          cancellationToken: token),
    ));
    expect((result as WorkspaceFailure<WorkspacePage>).kind,
        WorkspaceFailureKind.cancelled);
  });

  test('entry references round-trip without exposing authority', () {
    final reference =
        WorkspaceEntryRef.issued(workspaceId: id, stableId: adapter.rootToken);
    final restored = WorkspaceEntryRef.parse(reference.serialize());
    expect(restored, reference);
    expect(reference.toString(), isNot(contains(adapter.rootToken)));
    expect(() => WorkspaceEntryRef.parse('v1:${id.value}:../escape'),
        throwsFormatException);
  });

  test('cancellation listeners settle once and can unregister', () {
    final token = CancellationToken();
    var calls = 0;
    final unregister = token.register(() => calls++);
    unregister();
    token.cancel();
    token.cancel();
    expect(calls, 0);
    token.register(() => calls++);
    expect(calls, 1);
  });

  test('incomparable revision evidence is never verified', () async {
    final page = (await adapter.list(WorkspaceListRequest(
            workspaceId: id,
            directory: root,
            budget: budget())) as WorkspaceSuccess<WorkspacePage>)
        .value;
    final file = page.entries.single as WorkspaceFile;
    final result = await adapter.read(WorkspaceReadRequest(
      workspaceId: id,
      file: file.ref,
      range: const ByteRange(offset: 0, count: 3),
      budget: budget(),
      expectedRevision:
          PlatformContentRevision(namespace: 'provider', value: 'version-1'),
    ));
    expect((result as WorkspaceSuccess<WorkspaceRead>).value.stability,
        RevisionStability.unverified);
  });
}
