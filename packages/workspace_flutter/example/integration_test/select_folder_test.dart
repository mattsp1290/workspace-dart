import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workspace/workspace.dart';
import 'package:workspace_flutter/workspace_flutter.dart';
import 'package:workspace_flutter_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('selects and stores the synthetic workspace', (tester) async {
    final manager = WorkspaceGrantManager(
      vault: PreferencesGrantVault(await SharedPreferences.getInstance()),
    );
    final outcome = await manager.selectDirectory();
    expect(outcome, isA<WorkspaceSuccess<WorkspaceId>>());
  });
}
