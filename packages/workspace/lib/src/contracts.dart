import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'identities.dart';

enum ListCompletion { complete, hasMore, budgetExhausted }

enum ListConsistency { verified, changed, unverified }

enum RevisionStability { verified, changed, unverified }

final class CancellationToken {
  bool _cancelled = false;
  final Set<void Function()> _listeners = <void Function()>{};
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  /// Registers a callback and returns an idempotent unregister function.
  ///
  /// If cancellation already happened, [listener] runs synchronously.
  void Function() register(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    var registered = true;
    return () {
      if (!registered) return;
      registered = false;
      _listeners.remove(listener);
    };
  }
}

final class OperationBudget {
  const OperationBudget(
      {required this.maxEntries,
      required this.maxBytes,
      required this.deadline,
      required this.cancellationToken});
  final int maxEntries;
  final int maxBytes;
  final DateTime deadline;
  final CancellationToken cancellationToken;
  bool get isExpired => DateTime.now().isAfter(deadline);
  bool get isValid => maxEntries >= 0 && maxBytes >= 0;
}

final class BudgetUsage {
  const BudgetUsage({this.entries = 0, this.bytes = 0});
  final int entries;
  final int bytes;
  BudgetUsage add({int entries = 0, int bytes = 0}) =>
      BudgetUsage(entries: this.entries + entries, bytes: this.bytes + bytes);
}

final class WorkspacePageCursor {
  WorkspacePageCursor({required this.workspaceId, required String token})
      : token = token;
  final WorkspaceId workspaceId;
  final String token;
  @override
  String toString() => 'WorkspacePageCursor(${workspaceId.value}, <opaque>)';
}

sealed class WorkspaceEntry {
  const WorkspaceEntry(
      {required this.ref, required this.displayPath, required this.name});
  final WorkspaceEntryRef ref;
  final WorkspaceDisplayPath displayPath;
  final String name;
}

final class WorkspaceFile extends WorkspaceEntry {
  const WorkspaceFile(
      {required super.ref,
      required super.displayPath,
      required super.name,
      required this.byteLength});
  final int byteLength;
}

final class WorkspaceDirectory extends WorkspaceEntry {
  const WorkspaceDirectory(
      {required super.ref, required super.displayPath, required super.name});
}

sealed class ContentRevision {
  const ContentRevision();

  bool isComparableTo(ContentRevision other) =>
      runtimeType == other.runtimeType;
}

final class WholeContentSha256 extends ContentRevision {
  WholeContentSha256(String value) : value = _sha256(value);
  final String value;
  @override
  bool operator ==(Object other) =>
      other is WholeContentSha256 && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

final class PlatformContentRevision extends ContentRevision {
  PlatformContentRevision({required String namespace, required String value})
      : namespace = _revisionNamespace(namespace),
        value = _revisionValue(value);
  final String namespace;
  final String value;

  @override
  bool isComparableTo(ContentRevision other) =>
      other is PlatformContentRevision && other.namespace == namespace;

  @override
  bool operator ==(Object other) =>
      other is PlatformContentRevision &&
      other.namespace == namespace &&
      other.value == value;
  @override
  int get hashCode => Object.hash(namespace, value);
}

String _sha256(String value) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('Invalid SHA-256 revision.');
  }
  return value;
}

String _revisionValue(String value) {
  if (value.isEmpty ||
      value.length > 4096 ||
      utf8.encode(value).length > 4096 ||
      value.contains('\u0000')) {
    throw const FormatException('Invalid platform revision.');
  }
  return value;
}

String _revisionNamespace(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value)) {
    throw const FormatException('Invalid platform revision namespace.');
  }
  return value;
}

final class ByteRange {
  const ByteRange({required this.offset, required this.count});
  final int offset;
  final int count;
  bool get isValid => offset >= 0 && count >= 0;
}

final class WorkspaceListRequest {
  const WorkspaceListRequest(
      {required this.workspaceId,
      required this.directory,
      required this.budget,
      this.cursor});
  final WorkspaceId workspaceId;
  final WorkspaceEntryRef directory;
  final OperationBudget budget;
  final WorkspacePageCursor? cursor;
}

