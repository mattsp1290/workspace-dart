import Flutter
import UIKit
import CryptoKit

private struct WorkspaceListSnapshot {
  let workspaceId: String
  let directoryId: String
  let rows: [[String: Any]]
  let nextIndex: Int
  let expiry: TimeInterval
  let maxEntries: Int
  let maxBytes: Int
}

private struct PendingWorkspacePicker {
  let workspaceId: String
  let result: FlutterResult
}

public final class WorkspaceFlutterPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private var channel: FlutterMethodChannel!
  private var pendingPicker: PendingWorkspacePicker?
  private let operationLock = NSLock()
  // Provider enumeration stays outside this lock. It protects the private
  // lineage read/issue/write transaction against concurrent list operations.
  private let entryStateLock = NSLock()
  private let operationEngine = WorkspaceOperationEngine()
  private var cursors: [String: WorkspaceListSnapshot] = [:]
  private let bookmarkProvider: IOSBookmarkProvider
  private let workspaceStore: IOSWorkspaceStore

  /// Constructor used by Flutter's generated plugin registrant.
  public override init() {
#if WORKSPACE_NATIVE_TEST_FIXTURE
    bookmarkProvider = NativeTestBookmarkProvider()
#else
    bookmarkProvider = FoundationIOSBookmarkProvider()
#endif
    workspaceStore = UserDefaultsIOSWorkspaceStore()
    super.init()
  }

  /// XCTest can inject a scope-counting provider without exposing it through
  /// the public Flutter channel API.
  internal init(bookmarkProvider: IOSBookmarkProvider) {
    self.bookmarkProvider = bookmarkProvider
    workspaceStore = UserDefaultsIOSWorkspaceStore()
    super.init()
  }

  internal init(bookmarkProvider: IOSBookmarkProvider, workspaceStore: IOSWorkspaceStore) {
    self.bookmarkProvider = bookmarkProvider
    self.workspaceStore = workspaceStore
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = WorkspaceFlutterPlugin()
    instance.channel = FlutterMethodChannel(
      name: "workspace_flutter/read_only",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: instance.channel)
    // Publishing opts into Flutter's explicit engine-detach callback.
    registrar.publish(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    operationLock.lock()
    cursors.removeAll()
    operationLock.unlock()
    operationEngine.detach()
    pendingPicker?.result(error("cancelled"))
    pendingPicker = nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "selectDirectory": select(call, result: result)
    case "restore": restore(call, result: result)
    case "list": list(call, result: result)
    case "read": read(call, result: result)
    case "cancel": cancel(call, result: result)
    case "cancelWorkspace": cancelWorkspace(call, result: result)
    case "commitSelection", "abandonSelection": lifecycle(call, result: result)
    case "forgetWorkspace": forgetWorkspace(call, result: result)
    case "reconcileAcquisitions": reconcileAcquisitions(call, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func select(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let values = arguments(call),
          WorkspaceProtocol.hasVersion(values),
          WorkspaceProtocol.hasExactKeys(values, ["protocolVersion", "workspaceId"]),
          let workspaceId = WorkspaceProtocol.workspaceID(values["workspaceId"]) else {
      result(error("invalidRequest"))
      return
    }
    guard pendingPicker == nil else {
      result(error("providerFailure"))
      return
    }
    guard let controller = topController() else {
      result(error("unsupported"))
      return
    }
    pendingPicker = PendingWorkspacePicker(workspaceId: workspaceId, result: result)
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.folder],
      asCopy: false
    )
    picker.allowsMultipleSelection = false
    picker.delegate = self
    controller.present(picker, animated: true)
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPicker?.result(nil)
    pendingPicker = nil
  }

  public func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    // UIKit may deliver a dismissal/result callback after final detach or a
    // prior cancellation. It no longer belongs to an outstanding channel
    // request and must not resurrect state or force-unwrap a missing picker.
    guard let pending = pendingPicker else { return }
    defer { pendingPicker = nil }
    guard let url = urls.first else {
      pending.result(nil)
      return
    }
    do {
      guard bookmarkProvider.startAccessing(url) else {
        pending.result(self.error("permissionLost"))
        return
      }
      defer { bookmarkProvider.stopAccessing(url) }
      guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        pending.result(self.error("unsupported"))
        return
      }
      let bookmark = try url.bookmarkData(
        options: [.minimalBookmark],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      let rootID = self.randomOpaqueID()
      let vault = IOSVaultEnvelope(
        bookmark: bookmark,
        generation: UInt64.random(in: 1...UInt64(Int64.max)),
        rootID: rootID,
        rootDigest: self.rootDigest(url)
      )
      self.entryStateLock.lock()
      defer { self.entryStateLock.unlock() }
      guard self.bindRoot(workspaceId: pending.workspaceId, root: url, vault: vault, phase: "pending") else {
        pending.result(self.error("invalidReference"))
        return
      }
      var mappings: [String: IOSLineageRecord] = [:]
      let issuedRootID = self.issueEntryId(
        workspaceId: pending.workspaceId,
        parentID: nil,
        relativePath: "",
        preferredID: rootID,
        additions: &mappings
      )
      guard issuedRootID == rootID else {
        _ = self.workspaceStore.removeWorkspace(pending.workspaceId)
        pending.result(self.error("permissionLost"))
        return
      }
      guard self.commitMappings(workspaceId: pending.workspaceId, additions: mappings) else {
        _ = self.workspaceStore.removeWorkspace(pending.workspaceId)
        pending.result(self.error("providerFailure"))
        return
      }
      guard let envelope = WorkspaceProtocol.iOSEnvelope(
        bookmark: vault.bookmark,
        generation: vault.generation,
        rootID: vault.rootID,
        rootDigest: vault.rootDigest
      ) else {
        _ = self.workspaceStore.removeWorkspace(pending.workspaceId)
        pending.result(self.error("providerFailure"))
        return
      }
      pending.result(FlutterStandardTypedData(bytes: envelope))
    } catch {
      pending.result(self.error("providerFailure"))
    }
  }

  private func restore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = arguments(call),
          WorkspaceProtocol.hasVersion(arguments),
          WorkspaceProtocol.hasExactKeys(arguments, ["protocolVersion", "workspaceId", "envelope"]),
          let workspaceId = WorkspaceProtocol.workspaceID(arguments["workspaceId"]) else {
      result(error("invalidRequest"))
      return
    }
    withRoot(arguments, result: result) { root, vault in
      try self.withEntryStateLock {
        guard self.bindRoot(workspaceId: workspaceId, root: root, vault: vault, phase: "active") else {
          throw WorkspaceNativeError.invalidReference
        }
        var mappings: [String: IOSLineageRecord] = [:]
        let rootId = self.issueEntryId(
          workspaceId: workspaceId, parentID: nil, relativePath: "", preferredID: vault.rootID, additions: &mappings
        )
        guard rootId == vault.rootID else { throw WorkspaceNativeError.permissionLost }
        guard self.commitMappings(workspaceId: workspaceId, additions: mappings) else {
          throw WorkspaceNativeError.providerFailure
        }
        return [
          "entryId": rootId,
          "name": root.lastPathComponent.isEmpty ? "workspace" : root.lastPathComponent,
        ]
      }
    }
  }

  private func list(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = operationArguments(call),
          WorkspaceProtocol.hasExactKeys(arguments, [
            "protocolVersion", "workspaceId", "envelope", "directoryId", "maxEntries", "maxBytes", "cursor",
            "operationId", "remainingMillis",
          ]),
          let workspaceId = arguments["workspaceId"] as? String,
          let directoryId = WorkspaceProtocol.stableID(arguments["directoryId"]),
          let maxEntries = WorkspaceProtocol.boundedInt(
            arguments["maxEntries"], minimum: 0, maximum: 1_000
          ),
          let maxBytes = WorkspaceProtocol.boundedInt(
            arguments["maxBytes"], minimum: 0, maximum: 8 * 1024 * 1024
          ) else {
      result(error("invalidRequest"))
      return
    }
    guard workspaceStore.rootRecord(workspaceId: workspaceId)?.phase == "active" else {
      result(error("permissionLost"))
      return
    }
    guard let relativeDirectory = resolveEntry(
      workspaceId: workspaceId,
      stableId: directoryId
    ) else {
      result(error("invalidReference"))
      return
    }
    let rawCursor = arguments["cursor"]
    let cursorToken = rawCursor as? String
    guard rawCursor == nil || rawCursor is NSNull || WorkspaceProtocol.stableID(cursorToken) != nil else {
      result(error("invalidRequest"))
      return
    }
    runOperation(arguments, result: result) { operation, root, deadline in
      try self.bookmarkProvider.beforeList(root) { operation.isCancelled() }
      guard self.matchesRoot(workspaceId: workspaceId, root: root) else {
        throw WorkspaceNativeError.invalidReference
      }
      if let cursorToken {
        return try self.resumePage(
          cursorToken: cursorToken, workspaceId: workspaceId, directoryId: directoryId,
          maxEntries: maxEntries, maxBytes: maxBytes, deadline: deadline
        )
      }
      let directory = try self.validatedDescendant(
        root: root,
        relativePath: relativeDirectory
      )
      var coordinationError: NSError?
      var output: Any?
      operation.coordinator.coordinate(
        readingItemAt: directory,
        options: [],
        error: &coordinationError
      ) { coordinatedDirectory in
        do {
          let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
          ]
          guard let iterator = FileManager.default.enumerator(
            at: coordinatedDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants]
          ) else { throw WorkspaceNativeError.unavailable }
          var rows: [[String: Any]] = []
          var snapshotBytes = 0
          while let child = iterator.nextObject() as? URL {
            if operation.isCancelled() { throw WorkspaceNativeError.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline {
              throw WorkspaceNativeError.budgetExceeded
            }
            if rows.count >= 1_000 { throw WorkspaceNativeError.unsupported }
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            let safeChild = try self.validatedURL(root: root, candidate: child)
            guard self.isSafeDisplayName(safeChild.lastPathComponent) else { continue }
            let relative = try self.relativePath(root: root, child: safeChild)
            let metadataBytes = safeChild.lastPathComponent.lengthOfBytes(using: .utf8)
            if snapshotBytes + metadataBytes > 8 * 1024 * 1024 {
              throw WorkspaceNativeError.unsupported
            }
            if values.isDirectory != true && (values.fileSize == nil || values.fileSize! < 0) {
              // A missing provider size is not evidence of an empty file.
              throw WorkspaceNativeError.unsupported
            }
            var row: [String: Any] = [
              "name": safeChild.lastPathComponent,
              "type": values.isDirectory == true ? "directory" : "file",
              "_lineage": relative,
            ]
            if values.isDirectory != true { row["byteLength"] = values.fileSize! }
            rows.append(row)
            snapshotBytes += metadataBytes
          }
          self.entryStateLock.lock()
          do {
            defer { self.entryStateLock.unlock() }
            var mappings: [String: IOSLineageRecord] = [:]
            for index in rows.indices {
              guard let relative = rows[index]["_lineage"] as? String else {
                throw WorkspaceNativeError.providerFailure
              }
              rows[index]["entryId"] = self.issueEntryId(
                workspaceId: workspaceId, parentID: directoryId,
                relativePath: relative, additions: &mappings
              )
            }
            guard self.commitMappings(workspaceId: workspaceId, additions: mappings) else {
              throw WorkspaceNativeError.providerFailure
            }
          }
          // Directory enumerators have no ordering guarantee. Sort on private
          // lineage before creating a cursor, then strip it from the wire row.
          rows.sort {
            (($0["_lineage"] as? String) ?? "").utf8.lexicographicallyPrecedes(
              (($1["_lineage"] as? String) ?? "").utf8
            )
          }
          let publicRows = rows.map { row -> [String: Any] in
            var publicRow = row
            publicRow.removeValue(forKey: "_lineage")
            return publicRow
          }
          output = try self.pageFromSnapshot(
            workspaceId: workspaceId, directoryId: directoryId, rows: publicRows, startIndex: 0,
            maxEntries: maxEntries, maxBytes: maxBytes, expiry: deadline
          )
        } catch {
          output = self.flutterError(error)
        }
      }
      if let coordinationError { throw coordinationError }
      if let flutterError = output as? FlutterError {
        throw WorkspaceNativeError.wrapped(flutterError)
      }
      return output ?? [String: Any]()
    }
  }

  private func read(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = operationArguments(call),
          WorkspaceProtocol.hasExactKeys(arguments, [
            "protocolVersion", "workspaceId", "envelope", "fileId", "offset", "count", "maxBytes",
            "expectedRevision", "operationId", "remainingMillis",
          ]),
          let workspaceId = arguments["workspaceId"] as? String,
          let fileId = WorkspaceProtocol.stableID(arguments["fileId"]),
          let offset = WorkspaceProtocol.nonNegativeInt64(arguments["offset"]),
          let count = WorkspaceProtocol.boundedInt(
            arguments["count"], minimum: 0, maximum: 8 * 1024 * 1024
          ),
          let maxBytes = WorkspaceProtocol.boundedInt(
            arguments["maxBytes"], minimum: 0, maximum: 8 * 1024 * 1024
          ), offset <= Int64.max - Int64(count), count <= maxBytes,
          self.validExpectedRevision(arguments["expectedRevision"]) else {
      result(error("invalidRequest"))
      return
    }
    guard workspaceStore.rootRecord(workspaceId: workspaceId)?.phase == "active" else {
      result(error("permissionLost"))
      return
    }
    guard let relativeFile = resolveEntry(workspaceId: workspaceId, stableId: fileId) else {
      result(error("invalidReference"))
      return
    }
    runOperation(arguments, result: result) { operation, root, deadline in
      try self.bookmarkProvider.beforeRead(root) { operation.isCancelled() }
      guard self.matchesRoot(workspaceId: workspaceId, root: root) else {
        throw WorkspaceNativeError.invalidReference
      }
      let file = try self.validatedDescendant(root: root, relativePath: relativeFile)
      if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        throw WorkspaceNativeError.unsupported
      }
      var coordinationError: NSError?
      var output: Any?
      operation.coordinator.coordinate(readingItemAt: file, options: [], error: &coordinationError) {
        coordinatedFile in
        do {
          if operation.isCancelled() { throw WorkspaceNativeError.cancelled }
          if ProcessInfo.processInfo.systemUptime >= deadline {
            throw WorkspaceNativeError.budgetExceeded
          }
          let handle = try FileHandle(forReadingFrom: coordinatedFile)
          defer { try? handle.close() }
          try handle.seek(toOffset: UInt64(offset))
          let data = handle.readData(ofLength: count)
          let size = try coordinatedFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          output = [
            "bytes": FlutterStandardTypedData(bytes: data),
            "offset": offset,
            "eof": offset + Int64(data.count) >= Int64(size),
            "actualRevision": NSNull(),
            "stability": "unverified",
          ]
        } catch {
          output = self.flutterError(error)
        }
      }
      if let coordinationError { throw coordinationError }
      if let flutterError = output as? FlutterError {
        throw WorkspaceNativeError.wrapped(flutterError)
      }
      return output ?? [String: Any]()
    }
  }

  private func resumePage(
    cursorToken: String,
    workspaceId: String,
    directoryId: String,
    maxEntries: Int,
    maxBytes: Int,
    deadline: TimeInterval
  ) throws -> [String: Any] {
    guard cursorToken.range(of: "^[A-Za-z0-9_-]{1,512}$", options: .regularExpression) != nil else {
      throw WorkspaceNativeError.invalidCursor
    }
    operationLock.lock()
    let snapshot = cursors.removeValue(forKey: cursorToken)
    operationLock.unlock()
    guard let snapshot,
          snapshot.workspaceId == workspaceId,
          snapshot.directoryId == directoryId,
          snapshot.maxEntries == maxEntries,
          snapshot.maxBytes == maxBytes,
          ProcessInfo.processInfo.systemUptime < snapshot.expiry,
          ProcessInfo.processInfo.systemUptime < deadline else { throw WorkspaceNativeError.invalidCursor }
    return try pageFromSnapshot(
      workspaceId: workspaceId, directoryId: directoryId, rows: snapshot.rows,
      startIndex: snapshot.nextIndex, maxEntries: maxEntries, maxBytes: maxBytes,
      expiry: snapshot.expiry
    )
  }

  private func pageFromSnapshot(
    workspaceId: String,
    directoryId: String,
    rows: [[String: Any]],
    startIndex: Int,
    maxEntries: Int,
    maxBytes: Int,
    expiry: TimeInterval
  ) throws -> [String: Any] {
    var next = startIndex
    var usedBytes = 0
    var page: [[String: Any]] = []
    while next < rows.count && page.count < maxEntries {
      let row = rows[next]
      guard let name = row["name"] as? String else { throw WorkspaceNativeError.providerFailure }
      let bytes = name.lengthOfBytes(using: .utf8)
      if usedBytes + bytes > maxBytes { break }
      page.append(row)
      usedBytes += bytes
      next += 1
    }
    if next == startIndex && next < rows.count { throw WorkspaceNativeError.budgetExceeded }
    let cursor: String? = next < rows.count ? randomOpaqueID() : nil
    if let cursor {
      operationLock.lock()
      guard !operationEngine.isWorkspaceClosing(workspaceId) else {
        operationLock.unlock()
        throw WorkspaceNativeError.closed
      }
      cursors[cursor] = WorkspaceListSnapshot(
        workspaceId: workspaceId, directoryId: directoryId, rows: rows,
        nextIndex: next, expiry: expiry, maxEntries: maxEntries, maxBytes: maxBytes
      )
      operationLock.unlock()
    }
    return [
      "entries": page,
      "completion": cursor == nil ? "complete" : "hasMore",
      "consistency": "unverified",
      "usedEntries": page.count,
      "usedBytes": usedBytes,
      "cursor": cursor as Any,
    ]
  }

  private func runOperation(
    _ arguments: [String: Any],
    result: @escaping FlutterResult,
    body: @escaping (WorkspaceNativeOperation, URL, TimeInterval) throws -> Any
  ) {
    guard WorkspaceProtocol.hasVersion(arguments),
          let operationId = WorkspaceProtocol.operationID(arguments["operationId"]),
          let workspaceId = WorkspaceProtocol.workspaceID(arguments["workspaceId"]),
          let remainingMillis = WorkspaceProtocol.remainingMillis(arguments["remainingMillis"]) else {
      result(error("invalidRequest"))
      return
    }
    guard operationEngine.run(
      operationId: operationId,
      workspaceId: workspaceId,
      remainingMillis: remainingMillis,
      settle: { _, terminal in
        switch terminal {
        case let .success(value): result(value)
        case let .failure(error):
          if let terminalError = error as? WorkspaceTerminalFailure {
            result(self.error(terminalError.code))
          } else {
            result(self.flutterError(error))
          }
        }
      },
      body: { operation, deadline in
        try self.withRootSync(arguments, requiresExistingRoot: true) { root, _ in
          try body(operation, root, deadline)
        }
      }
    ) else {
      result(error(operationEngine.isWorkspaceClosing(workspaceId) ? "closed" : "invalidRequest"))
      return
    }
  }

  private func cancel(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let values = arguments(call), WorkspaceProtocol.hasVersion(values),
          WorkspaceProtocol.hasExactKeys(values, ["protocolVersion", "operationId"]),
          let operationId = WorkspaceProtocol.operationID(values["operationId"]) else {
      result(error("invalidRequest"))
      return
    }
    operationEngine.cancel(operationId)
    result(nil)
  }

  private func cancelWorkspace(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let values = arguments(call), WorkspaceProtocol.hasVersion(values),
          WorkspaceProtocol.hasExactKeys(values, ["protocolVersion", "workspaceId"]),
          let workspaceId = WorkspaceProtocol.workspaceID(values["workspaceId"]) else {
      result(error("invalidRequest"))
      return
    }
    operationLock.lock()
    cursors = cursors.filter { $0.value.workspaceId != workspaceId }
    let pending = pendingPicker?.workspaceId == workspaceId ? pendingPicker : nil
    if pending != nil { pendingPicker = nil }
    operationLock.unlock()
    operationEngine.closeWorkspace(workspaceId)
    pending?.result(error("cancelled"))
    // The result is a cleanup barrier, not merely a cancellation request.
    operationEngine.afterWorkspaceCleanup(workspaceId) {
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func forgetWorkspace(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let values = arguments(call), WorkspaceProtocol.hasVersion(values),
          WorkspaceProtocol.hasExactKeys(values, ["protocolVersion", "workspaceId"]),
          let workspaceId = WorkspaceProtocol.workspaceID(values["workspaceId"]) else {
      result(error("invalidRequest"))
      return
    }
    operationLock.lock()
    cursors = cursors.filter { $0.value.workspaceId != workspaceId }
    let pending = pendingPicker?.workspaceId == workspaceId ? pendingPicker : nil
    if pending != nil { pendingPicker = nil }
    operationLock.unlock()
    operationEngine.closeWorkspace(workspaceId)
    pending?.result(error("cancelled"))
    // Like close, forget is a cleanup barrier. Do not erase lineage while an
    // already-started coordinator can still access it.
    operationEngine.afterWorkspaceCleanup(workspaceId) {
      let saved = self.workspaceStore.removeWorkspace(workspaceId)
      DispatchQueue.main.async { result(saved ? nil : self.error("providerFailure")) }
    }
  }

  private func reconcileAcquisitions(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let values = arguments(call), WorkspaceProtocol.hasVersion(values),
          WorkspaceProtocol.hasExactKeys(values, ["protocolVersion", "activeWorkspaceIds"]),
          let rawIDs = values["activeWorkspaceIds"] as? [String],
          rawIDs.allSatisfy({ WorkspaceProtocol.workspaceID($0) != nil }) else {
      result(error("invalidRequest"))
      return
    }
    let activeIds = Set(rawIDs)
    for workspaceId in workspaceStore.storedWorkspaceIDs() {
      if activeIds.contains(workspaceId) {
        guard workspaceStore.promoteRoot(workspaceId: workspaceId) else {
          result(error("providerFailure"))
          return
        }
      } else if !workspaceStore.removeWorkspace(workspaceId) {
        result(error("providerFailure"))
        return
      }
    }
    result(nil)
  }

  private func lifecycle(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let values = arguments(call), WorkspaceProtocol.hasVersion(values),
          WorkspaceProtocol.hasExactKeys(values, ["protocolVersion", "workspaceId"]),
          let workspaceId = WorkspaceProtocol.workspaceID(values["workspaceId"]) else {
      result(error("invalidRequest"))
      return
    }
    if call.method == "abandonSelection" {
      guard workspaceStore.removeWorkspace(workspaceId) else {
        result(error("providerFailure"))
        return
      }
    } else if !workspaceStore.promoteRoot(workspaceId: workspaceId) {
      result(error("providerFailure"))
      return
    }
    result(nil)
  }

  private func withRoot(
    _ arguments: [String: Any],
    result: @escaping FlutterResult,
    body: (URL, IOSVaultEnvelope) throws -> Any
  ) {
    do { result(try withRootSync(arguments, body: body)) }
    catch { result(flutterError(error)) }
  }

  private func withRootSync<T>(
    _ arguments: [String: Any],
    requiresExistingRoot: Bool = false,
    body: (URL, IOSVaultEnvelope) throws -> T
  ) throws -> T {
    guard let workspaceID = WorkspaceProtocol.workspaceID(arguments["workspaceId"]),
          let typedData = arguments["envelope"] as? FlutterStandardTypedData,
          !typedData.data.isEmpty,
          typedData.data.count <= WorkspaceProtocol.maxEnvelopeBytes else {
      throw WorkspaceNativeError.invalidRequest
    }
    guard let vaultEnvelope = WorkspaceProtocol.iOSVaultEnvelope(fromEnvelope: typedData.data) else {
      throw WorkspaceNativeError.invalidRequest
    }
    do {
      return try IOSRootAccess.withRoot(bookmark: vaultEnvelope.bookmark, provider: bookmarkProvider) { root in
        // Path-only prototype records have no parent/generation schema and
        // cannot be safely interpreted as v1 authority. Delete them and make
        // the host reselect rather than manufacturing a new root around them.
        guard self.workspaceStore.records(workspaceId: workspaceID) != nil else {
          _ = self.workspaceStore.removeWorkspace(workspaceID)
          throw WorkspaceNativeError.permissionLost
        }
        if let record = self.workspaceStore.rootRecord(workspaceId: workspaceID) {
          guard record.identity == self.normalizedRootIdentity(root),
                record.generation == vaultEnvelope.generation,
                record.rootID == vaultEnvelope.rootID,
                record.digest == vaultEnvelope.rootDigest,
                vaultEnvelope.rootDigest == self.rootDigest(root),
                !requiresExistingRoot || record.phase == "active" else {
            throw WorkspaceNativeError.permissionLost
          }
        } else {
          if self.workspaceStore.hasRootState(workspaceId: workspaceID) {
            _ = self.workspaceStore.removeWorkspace(workspaceID)
            throw WorkspaceNativeError.permissionLost
          }
          if requiresExistingRoot { throw WorkspaceNativeError.permissionLost }
        }
        return try body(root, vaultEnvelope)
      }
    } catch IOSRootAccessError.invalidBookmark {
      throw WorkspaceNativeError.invalidRequest
    } catch IOSRootAccessError.permissionLost {
      throw WorkspaceNativeError.permissionLost
    } catch {
      throw error
    }
  }

  private func validatedDescendant(root: URL, relativePath: String) throws -> URL {
    guard let components = WorkspaceLineage.components(relativePath) else {
      throw WorkspaceNativeError.invalidReference
    }
    var candidate = root
    for component in components {
      candidate.appendPathComponent(String(component), isDirectory: false)
      if try candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        throw WorkspaceNativeError.invalidReference
      }
    }
    return try validatedURL(root: root, candidate: candidate)
  }

  private func validatedURL(root: URL, candidate: URL) throws -> URL {
    let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else { throw WorkspaceNativeError.invalidReference }
    let safeRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let safeCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    let rootComponents = safeRoot.pathComponents
    let candidateComponents = safeCandidate.pathComponents
    guard candidateComponents.count >= rootComponents.count,
          zip(rootComponents, candidateComponents).allSatisfy({ $0 == $1 }) else {
      throw WorkspaceNativeError.invalidReference
    }
    return safeCandidate
  }

  private func relativePath(root: URL, child: URL) throws -> String {
    let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let childComponents = child.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    guard childComponents.count >= rootComponents.count,
          zip(rootComponents, childComponents).allSatisfy({ $0 == $1 }) else {
      throw WorkspaceNativeError.invalidReference
    }
    return childComponents.dropFirst(rootComponents.count).joined(separator: "/")
  }

  private func validExpectedRevision(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return true }
    guard let revision = value as? [String: Any],
          let kind = revision["kind"] as? String,
          let revisionValue = revision["value"] as? String,
          !revisionValue.isEmpty,
          revisionValue.lengthOfBytes(using: .utf8) <= 4_096,
          !revisionValue.contains("\0") else { return false }
    switch kind {
    case "wholeContentSha256":
      return revision.count == 2 &&
        revisionValue.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    case "platform":
      guard let namespace = revision["namespace"] as? String,
            !namespace.isEmpty,
            namespace.utf8.count <= 128,
            namespace.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
        return false
      }
      return revision.count == 3
    default:
      return false
    }
  }

  /// Entry IDs are random public references. Their provider-relative lineage
  /// remains only in the workspace-private mapping.
  private func issueEntryId(
    workspaceId: String,
    parentID: String?,
    relativePath: String,
    preferredID: String? = nil,
    additions: inout [String: IOSLineageRecord]
  ) -> String {
    if let existing = additions.first(where: {
      $0.value.parentID == parentID && $0.value.relativePath == relativePath
    })?.key {
      return existing
    }
    if let existing = workspaceStore.records(workspaceId: workspaceId)?
      .first(where: { $0.value.parentID == parentID && $0.value.relativePath == relativePath })?.key {
      return existing
    }
    let id = preferredID ?? randomOpaqueID()
    additions[id] = IOSLineageRecord(parentID: parentID, relativePath: relativePath)
    return id
  }

  private func withEntryStateLock<T>(_ body: () throws -> T) rethrows -> T {
    entryStateLock.lock()
    defer { entryStateLock.unlock() }
    return try body()
  }

  private func randomOpaqueID() -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    var generator = SystemRandomNumberGenerator()
    return String((0..<22).map { _ in alphabet.randomElement(using: &generator)! })
  }

  private func isSafeDisplayName(_ name: String) -> Bool {
    guard !name.isEmpty,
          name.lengthOfBytes(using: .utf8) <= 4_096,
          !name.contains("\0"),
          !name.hasPrefix("/"),
          !name.hasPrefix("\\"),
          !name.contains("\\"),
          name != ".", name != ".." else { return false }
    return name.range(of: "^[A-Za-z]:", options: .regularExpression) == nil
  }

  private func normalizedRootIdentity(_ root: URL) -> String {
    root.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private func rootDigest(_ root: URL) -> Data {
    Data(SHA256.hash(data: Data(normalizedRootIdentity(root).utf8)))
  }

  private func bindRoot(workspaceId: String, root: URL, vault: IOSVaultEnvelope, phase: String) -> Bool {
    guard vault.rootDigest == rootDigest(root) else { return false }
    let expected = IOSRootRecord(
      identity: normalizedRootIdentity(root), generation: vault.generation, rootID: vault.rootID,
      digest: vault.rootDigest, phase: phase
    )
    guard let existing = workspaceStore.rootRecord(workspaceId: workspaceId) else {
      guard !workspaceStore.hasRootState(workspaceId: workspaceId) else { return false }
      return workspaceStore.saveRootRecord(expected, workspaceId: workspaceId)
    }
    return existing.identity == expected.identity && existing.generation == expected.generation &&
      existing.rootID == expected.rootID && existing.digest == expected.digest &&
      (existing.phase == expected.phase || (expected.phase == "active" && existing.phase == "pending"))
  }

  private func matchesRoot(workspaceId: String, root: URL) -> Bool {
    workspaceStore.rootRecord(workspaceId: workspaceId)?.identity == normalizedRootIdentity(root)
  }

  private func resolveEntry(workspaceId: String, stableId: String) -> String? {
    guard stableId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
      return nil
    }
    guard let records = workspaceStore.records(workspaceId: workspaceId),
          let requested = records[stableId],
          WorkspaceLineage.components(requested.relativePath) != nil else {
      return nil
    }
    var currentID: String? = stableId
    var current = requested
    var seen = Set<String>()
    for _ in 0..<256 {
      guard let id = currentID, seen.insert(id).inserted,
            WorkspaceLineage.components(current.relativePath) != nil else { return nil }
      guard let parentID = current.parentID else {
        return current.relativePath.isEmpty ? requested.relativePath : nil
      }
      guard let parent = records[parentID],
            current.relativePath.hasPrefix(
              parent.relativePath.isEmpty ? "" : parent.relativePath + "/"
            ), current.relativePath != parent.relativePath else { return nil }
      currentID = parentID
      current = parent
    }
    return nil
  }

  private func commitMappings(workspaceId: String, additions: [String: IOSLineageRecord]) -> Bool {
    guard var mappings = workspaceStore.records(workspaceId: workspaceId) else { return false }
    additions.forEach { mappings[$0.key] = $0.value }
    guard mappings.count <= 100_000,
          entryStoreBytes(workspaceId: workspaceId, mappings: mappings) <= 16 * 1024 * 1024 else {
      return false
    }
    return workspaceStore.saveRecords(mappings, workspaceId: workspaceId)
  }

  private func entryStoreBytes(workspaceId: String, mappings: [String: IOSLineageRecord]) -> Int {
    let workspaceBytes = workspaceId.lengthOfBytes(using: .utf8)
    return mappings.reduce(0) { total, record in
      total + workspaceBytes + record.key.lengthOfBytes(using: .utf8) +
        (record.value.parentID?.lengthOfBytes(using: .utf8) ?? 0) +
        record.value.relativePath.lengthOfBytes(using: .utf8) + 32
    }
  }

  private func operationArguments(_ call: FlutterMethodCall) -> [String: Any]? {
    guard let value = arguments(call),
          WorkspaceProtocol.hasVersion(value),
          WorkspaceProtocol.workspaceID(value["workspaceId"]) != nil,
          WorkspaceProtocol.operationID(value["operationId"]) != nil,
          WorkspaceProtocol.remainingMillis(value["remainingMillis"]) != nil else {
      return nil
    }
    return value
  }

  private func arguments(_ call: FlutterMethodCall) -> [String: Any]? {
    call.arguments as? [String: Any]
  }

  private func topController() -> UIViewController? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
  }

  private func error(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }

  private func flutterError(_ source: Error) -> FlutterError {
    if case WorkspaceNativeError.wrapped(let value) = source { return value }
    if let value = source as? WorkspaceNativeError { return error(value.code) }
    if source is IOSProviderUnavailable { return error("unavailable") }
    let nsError = source as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
      return error("notFound")
    }
    return error("providerFailure")
  }
}

private enum WorkspaceNativeError: Error {
  case cancelled
  case closed
  case budgetExceeded
  case invalidReference
  case invalidCursor
  case invalidRequest
  case permissionLost
  case providerFailure
  case unavailable
  case unsupported
  case wrapped(FlutterError)

  var code: String {
    switch self {
    case .cancelled: return "cancelled"
    case .closed: return "closed"
    case .budgetExceeded: return "budgetExceeded"
    case .invalidReference: return "invalidReference"
    case .invalidCursor: return "invalidCursor"
    case .invalidRequest: return "invalidRequest"
    case .permissionLost: return "permissionLost"
    case .providerFailure, .wrapped: return "providerFailure"
    case .unavailable: return "unavailable"
    case .unsupported: return "unsupported"
    }
  }
}
