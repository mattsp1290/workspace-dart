part of workspace_flutter;

/// Typed method-channel bridge. Native code owns grant resolution and I/O.
final class MethodChannelWorkspaceBridge implements WorkspacePlatformBridge {
  MethodChannelWorkspaceBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('workspace_flutter/read_only');
  final MethodChannel _channel;
  @override
  Future<WorkspaceOutcome<WorkspaceSelection>> selectDirectory(
    WorkspaceId id,
  ) async {
    try {
      final envelope = await _channel.invokeMethod<Uint8List>(
        'selectDirectory',
        _protocolArguments(<String, Object?>{'workspaceId': id.value}),
      );
      return envelope == null
          ? const WorkspaceFailure(WorkspaceFailureKind.cancelled)
          : WorkspaceSuccess(WorkspaceSelection(envelope));
    } on PlatformException catch (error) {
      return WorkspaceFailure(_failureKind(error.code));
    } on TypeError {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    }
  }

  @override
  Future<WorkspaceOutcome<WorkspaceDirectory>> restore(
    WorkspaceId id,
    Uint8List nativeEnvelope,
  ) async {
    final response = await _call(
      'restore',
      _protocolArguments({'workspaceId': id.value, 'envelope': nativeEnvelope}),
    );
    if (response is WorkspaceFailure<Map<Object?, Object?>>)
      return WorkspaceFailure(response.kind, message: response.message);
    return _directory(
      id,
      (response as WorkspaceSuccess<Map<Object?, Object?>>).value,
    );
  }