final class WorkspaceReadRequest {
  const WorkspaceReadRequest(
      {required this.workspaceId,
      required this.file,
      required this.range,
      required this.budget,
      this.expectedRevision});
  final WorkspaceId workspaceId;
  final WorkspaceEntryRef file;
  final ByteRange range;
  final OperationBudget budget;
  final ContentRevision? expectedRevision;
}

final class WorkspacePage {
  WorkspacePage(
      {required List<WorkspaceEntry> entries,
      required this.completion,
      required this.consistency,
      required this.usage,
      this.cursor})
      : entries = List.unmodifiable(entries);
  final List<WorkspaceEntry> entries;
  final ListCompletion completion;
  final ListConsistency consistency;
  final BudgetUsage usage;
  final WorkspacePageCursor? cursor;
}

final class WorkspaceRead {
  WorkspaceRead(
      {required Uint8List bytes,
      required this.offset,
      required this.eof,
      required this.actualRevision,
      required this.stability,
      required this.usage,
      this.expectedRevision})
      : _bytes = Uint8List.fromList(bytes),
        sliceSha256 = sha256.convert(bytes).toString();
  final Uint8List _bytes;

  /// A defensive copy of the exact digest-evidenced byte slice.
  Uint8List get bytes => Uint8List.fromList(_bytes);
  final int offset;
  final bool eof;
  final String sliceSha256;
  final ContentRevision? actualRevision;
  final ContentRevision? expectedRevision;
  final RevisionStability stability;
  final BudgetUsage usage;
}

sealed class WorkspaceOutcome<T> {
  const WorkspaceOutcome();
}

final class WorkspaceSuccess<T> extends WorkspaceOutcome<T> {
  const WorkspaceSuccess(this.value);
  final T value;
}

final class WorkspaceFailure<T> extends WorkspaceOutcome<T> {
  const WorkspaceFailure(this.kind, {this.message});
  final WorkspaceFailureKind kind;
  final String? message;
}

enum WorkspaceFailureKind {
  cancelled,
  budgetExceeded,
  invalidReference,
  invalidCursor,
  invalidRequest,
  permissionLost,
  unavailable,
  notFound,
  unsupported,
  providerFailure,
  closed
}

abstract interface class WorkspaceAdapter {
  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(WorkspaceId workspaceId);
  Future<WorkspaceOutcome<WorkspacePage>> list(WorkspaceListRequest request);
  Future<WorkspaceOutcome<WorkspaceRead>> read(WorkspaceReadRequest request);
  Future<void> close();
}

/// Adapter-injected access facade; it has no write, delete, move, or path API.
final class WorkspaceAccess {
  WorkspaceAccess(this._adapter);
  final WorkspaceAdapter _adapter;
  bool _closed = false;
  final Set<Future<void>> _active = <Future<void>>{};
  Future<WorkspaceOutcome<T>> _track<T>(
      Future<WorkspaceOutcome<T>> Function() operation) {
    if (_closed) {
      return Future<WorkspaceOutcome<T>>.value(
          WorkspaceFailure<T>(WorkspaceFailureKind.closed));
    }
    late final Future<void> done;
    final result = operation().then((value) {
      if (_closed) return WorkspaceFailure<T>(WorkspaceFailureKind.closed);
      return value;
    });
    done = result.then<void>((_) {}, onError: (_, __) {});
    _active.add(done);
    done.whenComplete(() => _active.remove(done));
    return result;
  }

  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(
          WorkspaceId workspaceId) =>
      _closed
          ? Future.value(const WorkspaceFailure(WorkspaceFailureKind.closed))
          : _track(() => _adapter.restore(workspaceId));
  Future<WorkspaceOutcome<WorkspacePage>> list(WorkspaceListRequest request) =>
      _closed
          ? Future.value(const WorkspaceFailure(WorkspaceFailureKind.closed))
          : _track(() => _adapter.list(request));
  Future<WorkspaceOutcome<WorkspaceRead>> read(WorkspaceReadRequest request) =>
      _closed
          ? Future.value(const WorkspaceFailure(WorkspaceFailureKind.closed))
          : _track(() => _adapter.read(request));
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      await _adapter.close();
      await Future.wait<void>(_active.toList());
    }
  }
}
