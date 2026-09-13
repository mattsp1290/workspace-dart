/// App-owned logical identity. It is not a native authority or a path.
final class WorkspaceId {
  WorkspaceId(String value) : value = _validated(value, 'workspace id');
  final String value;
  @override
  bool operator ==(Object other) =>
      other is WorkspaceId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => 'WorkspaceId($value)';
}

/// Opaque, workspace-bound entry identity. The token is deliberately not a path.
final class WorkspaceEntryRef {
  WorkspaceEntryRef.issued(
      {required this.workspaceId, required String stableId})
      : stableId = _validatedStableId(stableId);

  factory WorkspaceEntryRef.parse(String serialized) {
    final parts = serialized.split(':');
    if (parts.length != 3 || parts.first != 'v1') {
      throw const FormatException('Unsupported workspace entry reference.');
    }
    return WorkspaceEntryRef.issued(
      workspaceId: WorkspaceId(Uri.decodeComponent(parts[1])),
      stableId: parts[2],
    );
  }

  final WorkspaceId workspaceId;
  final String stableId;

  String serialize() =>
      'v1:${Uri.encodeComponent(workspaceId.value)}:$stableId';

  @override
  bool operator ==(Object other) =>
      other is WorkspaceEntryRef &&
      other.workspaceId == workspaceId &&
      other.stableId == stableId;
  @override
  int get hashCode => Object.hash(workspaceId, stableId);
  @override
  String toString() => 'WorkspaceEntryRef(${workspaceId.value}, <opaque>)';
}

String _validatedStableId(String value) {
  if (value.isEmpty ||
      value.length > 512 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid entry stable id.');
  }
  return value;
}

/// Presentation-only relative display metadata, never authority to open an entry.
final class WorkspaceDisplayPath {
  WorkspaceDisplayPath(String value) : value = _displayPath(value);
  final String value;
  @override
  bool operator ==(Object other) =>
      other is WorkspaceDisplayPath && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

String _validated(String value, String label) {
  if (value.isEmpty || value.length > 512 || value.contains('\u0000')) {
    throw FormatException('Invalid $label.');
  }
  return value;
}

String _displayPath(String value) {
  if (value.isEmpty ||
      value.length > 4096 ||
      value.contains('\u0000') ||
      value.startsWith('/') ||
      value.startsWith('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value)) {
    throw FormatException('Display paths must be relative and unambiguous.');
  }
  final parts = value.split('/');
  if (parts.any((part) =>
      part.isEmpty || part == '.' || part == '..' || part.contains('\\'))) {
    throw FormatException(
        'Display paths may not contain traversal or mixed separators.');
  }
  return value;
}
