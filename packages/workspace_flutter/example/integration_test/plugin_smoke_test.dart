import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:workspace/workspace.dart';
import 'package:workspace_flutter/workspace_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('registered native plugin rejects an invalid grant safely', (
    tester,
  ) async {
    final bridge = MethodChannelWorkspaceBridge();
    final id = WorkspaceId('native-smoke');

    await bridge.reconcileAcquisitions(const <WorkspaceId>[]);
    await bridge.cancelWorkspace(id);
    final outcome = await bridge.restore(id, Uint8List.fromList(<int>[0]));

    expect(outcome, isA<WorkspaceFailure<WorkspaceDirectory>>());
    expect(
      (outcome as WorkspaceFailure<WorkspaceDirectory>).kind,
      anyOf(
        WorkspaceFailureKind.permissionLost,
        WorkspaceFailureKind.providerFailure,
      ),
    );
  });
}
