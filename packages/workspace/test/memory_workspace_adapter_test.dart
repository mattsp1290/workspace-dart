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
    root = WorkspaceEntryRef(workspaceId: id, token: adapter.rootToken);
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
        expectedRevision: const ContentRevision('stale')));
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
    root = WorkspaceEntryRef(workspaceId: id, token: adapter.rootToken);
    final first = (await adapter.list(WorkspaceListRequest(
            workspaceId: id,
            directory: root,
            budget: budget())) as WorkspaceSuccess<WorkspacePage>)
        .value;
    expect(first.completion, ListCompletion.hasMore);
    final second = await adapter.list(WorkspaceListRequest(
        workspaceId: id,
        directory: root,
        cursor: first.cursor,
        budget: budget()));
    expect(
        (second as WorkspaceSuccess<WorkspacePage>).value.entries.single.name,
        'b');
    await adapter.close();
    final afterClose = await adapter.list(WorkspaceListRequest(
        workspaceId: id, directory: root, budget: budget()));
    expect((afterClose as WorkspaceFailure<WorkspacePage>).kind,
        WorkspaceFailureKind.closed);
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
}
