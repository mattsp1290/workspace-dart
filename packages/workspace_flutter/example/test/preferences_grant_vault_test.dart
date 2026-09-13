import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workspace/workspace.dart';
import 'package:workspace_flutter/workspace_flutter.dart';
import 'package:workspace_flutter_example/main.dart';

void main() {
  test('probe vault persists and deletes opaque grant records', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final vault = PreferencesGrantVault(await SharedPreferences.getInstance());
    final id = WorkspaceId('test');

    await vault.reservePending(id: id, schemaVersion: 1);
    await vault.storeNativeEnvelope(id, Uint8List.fromList(<int>[1, 2, 3]));
    await vault.activate(id);

    expect((await vault.loadMetadata(id))?.state, WorkspaceGrantState.active);
    expect(
      await vault.loadNativeEnvelope(id),
      Uint8List.fromList(<int>[1, 2, 3]),
    );

    await vault.markDeleting(id);
    await vault.delete(id);
    expect(await vault.loadMetadata(id), isNull);
    expect(await vault.loadNativeEnvelope(id), isNull);
  });
}
