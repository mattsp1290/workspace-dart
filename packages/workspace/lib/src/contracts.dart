import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'identities.dart';

enum ListCompletion { complete, hasMore, budgetExhausted }

enum ListConsistency { verified, changed, unverified }

enum RevisionStability { verified, changed, unverified }

final class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
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
  void validate() {
    if (maxEntries < 0 || maxBytes < 0)
      throw ArgumentError('Budget limits cannot be negative.');
  }
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

final class ContentRevision {
  const ContentRevision(this.value);
  final String value;
  @override
  bool operator ==(Object other) =>
      other is ContentRevision && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

final class ByteRange {
  const ByteRange({required this.offset, required this.count});
  final int offset;
  final int count;
  void validate() {
    if (offset < 0 || count < 0)
      throw ArgumentError('Range values cannot be negative.');
  }
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
  const WorkspacePage(
      {required this.entries,
      required this.completion,
      required this.consistency,
      required this.usage,
      this.cursor});
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
      this.expectedRevision})
      : bytes = Uint8List.fromList(bytes),
        sliceSha256 = sha256.convert(bytes).toString();
  final Uint8List bytes;
  final int offset;
  final bool eof;
  final String sliceSha256;
  final ContentRevision actualRevision;
  final ContentRevision? expectedRevision;
  final RevisionStability stability;
}

sealed class WorkspaceOutcome<T> {
  const WorkspaceOutcome();
}

final class WorkspaceSuccess<T> extends WorkspaceOutcome<T> {
  const WorkspaceSuccess(this.value);
  final T value;
}

final class WorkspaceEmpty<T> extends WorkspaceOutcome<T> {
  const WorkspaceEmpty();
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
  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(
          WorkspaceId workspaceId) =>
      _closed
          ? Future.value(const WorkspaceFailure(WorkspaceFailureKind.closed))
          : _adapter.restore(workspaceId);
  Future<WorkspaceOutcome<WorkspacePage>> list(WorkspaceListRequest request) =>
      _closed
          ? Future.value(const WorkspaceFailure(WorkspaceFailureKind.closed))
          : _adapter.list(request);
  Future<WorkspaceOutcome<WorkspaceRead>> read(WorkspaceReadRequest request) =>
      _closed
          ? Future.value(const WorkspaceFailure(WorkspaceFailureKind.closed))
          : _adapter.read(request);
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      await _adapter.close();
    }
  }
}
