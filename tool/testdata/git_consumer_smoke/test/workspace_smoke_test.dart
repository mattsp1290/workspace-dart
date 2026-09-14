import 'package:flutter_test/flutter_test.dart';
import 'package:workspace/workspace.dart';
import 'package:workspace_flutter/workspace_flutter.dart';

void main() {
  test('both Git subdirectory packages expose their public APIs', () {
    expect(WorkspaceId('consumer-workspace').value, 'consumer-workspace');
    expect(WorkspaceGrantMetadata, isNotNull);
  });
}
