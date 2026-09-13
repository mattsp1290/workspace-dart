import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../contracts.dart';
import '../identities.dart';

sealed class MemoryNode {
  MemoryNode(this.name);
  final String name;
}

final class MemoryDirectoryNode extends MemoryNode {
  MemoryDirectoryNode(super.name, [List<MemoryNode>? children])
      : children = children ?? [];
  final List<MemoryNode> children;
}

final class MemoryFileNode extends MemoryNode {
  MemoryFileNode(super.name, List<int> bytes)
      : bytes = Uint8List.fromList(bytes);
  Uint8List bytes;
}

/// Deterministic read-only adapter used for conformance tests and examples.
final class MemoryWorkspaceAdapter implements WorkspaceAdapter {
  MemoryWorkspaceAdapter(
      {required this.workspaceId, required this.root, this.pageSize = 100})
      : assert(pageSize > 0);
  final WorkspaceId workspaceId;
  final MemoryDirectoryNode root;
  final int pageSize;
  bool _closed = false;
  final Map<String, MemoryNode> _nodes = {};
  final Map<String, _CursorState> _cursors = {};
  int _nextCursor = 0;
  String get rootToken => _tokenFor(root, '');
  String _tokenFor(MemoryNode node, String path) {
    final stableId = sha256.convert('$path/${node.name}'.codeUnits).toString();
    _nodes[stableId] = node;
    return stableId;
  }

  bool _isSafeName(String name) {
    try {
      WorkspaceDisplayPath(name);
      return true;
    } on FormatException {
      return false;
    }
  }

  WorkspaceFailure<T> _stateFailure<T>(OperationBudget budget) =>
      WorkspaceFailure(budget.cancellationToken.isCancelled
          ? WorkspaceFailureKind.cancelled
          : budget.isExpired
              ? WorkspaceFailureKind.budgetExceeded
              : WorkspaceFailureKind.closed);
  @override
  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(WorkspaceId id) async {
    if (_closed) return const WorkspaceFailure(WorkspaceFailureKind.closed);
    if (id != workspaceId)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    if (!_isSafeName(root.name))
      return const WorkspaceFailure(WorkspaceFailureKind.invalidRequest);
    return WorkspaceSuccess(WorkspaceDirectory(
        ref: WorkspaceEntryRef.issued(
            workspaceId: workspaceId, stableId: rootToken),
        displayPath: WorkspaceDisplayPath(root.name),
        name: root.name));
  }

