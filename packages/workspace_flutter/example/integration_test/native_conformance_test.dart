import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Uint8List androidEnvelope(
  String treeUri, {
  String rootId = 'abcdefghijklmnopqrstuv',
}) {
  final payload = utf8.encode(treeUri);
  final rootIdBytes = utf8.encode(rootId);
  final rootDigest = sha256.convert(payload).bytes;
  final length = payload.length;
  return Uint8List.fromList(<int>[
    0x57,
    0x53,
    0x45,
    0x02,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    (rootIdBytes.length >> 8) & 0xff,
    rootIdBytes.length & 0xff,
    ...rootIdBytes,
    ...rootDigest,
    (length >> 24) & 0xff,
    (length >> 16) & 0xff,
    (length >> 8) & 0xff,
    length & 0xff,
    ...payload,
  ]);
}

Uint8List iOSEnvelope(
  List<int> bookmark, {
  String rootId = 'abcdefghijklmnopqrstuv',
}) {
  final rootIdBytes = utf8.encode(rootId);
  final rootPath =
      '${Directory.systemTemp.path}/${iOSFixtureRootName(bookmark)}';
  final rootDigest = sha256.convert(utf8.encode(rootPath)).bytes;
  final length = bookmark.length;
  return Uint8List.fromList(<int>[
    0x57,
    0x53,
    0x45,
    0x02,
    0x02,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    (rootIdBytes.length >> 8) & 0xff,
    rootIdBytes.length & 0xff,
    ...rootIdBytes,
    ...rootDigest,
    (length >> 24) & 0xff,
    (length >> 16) & 0xff,
    (length >> 8) & 0xff,
    length & 0xff,
    ...bookmark,
  ]);
}

String iOSFixtureRootName(List<int> bookmark) {
  switch (String.fromCharCodes(bookmark)) {
    case 'WSFT':
      return 'workspace-flutter-native-fixture';
    case 'WSDN':
      return 'workspace-flutter-native-denied';
    case 'WSMS':
      return 'workspace-flutter-native-missing';
    case 'WSBL':
      return 'workspace-flutter-native-blocked';
    case 'WSUN':
      return 'workspace-flutter-native-unavailable';
    case 'WSPF':
      return 'workspace-flutter-native-provider-failure';
    case 'WSDL':
      return 'workspace-flutter-native-deadline';
    case 'WSBR':
      return 'workspace-flutter-native-blocked-read';
    default:
      return 'workspace-flutter-native-fixture';
  }
}

