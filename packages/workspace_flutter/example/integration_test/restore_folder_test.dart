import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workspace/workspace.dart';
import 'package:workspace_flutter/workspace_flutter.dart';
import 'package:workspace_flutter_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('restores, lists, and reads after a separate launch', (
    tester,
  ) async {
    final manager = WorkspaceGrantManager(
      vault: PreferencesGrantVault(await SharedPreferences.getInstance()),
    );
    final known = await manager.listKnownWorkspaces();
    expect(known, isNotEmpty);
    final restored = await manager.restore(known.first.id);
    expect(restored, isA<WorkspaceSuccess<FlutterWorkspaceAccess>>());
    final adapter =
        (restored as WorkspaceSuccess<FlutterWorkspaceAccess>).value;
    final access = WorkspaceAccess(adapter);
    try {
      final page = await access.list(
        WorkspaceListRequest(
          workspaceId: adapter.id,
          directory: adapter.root.ref,
          budget: _budget(maxEntries: 100, maxBytes: 64 * 1024),
        ),
      );
      expect(page, isA<WorkspaceSuccess<WorkspacePage>>());
      final entries = (page as WorkspaceSuccess<WorkspacePage>).value.entries;
      final sample = entries.whereType<WorkspaceFile>().singleWhere(
        (entry) => entry.name == 'sample.txt',
      );
      final read = await access.read(
        WorkspaceReadRequest(
          workspaceId: adapter.id,
          file: sample.ref,
          range: const ByteRange(offset: 0, count: 4096),
          budget: _budget(maxEntries: 0, maxBytes: 4096),
        ),
      );
      expect(read, isA<WorkspaceSuccess<WorkspaceRead>>());
      final value = (read as WorkspaceSuccess<WorkspaceRead>).value;
      expect(value.bytes, isNotEmpty);
      expect(value.stability, RevisionStability.unverified);
    } finally {
      await access.close();
    }
  });
}

OperationBudget _budget({required int maxEntries, required int maxBytes}) =>
    OperationBudget(
      maxEntries: maxEntries,
      maxBytes: maxBytes,
      deadline: DateTime.now().add(const Duration(seconds: 30)),
      cancellationToken: CancellationToken(),
    );