  @override
  Future<WorkspaceOutcome<WorkspacePage>> list(
    WorkspaceListRequest request,
    Uint8List nativeEnvelope,
  ) async {
    if (!request.budget.isValid)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidRequest);
    final response = await _operationCall('list', request.budget, {
      'workspaceId': request.workspaceId.value,
      'envelope': nativeEnvelope,
      'directoryId': request.directory.stableId,
      'maxEntries': request.budget.maxEntries,
      'maxBytes': request.budget.maxBytes,
      'cursor': request.cursor?.token,
    });
    if (response is WorkspaceFailure<Map<Object?, Object?>>)
      return WorkspaceFailure(response.kind, message: response.message);
    try {
      final value = (response as WorkspaceSuccess<Map<Object?, Object?>>).value;
      final rawEntries = value['entries'];
      if (rawEntries is! List ||
          value['usedEntries'] is! int ||
          value['usedBytes'] is! int ||
          value['completion'] is! String ||
          value['consistency'] is! String) {
        throw const FormatException('Malformed native list response.');
      }
      final entries = rawEntries
          .map(
            (entry) => _entry(
              request.workspaceId,
              Map<Object?, Object?>.from(entry! as Map),
            ),
          )
          .toList();
      final completion = switch (value['completion']) {
        'hasMore' => ListCompletion.hasMore,
        'budgetExhausted' => ListCompletion.budgetExhausted,
        'complete' => ListCompletion.complete,
        _ => throw const FormatException('Unknown list completion.'),
      };
      final consistency = switch (value['consistency']) {
        'verified' => ListConsistency.verified,
        'changed' => ListConsistency.changed,
        'unverified' => ListConsistency.unverified,
        _ => throw const FormatException('Unknown list consistency.'),
      };
      final cursor = value['cursor'] as String?;
      if ((completion == ListCompletion.hasMore) != (cursor != null) ||
          (cursor != null && !_isOpaqueId(cursor, maxLength: 512)) ||
          entries.length > request.budget.maxEntries ||
          value['usedEntries'] as int != entries.length ||
          value['usedBytes'] as int < 0 ||
          value['usedBytes'] as int > request.budget.maxBytes) {
        throw const FormatException('Invalid native list accounting.');
      }
      return WorkspaceSuccess(
        WorkspacePage(
          entries: entries,
          completion: completion,
          consistency: consistency,
          usage: BudgetUsage(
            entries: value['usedEntries'] as int,
            bytes: value['usedBytes'] as int,
          ),
          cursor: cursor == null
              ? null
              : WorkspacePageCursor(
                  workspaceId: request.workspaceId,
                  token: cursor,
                ),
        ),
      );
    } on FormatException {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    } on TypeError {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    }
  }

  @override
  Future<WorkspaceOutcome<WorkspaceRead>> read(
    WorkspaceReadRequest request,
    Uint8List nativeEnvelope,
  ) async {
    if (!request.budget.isValid || !request.range.isValid)
      return const WorkspaceFailure(WorkspaceFailureKind.invalidRequest);
    final response = await _operationCall('read', request.budget, {
      'workspaceId': request.workspaceId.value,
      'envelope': nativeEnvelope,
      'fileId': request.file.stableId,
      'offset': request.range.offset,
      'count': request.range.count,
      'maxBytes': request.budget.maxBytes,
      'expectedRevision': _revisionToWire(request.expectedRevision),
    });
    if (response is WorkspaceFailure<Map<Object?, Object?>>)
      return WorkspaceFailure(response.kind, message: response.message);
    try {
      final value = (response as WorkspaceSuccess<Map<Object?, Object?>>).value;
      final bytes = value['bytes'] as Uint8List?;
      final offset = value['offset'];
      final eof = value['eof'];
      if (bytes == null ||
          offset is! int ||
          offset < 0 ||
          offset != request.range.offset ||
          eof is! bool ||
          !value.containsKey('actualRevision') ||
          bytes.length > request.range.count ||
          bytes.length > request.budget.maxBytes) {
        throw const FormatException('Malformed native read response.');
      }
      final reportedStability = switch (value['stability']) {
        'verified' => RevisionStability.verified,
        'changed' => RevisionStability.changed,
        'unverified' => RevisionStability.unverified,
        _ => throw const FormatException('Unknown read stability.'),
      };
      final actualRevision = _revisionFromWire(value['actualRevision']);
      final stability = _validatedStability(
        reportedStability,
        actualRevision,
        request.expectedRevision,
      );
      return WorkspaceSuccess(
        WorkspaceRead(
          bytes: bytes,
          offset: offset,
          eof: eof,
          actualRevision: actualRevision,
          expectedRevision: request.expectedRevision,
          stability: stability,
          usage: BudgetUsage(bytes: bytes.length),
        ),
      );
    } on FormatException {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    } on TypeError {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    }
  }

  @override
  Future<void> cancelWorkspace(WorkspaceId id) => _channel.invokeMethod<void>(
    'cancelWorkspace',
    _protocolArguments(<String, Object?>{'workspaceId': id.value}),
  );

  @override
  Future<void> commitSelection(WorkspaceId id) => _channel.invokeMethod<void>(
    'commitSelection',
    _protocolArguments(<String, Object?>{'workspaceId': id.value}),
  );

  @override
  Future<void> abandonSelection(WorkspaceId id) => _channel.invokeMethod<void>(
    'abandonSelection',
    _protocolArguments(<String, Object?>{'workspaceId': id.value}),
  );

  @override
  Future<void> forgetWorkspace(WorkspaceId id) => _channel.invokeMethod<void>(
    'forgetWorkspace',
    _protocolArguments(<String, Object?>{'workspaceId': id.value}),
  );

  @override
  Future<void> reconcileAcquisitions(List<WorkspaceId> activeIds) =>
      _channel.invokeMethod<void>(
        'reconcileAcquisitions',
        _protocolArguments(<String, Object?>{
          'activeWorkspaceIds': activeIds.map((id) => id.value).toList(),
        }),
      );

  Future<WorkspaceOutcome<Map<Object?, Object?>>> _operationCall(
    String method,
    OperationBudget budget,
    Map<String, Object?> arguments,
  ) async {
    if (budget.cancellationToken.isCancelled) {
      return const WorkspaceFailure(WorkspaceFailureKind.cancelled);
    }
    final remainingMillis = budget.deadline
        .difference(DateTime.now())
        .inMilliseconds;
    if (remainingMillis <= 0) {
      return const WorkspaceFailure(WorkspaceFailureKind.budgetExceeded);
    }
    final operationId = _newOperationId();
    var cancelSent = false;
    Future<void> cancel() async {
      if (cancelSent) return;
      cancelSent = true;
      try {
        await _channel.invokeMethod<void>(
          'cancel',
          _protocolArguments(<String, Object?>{'operationId': operationId}),
        );
      } on PlatformException {
        // The primary operation owns the public outcome.
      } on MissingPluginException {
        // Detach can race cancellation; the primary operation still settles.
      }
    }

    final unregister = budget.cancellationToken.register(() {
      unawaited(cancel());
    });
    try {
      final outcome = await _call(
        method,
        _protocolArguments(<String, Object?>{
          ...arguments,
          'operationId': operationId,
          'remainingMillis': remainingMillis.clamp(1, 86400000),
        }),
      );
      return budget.cancellationToken.isCancelled
          ? const WorkspaceFailure(WorkspaceFailureKind.cancelled)
          : outcome;
    } finally {
      unregister();
    }
  }

  Future<WorkspaceOutcome<Map<Object?, Object?>>> _call(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      final response = await _channel.invokeMapMethod<Object?, Object?>(
        method,
        arguments,
      );
      return WorkspaceSuccess(
        Map<Object?, Object?>.from(response ?? const <Object?, Object?>{}),
      );
    } on PlatformException catch (error) {
      return WorkspaceFailure(_failureKind(error.code));
    } on TypeError {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    }
  }

  Map<String, Object?> _protocolArguments(Map<String, Object?> values) =>
      <String, Object?>{'protocolVersion': 1, ...values};

  String _newOperationId() {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final random = Random.secure();
    return List<String>.generate(
      22,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  WorkspaceOutcome<WorkspaceDirectory> _directory(
    WorkspaceId id,
    Map<Object?, Object?> map,
  ) {
    try {
      return WorkspaceSuccess(
        WorkspaceDirectory(
          ref: WorkspaceEntryRef.issued(
            workspaceId: id,
            stableId: map['entryId']! as String,
          ),
          displayPath: WorkspaceDisplayPath(map['name']! as String),
          name: map['name']! as String,
        ),
      );
    } on FormatException {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    } on TypeError {
      return const WorkspaceFailure(WorkspaceFailureKind.providerFailure);
    }
  }

  WorkspaceEntry _entry(WorkspaceId id, Map<Object?, Object?> map) {
    final ref = WorkspaceEntryRef.issued(
      workspaceId: id,
      stableId: map['entryId']! as String,
    );
    final name = map['name']! as String;
    final display = WorkspaceDisplayPath(name);
    return switch (map['type']) {
      'directory' when !map.containsKey('byteLength') => WorkspaceDirectory(
        ref: ref,
        displayPath: display,
        name: name,
      ),
      'file' => WorkspaceFile(
        ref: ref,
        displayPath: display,
        name: name,
        byteLength: _fileByteLength(map['byteLength']),
      ),
      _ => throw const FormatException('Unknown native entry type.'),
    };
  }
}

int _fileByteLength(Object? value) {
  if (value is! int || value < 0) {
    throw const FormatException('Invalid native file length.');
  }
  return value;
}

Map<String, Object?>? _revisionToWire(ContentRevision? revision) =>
    switch (revision) {
      WholeContentSha256(:final value) => <String, Object?>{
        'kind': 'wholeContentSha256',
        'value': value,
      },
      PlatformContentRevision(:final namespace, :final value) =>
        <String, Object?>{
          'kind': 'platform',
          'namespace': namespace,
          'value': value,
        },
      null => null,
    };

ContentRevision? _revisionFromWire(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map) throw const FormatException('Invalid revision evidence.');
  final map = Map<Object?, Object?>.from(raw);
  return switch (map['kind']) {
    'wholeContentSha256' => WholeContentSha256(map['value']! as String),
    'platform' => PlatformContentRevision(
      namespace: map['namespace']! as String,
      value: map['value']! as String,
    ),
    _ => throw const FormatException('Unknown revision evidence.'),
  };
}