  @override
  Future<WorkspaceOutcome<WorkspacePage>> list(
      WorkspaceListRequest request) async {
    if (!request.budget.isValid)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidRequest);
    if (_closed ||
        request.budget.isExpired ||
        request.budget.cancellationToken.isCancelled)
      return _stateFailure(request.budget);
    if (request.workspaceId != workspaceId ||
        request.directory.workspaceId != workspaceId)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    if (request.cursor != null && request.cursor!.workspaceId != workspaceId)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidCursor);
    final node = _nodes[request.directory.stableId] ??
        (request.directory.stableId == rootToken ? root : null);
    if (node is! MemoryDirectoryNode)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    final priorUsage = request.cursor == null
        ? const BudgetUsage()
        : _cursorUsage(request.cursor!, request);
    if (priorUsage == null)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidCursor);
    final start = request.cursor == null
        ? 0
        : _cursors.remove(request.cursor!.token)!.nextIndex;
    if (start < 0 || start > node.children.length)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidCursor);
    final entries = <WorkspaceEntry>[];
    var metadataBytes = 0;
    for (var i = start; i < node.children.length; i++) {
      if (request.budget.cancellationToken.isCancelled)
        return const WorkspaceFailure(WorkspaceFailureKind.cancelled);
      if (priorUsage.entries + entries.length >= request.budget.maxEntries ||
          priorUsage.bytes + metadataBytes >= request.budget.maxBytes) {
        if (entries.isEmpty) {
          return const WorkspaceFailure(WorkspaceFailureKind.budgetExceeded);
        }
        return WorkspaceSuccess(WorkspacePage(
            entries: entries,
            completion: ListCompletion.budgetExhausted,
            consistency: ListConsistency.verified,
            usage:
                priorUsage.add(entries: entries.length, bytes: metadataBytes),
            cursor: null));
      }
      final child = node.children[i];
      if (!_isSafeName(child.name))
        return const WorkspaceFailure(WorkspaceFailureKind.invalidRequest);
      final childMetadataBytes = utf8.encode(child.name).length;
      if (priorUsage.bytes + metadataBytes + childMetadataBytes >
          request.budget.maxBytes) {
        if (entries.isEmpty) {
          return const WorkspaceFailure(WorkspaceFailureKind.budgetExceeded);
        }
        return WorkspaceSuccess(WorkspacePage(
            entries: entries,
            completion: ListCompletion.budgetExhausted,
            consistency: ListConsistency.verified,
            usage:
                priorUsage.add(entries: entries.length, bytes: metadataBytes)));
      }
      final token = _tokenFor(child, request.directory.stableId);
      final ref =
          WorkspaceEntryRef.issued(workspaceId: workspaceId, stableId: token);
      final display = WorkspaceDisplayPath(child.name);
      entries.add(child is MemoryFileNode
          ? WorkspaceFile(
              ref: ref,
              displayPath: display,
              name: child.name,
              byteLength: child.bytes.length)
          : WorkspaceDirectory(
              ref: ref, displayPath: display, name: child.name));
      metadataBytes += childMetadataBytes;
      if (entries.length == pageSize && i + 1 < node.children.length) {
        final cursor = 'cursor-${_nextCursor++}';
        _cursors[cursor] = _CursorState(
            directoryToken: request.directory.stableId,
            nextIndex: i + 1,
            budget: request.budget,
            usage:
                priorUsage.add(entries: entries.length, bytes: metadataBytes));
        return WorkspaceSuccess(WorkspacePage(
            entries: entries,
            completion: ListCompletion.hasMore,
            consistency: ListConsistency.verified,
            usage:
                priorUsage.add(entries: entries.length, bytes: metadataBytes),
            cursor:
                WorkspacePageCursor(workspaceId: workspaceId, token: cursor)));
      }
    }
    return WorkspaceSuccess(WorkspacePage(
        entries: entries,
        completion: ListCompletion.complete,
        consistency: ListConsistency.verified,
        usage: priorUsage.add(entries: entries.length, bytes: metadataBytes)));
  }

  BudgetUsage? _cursorUsage(
      WorkspacePageCursor cursor, WorkspaceListRequest request) {
    final state = _cursors[cursor.token];
    if (state == null ||
        state.directoryToken != request.directory.stableId ||
        state.budget.maxEntries != request.budget.maxEntries ||
        state.budget.maxBytes != request.budget.maxBytes ||
        state.budget.deadline != request.budget.deadline) return null;
    return state.usage;
  }

  @override
  Future<WorkspaceOutcome<WorkspaceRead>> read(
      WorkspaceReadRequest request) async {
    if (!request.budget.isValid || !request.range.isValid)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidRequest);
    if (_closed ||
        request.budget.isExpired ||
        request.budget.cancellationToken.isCancelled)
      return _stateFailure(request.budget);
    if (request.workspaceId != workspaceId ||
        request.file.workspaceId != workspaceId)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    final node = _nodes[request.file.stableId];
    if (node is! MemoryFileNode)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    if (request.range.count > request.budget.maxBytes)
      return const WorkspaceFailure(WorkspaceFailureKind.budgetExceeded);
    final start = request.range.offset.clamp(0, node.bytes.length);
    final end = (start + request.range.count).clamp(start, node.bytes.length);
    final bytes = Uint8List.fromList(node.bytes.sublist(start, end));
    final revision = WholeContentSha256(sha256.convert(node.bytes).toString());
    final expected = request.expectedRevision;
    final stability = expected == null
        ? RevisionStability.verified
        : !expected.isComparableTo(revision)
            ? RevisionStability.unverified
            : expected != revision
                ? RevisionStability.changed
                : RevisionStability.verified;
    return WorkspaceSuccess(WorkspaceRead(
        bytes: bytes,
        offset: start,
        eof: end == node.bytes.length,
        actualRevision: revision,
        expectedRevision: request.expectedRevision,
        stability: stability,
        usage: BudgetUsage(bytes: bytes.length)));
  }

  @override
  Future<void> close() async {
    _closed = true;
    _nodes.clear();
    _cursors.clear();
  }
}

final class _CursorState {
  const _CursorState(
      {required this.directoryToken,
      required this.nextIndex,
      required this.budget,
      required this.usage});
  final String directoryToken;
  final int nextIndex;
  final OperationBudget budget;
  final BudgetUsage usage;
}
