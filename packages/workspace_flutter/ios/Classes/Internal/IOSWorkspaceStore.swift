import Foundation

/// Private native lineage/root store. Public models never receive these values.
internal struct IOSLineageRecord: Equatable {
  let parentID: String?
  let relativePath: String
}

internal struct IOSRootRecord: Equatable {
  let identity: String
  let generation: UInt64
  let rootID: String
  let digest: Data
  let phase: String
}

internal protocol IOSWorkspaceStore {
  /// Returns nil when a workspace contains an unversioned or malformed record.
  /// Callers fail closed rather than interpreting legacy path-only state.
  func records(workspaceId: String) -> [String: IOSLineageRecord]?
  func saveRecords(_ records: [String: IOSLineageRecord], workspaceId: String) -> Bool
  func rootRecord(workspaceId: String) -> IOSRootRecord?
  func hasRootState(workspaceId: String) -> Bool
  func saveRootRecord(_ record: IOSRootRecord, workspaceId: String) -> Bool
  func promoteRoot(workspaceId: String) -> Bool
  func removeWorkspace(_ workspaceId: String) -> Bool
  func storedWorkspaceIDs() -> Set<String>
}

internal final class UserDefaultsIOSWorkspaceStore: IOSWorkspaceStore {
  static let suiteName = "com.mattsp1290.workspace_flutter.native"
  private let defaults: UserDefaults
  private let entryPrefix = "workspace_flutter.entries."
  private let rootPrefix = "workspace_flutter.root-binding."

  init(defaults: UserDefaults? = nil) {
    // This is a plugin-owned private namespace, not the host's default
    // preference domain. The prototype format is unpublished and is not
    // migrated into the versioned native state model.
    self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName)!
  }

  func records(workspaceId: String) -> [String: IOSLineageRecord]? {
    guard let raw = defaults.dictionary(forKey: entryKey(workspaceId)) else { return [:] }
    var records: [String: IOSLineageRecord] = [:]
    for (stableID, value) in raw {
      guard isOpaqueID(stableID),
            let encoded = value as? [String: Any],
            Set(encoded.keys) == ["version", "parentID", "relativePath"],
            encoded["version"] as? Int == 1,
            let relativePath = encoded["relativePath"] as? String else { return nil }
      guard let encodedParentID = encoded["parentID"] as? String else { return nil }
      let parentID = encodedParentID.isEmpty ? nil : encodedParentID
      guard parentID == nil || isOpaqueID(parentID!) else { return nil }
      records[stableID] = IOSLineageRecord(parentID: parentID, relativePath: relativePath)
    }
    return records
  }

  func saveRecords(_ records: [String: IOSLineageRecord], workspaceId: String) -> Bool {
    let encoded = records.mapValues { record in
      [
        "version": 1,
        // Property lists cannot represent null. Empty is reserved solely for
        // the root record; non-root IDs are validated by the plugin.
        "parentID": record.parentID ?? "",
        "relativePath": record.relativePath,
      ] as [String: Any]
    }
    defaults.set(encoded, forKey: entryKey(workspaceId))
    return defaults.synchronize()
  }

  func rootRecord(workspaceId: String) -> IOSRootRecord? {
    guard let encoded = defaults.dictionary(forKey: rootKey(workspaceId)),
          Set(encoded.keys) == ["version", "identity", "generation", "rootID", "digest", "phase"],
          encoded["version"] as? Int == 1,
          let identity = encoded["identity"] as? String,
          let generation = encoded["generation"] as? NSNumber,
          generation.int64Value > 0,
          let rootID = encoded["rootID"] as? String,
          isOpaqueID(rootID),
          let digest = encoded["digest"] as? Data,
          digest.count == 32,
          let phase = encoded["phase"] as? String,
          phase == "pending" || phase == "active" else { return nil }
    return IOSRootRecord(
      identity: identity, generation: UInt64(generation.int64Value), rootID: rootID, digest: digest, phase: phase
    )
  }

  func hasRootState(workspaceId: String) -> Bool {
    defaults.object(forKey: rootKey(workspaceId)) != nil
  }

  func saveRootRecord(_ record: IOSRootRecord, workspaceId: String) -> Bool {
    defaults.set([
      "version": 1,
      "identity": record.identity,
      "generation": NSNumber(value: record.generation),
      "rootID": record.rootID,
      "digest": record.digest,
      "phase": record.phase,
    ], forKey: rootKey(workspaceId))
    return defaults.synchronize()
  }

  func promoteRoot(workspaceId: String) -> Bool {
    guard var record = rootRecord(workspaceId: workspaceId) else { return false }
    if record.phase == "active" { return true }
    record = IOSRootRecord(
      identity: record.identity, generation: record.generation, rootID: record.rootID,
      digest: record.digest, phase: "active"
    )
    return saveRootRecord(record, workspaceId: workspaceId)
  }

  func removeWorkspace(_ workspaceId: String) -> Bool {
    defaults.removeObject(forKey: entryKey(workspaceId))
    defaults.removeObject(forKey: rootKey(workspaceId))
    return defaults.synchronize()
  }

  func storedWorkspaceIDs() -> Set<String> {
    Set(defaults.dictionaryRepresentation().keys.compactMap { key in
      if key.hasPrefix(entryPrefix) {
        return String(key.dropFirst(entryPrefix.count))
      }
      if key.hasPrefix(rootPrefix) {
        return String(key.dropFirst(rootPrefix.count))
      }
      return nil
    })
  }

  private func entryKey(_ workspaceId: String) -> String { entryPrefix + workspaceId }
  private func rootKey(_ workspaceId: String) -> String { rootPrefix + workspaceId }

  private func isOpaqueID(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9_-]{1,512}$", options: .regularExpression) != nil
  }
}