RevisionStability _validatedStability(
  RevisionStability reported,
  ContentRevision? actual,
  ContentRevision? expected,
) {
  if (reported == RevisionStability.changed) return RevisionStability.changed;
  if (expected != null) {
    if (actual == null || !expected.isComparableTo(actual)) {
      return RevisionStability.unverified;
    }
    if (expected != actual) return RevisionStability.changed;
  }
  if (reported == RevisionStability.verified && actual == null) {
    return RevisionStability.unverified;
  }
  return reported;
}

WorkspaceFailureKind _failureKind(String code) => switch (code) {
  'cancelled' => WorkspaceFailureKind.cancelled,
  'permissionLost' => WorkspaceFailureKind.permissionLost,
  'unavailable' => WorkspaceFailureKind.unavailable,
  'notFound' => WorkspaceFailureKind.notFound,
  'unsupported' => WorkspaceFailureKind.unsupported,
  'invalidReference' => WorkspaceFailureKind.invalidReference,
  'invalidCursor' => WorkspaceFailureKind.invalidCursor,
  'invalidRequest' => WorkspaceFailureKind.invalidRequest,
  'budgetExceeded' => WorkspaceFailureKind.budgetExceeded,
  'closed' => WorkspaceFailureKind.closed,
  _ => WorkspaceFailureKind.providerFailure,
};

bool _isOpaqueId(String value, {required int maxLength}) =>
    value.isNotEmpty &&
    value.length <= maxLength &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
