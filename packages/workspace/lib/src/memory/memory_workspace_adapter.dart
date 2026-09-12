import 'dart:async';
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
  final Map<String, int> _cursors = {};
  int _nextCursor = 0;
  String get rootToken => _tokenFor(root, '');
  String _tokenFor(MemoryNode node, String path) {
    final token = sha256.convert('$path/${node.name}'.codeUnits).toString();
    _nodes[token] = node;
    return token;
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
    return WorkspaceSuccess(WorkspaceDirectory(
        ref: WorkspaceEntryRef(workspaceId: workspaceId, token: rootToken),
        displayPath: WorkspaceDisplayPath(root.name),
        name: root.name));
  }

  @override
  Future<WorkspaceOutcome<WorkspacePage>> list(
      WorkspaceListRequest request) async {
    request.budget.validate();
    if (_closed ||
        request.budget.isExpired ||
        request.budget.cancellationToken.isCancelled)
      return _stateFailure(request.budget);
    if (request.workspaceId != workspaceId ||
        request.directory.workspaceId != workspaceId)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    if (request.cursor != null && request.cursor!.workspaceId != workspaceId)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidCursor);
    final node = _nodes[request.directory.token] ??
        (request.directory.token == rootToken ? root : null);
    if (node is! MemoryDirectoryNode)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    final start = request.cursor == null
        ? 0
        : _cursors.remove(request.cursor!.token) ?? -1;
    if (start < 0 || start > node.children.length)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidCursor);
    final entries = <WorkspaceEntry>[];
    for (var i = start; i < node.children.length; i++) {
      if (request.budget.cancellationToken.isCancelled)
        return const WorkspaceFailure(WorkspaceFailureKind.cancelled);
      if (entries.length >= request.budget.maxEntries)
        return WorkspaceSuccess(WorkspacePage(
            entries: entries,
            completion: ListCompletion.budgetExhausted,
            consistency: ListConsistency.verified,
            usage: BudgetUsage(entries: entries.length),
            cursor: null));
      final child = node.children[i];
      final token = _tokenFor(child, request.directory.token);
      final ref = WorkspaceEntryRef(workspaceId: workspaceId, token: token);
      final display = WorkspaceDisplayPath(child.name);
      entries.add(child is MemoryFileNode
          ? WorkspaceFile(
              ref: ref,
              displayPath: display,
              name: child.name,
              byteLength: child.bytes.length)
          : WorkspaceDirectory(
              ref: ref, displayPath: display, name: child.name));
      if (entries.length == pageSize && i + 1 < node.children.length) {
        final cursor = 'cursor-${_nextCursor++}';
        _cursors[cursor] = i + 1;
        return WorkspaceSuccess(WorkspacePage(
            entries: entries,
            completion: ListCompletion.hasMore,
            consistency: ListConsistency.verified,
            usage: BudgetUsage(entries: entries.length),
            cursor:
                WorkspacePageCursor(workspaceId: workspaceId, token: cursor)));
      }
    }
    return WorkspaceSuccess(WorkspacePage(
        entries: entries,
        completion: ListCompletion.complete,
        consistency: ListConsistency.verified,
        usage: BudgetUsage(entries: entries.length)));
  }

  @override
  Future<WorkspaceOutcome<WorkspaceRead>> read(
      WorkspaceReadRequest request) async {
    request.budget.validate();
    request.range.validate();
    if (_closed ||
        request.budget.isExpired ||
        request.budget.cancellationToken.isCancelled)
      return _stateFailure(request.budget);
    if (request.workspaceId != workspaceId ||
        request.file.workspaceId != workspaceId)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    final node = _nodes[request.file.token];
    if (node is! MemoryFileNode)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidReference);
    if (request.range.count > request.budget.maxBytes)
      return const WorkspaceFailure(WorkspaceFailureKind.budgetExceeded);
    final start = request.range.offset.clamp(0, node.bytes.length);
    final end = (start + request.range.count).clamp(start, node.bytes.length);
    final bytes = Uint8List.fromList(node.bytes.sublist(start, end));
    final revision = ContentRevision(sha256.convert(node.bytes).toString());
    final stability =
        request.expectedRevision != null && request.expectedRevision != revision
            ? RevisionStability.changed
            : RevisionStability.verified;
    return WorkspaceSuccess(WorkspaceRead(
        bytes: bytes,
        offset: start,
        eof: end == node.bytes.length,
        actualRevision: revision,
        expectedRevision: request.expectedRevision,
        stability: stability));
  }

  @override
  Future<void> close() async {
    _closed = true;
    _nodes.clear();
    _cursors.clear();
  }
}
