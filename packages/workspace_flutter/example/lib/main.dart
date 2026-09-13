import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workspace/workspace.dart';
import 'package:workspace_flutter/workspace_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  runApp(WorkspaceProbe(vault: PreferencesGrantVault(preferences)));
}

final class PreferencesGrantVault implements WorkspaceGrantVault {
  PreferencesGrantVault(this._preferences);

  final SharedPreferences _preferences;
  static const _idsKey = 'workspace_probe.ids';

  @override
  Future<void> reservePending({
    required WorkspaceId id,
    required int schemaVersion,
  }) async {
    final ids = {...?_preferences.getStringList(_idsKey), id.value}.toList();
    if (!await _preferences.setStringList(_idsKey, ids) ||
        !await _preferences.setString(_stateKey(id), 'pending') ||
        !await _preferences.setInt(_schemaKey(id), schemaVersion)) {
      throw StateError('Could not reserve workspace state.');
    }
  }

  @override
  Future<void> storeNativeEnvelope(
    WorkspaceId id,
    Uint8List nativeEnvelope,
  ) async {
    if (!await _preferences.setString(
      _envelopeKey(id),
      base64Encode(nativeEnvelope),
    )) {
      throw StateError('Could not store workspace grant.');
    }
  }

  @override
  Future<void> activate(WorkspaceId id) async {
    if (!await _preferences.setString(_stateKey(id), 'active')) {
      throw StateError('Could not activate workspace state.');
    }
  }

  @override
  Future<void> markDeleting(WorkspaceId id) async {
    if (!await _preferences.setString(_stateKey(id), 'deleting')) {
      throw StateError('Could not mark workspace for deletion.');
    }
  }

  @override
  Future<void> delete(WorkspaceId id) async {
    final ids = {...?_preferences.getStringList(_idsKey)}..remove(id.value);
    final results = await Future.wait<bool>([
      _preferences.setStringList(_idsKey, ids.toList()),
      _preferences.remove(_stateKey(id)),
      _preferences.remove(_schemaKey(id)),
      _preferences.remove(_envelopeKey(id)),
    ]);
    if (results.any((result) => !result)) {
      throw StateError('Could not delete workspace state.');
    }
  }

  @override
  Future<Uint8List?> loadNativeEnvelope(WorkspaceId id) async {
    final encoded = _preferences.getString(_envelopeKey(id));
    return encoded == null ? null : base64Decode(encoded);
  }

  @override
  Future<WorkspaceGrantMetadata?> loadMetadata(WorkspaceId id) async {
    final state = _state(_preferences.getString(_stateKey(id)));
    final schema = _preferences.getInt(_schemaKey(id));
    if (state == null || schema == null) return null;
    return WorkspaceGrantMetadata(id: id, state: state, schemaVersion: schema);
  }

  @override
  Future<List<WorkspaceGrantMetadata>> listMetadata() async {
    final records = <WorkspaceGrantMetadata>[];
    for (final rawId in _preferences.getStringList(_idsKey) ?? const []) {
      final record = await loadMetadata(WorkspaceId(rawId));
      if (record != null) records.add(record);
    }
    return records;
  }

  WorkspaceGrantState? _state(String? value) => switch (value) {
    'pending' => WorkspaceGrantState.pending,
    'active' => WorkspaceGrantState.active,
    'deleting' => WorkspaceGrantState.deleting,
    _ => null,
  };

  String _stateKey(WorkspaceId id) => 'workspace_probe.${id.value}.state';
  String _schemaKey(WorkspaceId id) => 'workspace_probe.${id.value}.schema';
  String _envelopeKey(WorkspaceId id) => 'workspace_probe.${id.value}.grant';
}

final class WorkspaceProbe extends StatelessWidget {
  const WorkspaceProbe({super.key, required this.vault});

  final WorkspaceGrantVault vault;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Workspace probe',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    home: ProbeScreen(vault: vault),
  );
}

final class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key, required this.vault});

  final WorkspaceGrantVault vault;

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

final class _ProbeScreenState extends State<ProbeScreen> {
  late final WorkspaceGrantManager _manager;
  String _status = 'Ready';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _manager = WorkspaceGrantManager(vault: widget.vault);
  }

  Future<void> _select() async {
    await _run(() async {
      final outcome = await _manager.selectDirectory();
      _status = switch (outcome) {
        WorkspaceSuccess<WorkspaceId>(:final value) =>
          'Selected workspace ${value.value.substring(0, 8)}',
        WorkspaceFailure<WorkspaceId>(:final kind) => 'Selection: ${kind.name}',
      };
    });
  }

  Future<void> _restoreAndRead() async {
    await _run(() async {
      final known = await _manager.listKnownWorkspaces();
      if (known.isEmpty) {
        _status = 'No saved workspace';
        return;
      }
      final restored = await _manager.restore(known.first.id);
      if (restored is WorkspaceFailure<FlutterWorkspaceAccess>) {
        _status = 'Restore: ${restored.kind.name}';
        return;
      }
      final adapter =
          (restored as WorkspaceSuccess<FlutterWorkspaceAccess>).value;
      final access = WorkspaceAccess(adapter);
      try {
        final pageOutcome = await access.list(
          WorkspaceListRequest(
            workspaceId: adapter.id,
            directory: adapter.root.ref,
            budget: _budget(maxEntries: 100, maxBytes: 64 * 1024),
          ),
        );
        if (pageOutcome is WorkspaceFailure<WorkspacePage>) {
          _status = 'List: ${pageOutcome.kind.name}';
          return;
        }
        final page = (pageOutcome as WorkspaceSuccess<WorkspacePage>).value;
        final files = page.entries.whereType<WorkspaceFile>().toList();
        if (files.isEmpty) {
          _status = 'Listed ${page.entries.length} entries; no file to read';
          return;
        }
        final readOutcome = await access.read(
          WorkspaceReadRequest(
            workspaceId: adapter.id,
            file: files.first.ref,
            range: const ByteRange(offset: 0, count: 4096),
            budget: _budget(maxEntries: 0, maxBytes: 4096),
          ),
        );
        _status = switch (readOutcome) {
          WorkspaceSuccess<WorkspaceRead>(:final value) =>
            'Read ${value.bytes.length} bytes (${value.stability.name})',
          WorkspaceFailure<WorkspaceRead>(:final kind) => 'Read: ${kind.name}',
        };
      } finally {
        await access.close();
      }
    });
  }

  OperationBudget _budget({required int maxEntries, required int maxBytes}) =>
      OperationBudget(
        maxEntries: maxEntries,
        maxBytes: maxBytes,
        deadline: DateTime.now().add(const Duration(seconds: 15)),
        cancellationToken: CancellationToken(),
      );

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (_) {
      _status = 'Probe failed';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Workspace probe')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_status, key: const ValueKey('status')),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _select,
            child: const Text('Select directory'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _busy ? null : _restoreAndRead,
            child: const Text('Restore, list, and read'),
          ),
        ],
      ),
    ),
  );
}