/// This starts the example normally, so calls reach the generated registrant
/// and production handler rather than a mock binary messenger.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('workspace_flutter/read_only');

  testWidgets('P01 registered plugin rejects an unknown protocol version', (
    tester,
  ) async {
    await expectLater(
      channel.invokeMethod<Object?>('reconcileAcquisitions', <String, Object?>{
        'protocolVersion': 2,
        'activeWorkspaceIds': <String>[],
      }),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalidRequest',
        ),
      ),
    );
  });

  testWidgets('P02 registered plugin rejects missing operation fields', (
    tester,
  ) async {
    await expectLater(
      channel.invokeMethod<Object?>('list', <String, Object?>{
        'protocolVersion': 1,
      }),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalidRequest',
        ),
      ),
    );
  });

  testWidgets('P03 registered plugin validates cancellation envelopes', (
    tester,
  ) async {
    await expectLater(
      channel.invokeMethod<Object?>('cancel', <String, Object?>{
        'protocolVersion': 1,
        'operationId': 'not an opaque id',
      }),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalidRequest',
        ),
      ),
    );
  });

  testWidgets('P04 registered plugin rejects malformed restore envelopes', (
    tester,
  ) async {
    await expectLater(
      channel.invokeMethod<Object?>('restore', <String, Object?>{
        'protocolVersion': 1,
        'workspaceId': 'workspace',
        'envelope': Uint8List.fromList(<int>[1, 2, 3]),
      }),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalidRequest',
        ),
      ),
    );
  });

  testWidgets('P04 registered plugin rejects raw platform credentials', (
    tester,
  ) async {
    final rawCredential = Platform.isAndroid
        ? Uint8List.fromList(
            utf8.encode(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            ),
          )
        : Uint8List.fromList(<int>[0x57, 0x53, 0x46, 0x54]);
    await expectLater(
      channel.invokeMethod<Object?>('restore', <String, Object?>{
        'protocolVersion': 1,
        'workspaceId': 'raw-credential-workspace',
        'envelope': rawCredential,
      }),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalidRequest',
        ),
      ),
    );
  });

  testWidgets('P04 registered plugin rejects the other platform credential', (
    tester,
  ) async {
    final otherPlatformCredential = Platform.isAndroid
        ? iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54])
        : androidEnvelope('content://example.invalid/tree/root');
    await expectLater(
      channel.invokeMethod<Object?>('restore', <String, Object?>{
        'protocolVersion': 1,
        'workspaceId': 'cross-platform-credential-workspace',
        'envelope': otherPlatformCredential,
      }),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalidRequest',
        ),
      ),
    );
  });

  testWidgets('P05 registered plugin rejects unknown request fields', (
    tester,
  ) async {
    await expectLater(
      channel.invokeMethod<Object?>('reconcileAcquisitions', <String, Object?>{
        'protocolVersion': 1,
        'activeWorkspaceIds': <String>[],
        'unexpected': true,
      }),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalidRequest',
        ),
      ),
    );
  });

  testWidgets(
    'P06 registered plugin rejects malformed workspace lifecycle calls',
    (tester) async {
      await expectLater(
        channel.invokeMethod<Object?>('cancelWorkspace', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': 'workspace',
          'unexpected': true,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalidRequest',
          ),
        ),
      );
    },
  );

  const iOSNativeFixture = bool.fromEnvironment(
    'WORKSPACE_NATIVE_TEST_FIXTURE',
  );
  if (Platform.isAndroid || (Platform.isIOS && iOSNativeFixture)) {
    testWidgets(
      'L01/R01 nativeTest fixture traverses the registered production handler',
      (tester) async {
        const workspaceId = 'native-test-workspace';
        final envelope = Platform.isAndroid
            ? androidEnvelope(
                'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
              )
            : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
        final root = await channel.invokeMapMethod<Object?, Object?>(
          'restore',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
          },
        );
        expect(root, isNotNull);
        final rootId = root!['entryId'] as String;
        final restoredAgain = await channel.invokeMapMethod<Object?, Object?>(
          'restore',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
          },
        );
        expect(restoredAgain!['entryId'], rootId);

        final page = await channel.invokeMapMethod<Object?, Object?>(
          'list',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
            'directoryId': rootId,
            'maxEntries': 10,
            'maxBytes': 1024,
            'cursor': null,
            'operationId': 'native_test_list',
            'remainingMillis': 10000,
          },
        );
        expect(page, isNotNull);
        final entries = page!['entries'] as List<Object?>;
        expect(entries, isNotEmpty);
        final file = Map<Object?, Object?>.from(
          entries.cast<Map<Object?, Object?>>().firstWhere(
            (entry) => entry['name'] == 'fixture.txt',
          ),
        );
        expect(file['name'], 'fixture.txt');

        final read = await channel.invokeMapMethod<Object?, Object?>(
          'read',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
            'fileId': file['entryId'],
            'offset': 0,
            'count': 1024,
            'maxBytes': 1024,
            'expectedRevision': null,
            'operationId': 'native_test_read',
            'remainingMillis': 10000,
          },
        );
        expect(read, isNotNull);
        expect(
          utf8.decode(read!['bytes']! as Uint8List),
          'native test fixture',
        );
      },
    );

    testWidgets(
      'L01 nativeTest fixture reuses lineage IDs across concurrent lists',
      (tester) async {
        const workspaceId = 'native-test-concurrent-lineage-workspace';
        final envelope = Platform.isAndroid
            ? androidEnvelope(
                'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
              )
            : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
        final root = await channel.invokeMapMethod<Object?, Object?>(
          'restore',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
          },
        );
        final rootId = root!['entryId'] as String;
        final pages = await Future.wait(
          List<Future<Map<Object?, Object?>?>>.generate(8, (index) {
            return channel.invokeMapMethod<Object?, Object?>(
              'list',
              <String, Object?>{
                'protocolVersion': 1,
                'workspaceId': workspaceId,
                'envelope': envelope,
                'directoryId': rootId,
                'maxEntries': 10,
                'maxBytes': 1024,
                'cursor': null,
                'operationId': 'native_test_concurrent_lineage_$index',
                'remainingMillis': 10000,
              },
            );
          }),
        );
        final identities = pages.map((page) {
          return Map<String, Object?>.fromEntries(
            (page!['entries']! as List<Object?>)
                .cast<Map<Object?, Object?>>()
                .map(
                  (entry) =>
                      MapEntry(entry['name']! as String, entry['entryId']),
                ),
          );
        }).toList();
        for (final identity in identities.skip(1)) {
          expect(identity, identities.first);
        }
      },
    );
  }

  if (Platform.isIOS && iOSNativeFixture) {
    testWidgets(
      'L02 nativeTest fixture rejects a first-entry budget overflow',
      (tester) async {
        const workspaceId = 'native-test-budget-workspace';
        final envelope = iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
        final root = await channel.invokeMapMethod<Object?, Object?>(
          'restore',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
          },
        );

        await expectLater(
          channel.invokeMethod<Object?>('list', <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
            'directoryId': root!['entryId'],
            'maxEntries': 0,
            'maxBytes': 1024,
            'cursor': null,
            'operationId': 'native_test_first_entry_overflow',
            'remainingMillis': 10000,
          }),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'budgetExceeded',
            ),
          ),
        );
      },
    );

    testWidgets('L04 nativeTest fixture resumes and consumes cursors', (
      tester,
    ) async {
      const workspaceId = 'native-test-cursor-workspace';
      final envelope = iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      final root = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      final rootId = root!['entryId'] as String;
      final firstPage = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_cursor_first',
          'remainingMillis': 10000,
        },
      );
      final cursor = firstPage!['cursor'] as String;
      expect(firstPage['completion'], 'hasMore');

      final secondPage = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': cursor,
          'operationId': 'native_test_cursor_second',
          'remainingMillis': 10000,
        },
      );
      expect(secondPage, isNotNull);
      expect(secondPage!['completion'], 'complete');
      expect(secondPage['cursor'], isNull);

      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': cursor,
          'operationId': 'native_test_cursor_replay',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalidCursor',
          ),
        ),
      );

      final mismatchPage = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_cursor_mismatch_first',
          'remainingMillis': 10000,
        },
      );
      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 2,
          'maxBytes': 1024,
          'cursor': mismatchPage!['cursor'],
          'operationId': 'native_test_cursor_mismatch_resume',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalidCursor',
          ),
        ),
      );

      final expiringPage = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_cursor_expiry_first',
          'remainingMillis': 100,
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': expiringPage!['cursor'],
          'operationId': 'native_test_cursor_expiry_resume',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalidCursor',
          ),
        ),
      );
    });
  }

  if (Platform.isAndroid || (Platform.isIOS && iOSNativeFixture)) {
    testWidgets('R02 nativeTest fixture rejects a directory as a file', (
      tester,
    ) async {
      const workspaceId = 'native-test-directory-read-workspace';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      final root = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      await expectLater(
        channel.invokeMethod<Object?>('read', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'fileId': root!['entryId'],
          'offset': 0,
          'count': 1,
          'maxBytes': 1,
          'expectedRevision': null,
          'operationId': 'native_test_directory_read',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'unsupported',
          ),
        ),
      );
    });

    testWidgets('R01 nativeTest fixture bounds exact and EOF range reads', (
      tester,
    ) async {
      const workspaceId = 'native-test-range-workspace';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      final root = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      final page = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': root!['entryId'],
          'maxEntries': 10,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_range_list',
          'remainingMillis': 10000,
        },
      );
      final fileId = (page!['entries'] as List<Object?>)
          .cast<Map<Object?, Object?>>()
          .firstWhere((entry) => entry['name'] == 'fixture.txt')['entryId'];

      Future<Map<Object?, Object?>> read(
        int offset,
        int count,
        String operationId, {
        Map<String, Object?>? expectedRevision,
      }) async {
        final value = await channel.invokeMapMethod<Object?, Object?>(
          'read',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
            'fileId': fileId,
            'offset': offset,
            'count': count,
            'maxBytes': count,
            'expectedRevision': expectedRevision,
            'operationId': operationId,
            'remainingMillis': 10000,
          },
        );
        return Map<Object?, Object?>.from(value!);
      }

      final exact = await read(0, 6, 'native_test_range_exact');
      expect(utf8.decode(exact['bytes']! as Uint8List), 'native');
      expect(exact['eof'], isFalse);
      final expectedRevisionRead = await read(
        0,
        1,
        'native_test_range_expected_revision',
        expectedRevision: <String, Object?>{
          'kind': 'platform',
          'namespace': 'fixture',
          'value': 'client-revision',
        },
      );
      expect(expectedRevisionRead['actualRevision'], isNull);
      expect(expectedRevisionRead['stability'], 'unverified');
      final short = await read(16, 10, 'native_test_range_short');
      expect(utf8.decode(short['bytes']! as Uint8List), 'ure');
      expect(short['eof'], isTrue);
      final past = await read(100, 4, 'native_test_range_past_eof');
      expect(
        past['bytes'],
        isA<Uint8List>().having((value) => value, 'empty', isEmpty),
      );
      expect(past['eof'], isTrue);
    });

    testWidgets('A01 nativeTest fixture rejects an unknown entry ID', (
      tester,
    ) async {
      const workspaceId = 'native-test-unknown-entry-workspace';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': 'never_issued_entry_id',
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_unknown_entry_list',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalidReference',
          ),
        ),
      );
    });

    testWidgets('A02 nativeTest fixture rejects a cross-workspace entry ID', (
      tester,
    ) async {
      const firstWorkspace = 'native-test-cross-workspace-a';
      const secondWorkspace = 'native-test-cross-workspace-b';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      final firstRoot = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': firstWorkspace,
          'envelope': envelope,
        },
      );
      final firstPage = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': firstWorkspace,
          'envelope': envelope,
          'directoryId': firstRoot!['entryId'],
          'maxEntries': 10,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_cross_workspace_list',
          'remainingMillis': 10000,
        },
      );
      final firstFile = (firstPage!['entries'] as List<Object?>)
          .cast<Map<Object?, Object?>>()
          .firstWhere((entry) => entry['type'] == 'file')['entryId'];
      final secondRoot = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': secondWorkspace,
          'envelope': envelope,
        },
      );
      expect(secondRoot, isNotNull);
      await expectLater(
        channel.invokeMethod<Object?>('read', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': secondWorkspace,
          'envelope': envelope,
          'fileId': firstFile,
          'offset': 0,
          'count': 1,
          'maxBytes': 1,
          'expectedRevision': null,
          'operationId': 'native_test_cross_workspace_read',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalidReference',
          ),
        ),
      );
    });

    testWidgets('A02 nativeTest fixture rejects a root swap in one workspace', (
      tester,
    ) async {
      const workspaceId = 'native-test-root-swap-workspace';
      final firstEnvelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      final swappedEnvelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/missing',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x4D, 0x53]);
      await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': firstEnvelope,
        },
      );
      await expectLater(
        channel.invokeMethod<Object?>('restore', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': swappedEnvelope,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'permissionLost',
          ),
        ),
      );
    });

    testWidgets(
      'C01 nativeTest fixture cancels an in-flight provider operation',
      (tester) async {
        const workspaceId = 'native-test-cancel-workspace';
        const operationId = 'native_test_blocked_list';
        final envelope = Platform.isAndroid
            ? androidEnvelope(
                'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/blocked',
              )
            : iOSEnvelope(<int>[0x57, 0x53, 0x42, 0x4C]);
        final root = await channel.invokeMapMethod<Object?, Object?>(
          'restore',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
          },
        );
        final list = channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': root!['entryId'],
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': operationId,
          'remainingMillis': 10000,
        });
        await channel.invokeMethod<void>('cancel', <String, Object?>{
          'protocolVersion': 1,
          'operationId': operationId,
        });
        await expectLater(
          list,
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'cancelled',
            ),
          ),
        );
      },
    );

    testWidgets('C01 nativeTest fixture cancels an in-flight file read', (
      tester,
    ) async {
      const workspaceId = 'native-test-cancel-read-workspace';
      const operationId = 'native_test_blocked_read';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/blocked-read',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x42, 0x52]);
      final root = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      final page = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': root!['entryId'],
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_blocked_read_list',
          'remainingMillis': 10000,
        },
      );
      final fileId = Map<Object?, Object?>.from(
        (page!['entries'] as List<Object?>).single as Map<Object?, Object?>,
      )['entryId'];
      final read = channel.invokeMethod<Object?>('read', <String, Object?>{
        'protocolVersion': 1,
        'workspaceId': workspaceId,
        'envelope': envelope,
        'fileId': fileId,
        'offset': 0,
        'count': 1,
        'maxBytes': 1,
        'expectedRevision': null,
        'operationId': operationId,
        'remainingMillis': 10000,
      });
      await channel.invokeMethod<void>('cancel', <String, Object?>{
        'protocolVersion': 1,
        'operationId': operationId,
      });
      await expectLater(
        read,
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
    });

    testWidgets(
      'C02 nativeTest fixture rejects a duplicate live operation ID',
      (tester) async {
        const workspaceId = 'native-test-duplicate-workspace';
        const operationId = 'native_test_duplicate_list';
        final envelope = Platform.isAndroid
            ? androidEnvelope(
                'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/blocked',
              )
            : iOSEnvelope(<int>[0x57, 0x53, 0x42, 0x4C]);
        final root = await channel.invokeMapMethod<Object?, Object?>(
          'restore',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
          },
        );
        Map<String, Object?> listRequest() => <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': root!['entryId'],
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': operationId,
          'remainingMillis': 10000,
        };
        final first = channel.invokeMethod<Object?>('list', listRequest());
        await expectLater(
          channel.invokeMethod<Object?>('list', listRequest()),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'invalidRequest',
            ),
          ),
        );
        await channel.invokeMethod<void>('cancel', <String, Object?>{
          'protocolVersion': 1,
          'operationId': operationId,
        });
        await expectLater(
          first,
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'cancelled',
            ),
          ),
        );
      },
    );

    testWidgets('C02 nativeTest fixture expires an in-flight deadline', (
      tester,
    ) async {
      const workspaceId = 'native-test-deadline-workspace';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/deadline',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x44, 0x4C]);
      final root = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': root!['entryId'],
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_deadline_list',
          'remainingMillis': 1,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'budgetExceeded',
          ),
        ),
      );
    });

    testWidgets('C03 nativeTest close invalidates later registered access', (
      tester,
    ) async {
      const workspaceId = 'native-test-close-workspace';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      final root = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      final rootId = root!['entryId'] as String;
      await channel.invokeMethod<void>('cancelWorkspace', <String, Object?>{
        'protocolVersion': 1,
        'workspaceId': workspaceId,
      });

      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_close_later_list',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'closed',
          ),
        ),
      );
    });

    testWidgets('C03 nativeTest abandonment clears pending private lineage', (
      tester,
    ) async {
      const workspaceId = 'native-test-abandon-workspace';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      final initial = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      await channel.invokeMethod<void>('abandonSelection', <String, Object?>{
        'protocolVersion': 1,
        'workspaceId': workspaceId,
      });
      final restoredEnvelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
              rootId: 'bcdefghijklmnopqrstuvA',
            )
          : iOSEnvelope(<int>[
              0x57,
              0x53,
              0x46,
              0x54,
            ], rootId: 'bcdefghijklmnopqrstuvA');
      final restored = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': restoredEnvelope,
        },
      );
      expect(restored!['entryId'], isNot(initial!['entryId']));
    });

    testWidgets('C03 nativeTest close is isolated to one workspace', (
      tester,
    ) async {
      const closedWorkspace = 'native-test-close-isolated-a';
      const liveWorkspace = 'native-test-close-isolated-b';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      final closedRoot = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': closedWorkspace,
          'envelope': envelope,
        },
      );
      final liveRoot = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': liveWorkspace,
          'envelope': envelope,
        },
      );
      await channel.invokeMethod<void>('cancelWorkspace', <String, Object?>{
        'protocolVersion': 1,
        'workspaceId': closedWorkspace,
      });
      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': closedWorkspace,
          'envelope': envelope,
          'directoryId': closedRoot!['entryId'],
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_close_isolated_closed',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'closed',
          ),
        ),
      );
      final page = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': liveWorkspace,
          'envelope': envelope,
          'directoryId': liveRoot!['entryId'],
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_close_isolated_live',
          'remainingMillis': 10000,
        },
      );
      expect(page!['entries'], isNotEmpty);
    });

    testWidgets('C03 nativeTest reconciliation removes inactive authority', (
      tester,
    ) async {
      const workspaceId = 'native-test-reconcile-workspace';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      final root = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      await channel.invokeMethod<void>(
        'reconcileAcquisitions',
        <String, Object?>{
          'protocolVersion': 1,
          'activeWorkspaceIds': <String>[],
        },
      );
      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': root!['entryId'],
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_reconcile_list',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'permissionLost',
          ),
        ),
      );
    });

    testWidgets('C03 nativeTest forget removes prior authority', (
      tester,
    ) async {
      const workspaceId = 'native-test-forget-workspace';
      final envelope = Platform.isAndroid
          ? androidEnvelope(
              'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
            )
          : iOSEnvelope(<int>[0x57, 0x53, 0x46, 0x54]);
      final root = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      await channel.invokeMethod<void>('forgetWorkspace', <String, Object?>{
        'protocolVersion': 1,
        'workspaceId': workspaceId,
      });
      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': root!['entryId'],
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_forget_list',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'permissionLost',
          ),
        ),
      );
    });
  }

  if (Platform.isAndroid) {
    testWidgets(
      'L02 nativeTest fixture rejects a first-entry budget overflow',
      (tester) async {
        const workspaceId = 'native-test-android-budget-workspace';
        final envelope = androidEnvelope(
          'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
        );
        final root = await channel.invokeMapMethod<Object?, Object?>(
          'restore',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
          },
        );

        await expectLater(
          channel.invokeMethod<Object?>('list', <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
            'directoryId': root!['entryId'],
            'maxEntries': 0,
            'maxBytes': 1024,
            'cursor': null,
            'operationId': 'native_test_android_first_entry_overflow',
            'remainingMillis': 10000,
          }),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'budgetExceeded',
            ),
          ),
        );
      },
    );

    testWidgets('L04 nativeTest fixture resumes and consumes cursors', (
      tester,
    ) async {
      const workspaceId = 'native-test-android-cursor-workspace';
      final envelope = androidEnvelope(
        'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/root',
      );
      final root = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      final rootId = root!['entryId'] as String;
      final firstPage = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_android_cursor_first',
          'remainingMillis': 10000,
        },
      );
      expect(firstPage!['completion'], 'hasMore');
      final cursor = firstPage['cursor'] as String;

      final secondPage = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': cursor,
          'operationId': 'native_test_android_cursor_second',
          'remainingMillis': 10000,
        },
      );
      expect(secondPage!['completion'], 'complete');
      expect(secondPage['cursor'], isNull);

      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': cursor,
          'operationId': 'native_test_android_cursor_replay',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalidCursor',
          ),
        ),
      );

      final mismatchPage = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_android_cursor_mismatch_first',
          'remainingMillis': 10000,
        },
      );
      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 2,
          'maxBytes': 1024,
          'cursor': mismatchPage!['cursor'],
          'operationId': 'native_test_android_cursor_mismatch_resume',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalidCursor',
          ),
        ),
      );

      final expiringPage = await channel.invokeMapMethod<Object?, Object?>(
        'list',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_android_cursor_expiry_first',
          'remainingMillis': 100,
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': rootId,
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': expiringPage!['cursor'],
          'operationId': 'native_test_android_cursor_expiry_resume',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalidCursor',
          ),
        ),
      );
    });

    testWidgets('A03 nativeTest fixture revalidates deletion and type mutation', (
      tester,
    ) async {
      Future<void> expectReadFailure(
        String rootName,
        String expectedCode,
      ) async {
        final workspaceId = 'native-test-mutation-$rootName';
        final envelope = androidEnvelope(
          'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/$rootName',
        );
        final root = await channel.invokeMapMethod<Object?, Object?>(
          'restore',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
          },
        );
        final page = await channel.invokeMapMethod<Object?, Object?>(
          'list',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
            'directoryId': root!['entryId'],
            'maxEntries': 1,
            'maxBytes': 1024,
            'cursor': null,
            'operationId': 'native_test_mutation_list_$rootName',
            'remainingMillis': 10000,
          },
        );
        final entry =
            (page!['entries']! as List<Object?>).single
                as Map<Object?, Object?>;
        await expectLater(
          channel.invokeMethod<Object?>('read', <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
            'fileId': entry['entryId'],
            'offset': 0,
            'count': 1,
            'maxBytes': 1,
            'expectedRevision': null,
            'operationId': 'native_test_mutation_read_$rootName',
            'remainingMillis': 10000,
          }),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              expectedCode,
            ),
          ),
        );
      }

      await expectReadFailure('deleted-after-list', 'notFound');
      await expectReadFailure('file-to-directory', 'unsupported');
    });

    testWidgets('A03 nativeTest fixture maps typed provider failures', (
      tester,
    ) async {
      Future<void> expectListFailure(String rootId, String expectedCode) async {
        final workspaceId = 'native-test-$rootId-workspace';
        final envelope = androidEnvelope(
          'content://com.mattsp1290.workspace_flutter_example.native_test_documents/tree/$rootId',
        );
        final root = await channel.invokeMapMethod<Object?, Object?>(
          'restore',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
          },
        );
        await expectLater(
          channel.invokeMethod<Object?>('list', <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspaceId,
            'envelope': envelope,
            'directoryId': root!['entryId'],
            'maxEntries': 1,
            'maxBytes': 1024,
            'cursor': null,
            'operationId': 'native_test_${rootId}_list',
            'remainingMillis': 10000,
          }),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              expectedCode,
            ),
          ),
        );
      }

      await expectListFailure('denied', 'permissionLost');
      await expectListFailure('missing', 'notFound');
      await expectListFailure('unavailable', 'unavailable');
      await expectListFailure('provider-failure', 'providerFailure');
    });
  }

  if (Platform.isIOS && iOSNativeFixture) {
    testWidgets('A03 nativeTest fixture maps typed provider failures', (
      tester,
    ) async {
      await expectLater(
        channel.invokeMethod<Object?>('restore', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': 'native-test-denied-workspace',
          'envelope': iOSEnvelope(<int>[0x57, 0x53, 0x44, 0x4E]),
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'permissionLost',
          ),
        ),
      );

      const workspaceId = 'native-test-missing-workspace';
      final envelope = iOSEnvelope(<int>[0x57, 0x53, 0x4D, 0x53]);
      final root = await channel.invokeMapMethod<Object?, Object?>(
        'restore',
        <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
        },
      );
      await expectLater(
        channel.invokeMethod<Object?>('list', <String, Object?>{
          'protocolVersion': 1,
          'workspaceId': workspaceId,
          'envelope': envelope,
          'directoryId': root!['entryId'],
          'maxEntries': 1,
          'maxBytes': 1024,
          'cursor': null,
          'operationId': 'native_test_missing_list',
          'remainingMillis': 10000,
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'notFound',
          ),
        ),
      );

      Future<void> expectListFailure(
        String identifier,
        Uint8List fixtureEnvelope,
        String expectedCode,
      ) async {
        final workspace = 'native-test-$identifier-workspace';
        final fixtureRoot = await channel.invokeMapMethod<Object?, Object?>(
          'restore',
          <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspace,
            'envelope': fixtureEnvelope,
          },
        );
        await expectLater(
          channel.invokeMethod<Object?>('list', <String, Object?>{
            'protocolVersion': 1,
            'workspaceId': workspace,
            'envelope': fixtureEnvelope,
            'directoryId': fixtureRoot!['entryId'],
            'maxEntries': 1,
            'maxBytes': 1024,
            'cursor': null,
            'operationId': 'native_test_${identifier}_list',
            'remainingMillis': 10000,
          }),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              expectedCode,
            ),
          ),
        );
      }

      await expectListFailure(
        'unavailable',
        iOSEnvelope(<int>[0x57, 0x53, 0x55, 0x4E]),
        'unavailable',
      );
      await expectListFailure(
        'provider-failure',
        iOSEnvelope(<int>[0x57, 0x53, 0x50, 0x46]),
        'providerFailure',
      );
    });
  }
}
