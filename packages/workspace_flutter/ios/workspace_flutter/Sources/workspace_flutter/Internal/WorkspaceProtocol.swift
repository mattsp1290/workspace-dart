import Foundation

struct IOSVaultEnvelope: Equatable {
  let bookmark: Data
  let generation: UInt64
  let rootID: String
  let rootDigest: Data
}

/// Protocol-v1 validation shared by the channel handler and XCTest target.
enum WorkspaceProtocol {
  static let version = 1
  static let maxWorkspaceBytes = 512
  static let maxOperationIDBytes = 128
  static let maxStableIDBytes = 512
  static let maxEnvelopeBytes = 1_048_576
  static let maxRemainingMillis: Int64 = 86_400_000

  /// A platform-tagged binary vault credential. It binds the opaque bookmark
  /// to the native root generation and opaque root ID; Dart never decodes it.
  static func iOSEnvelope(
    bookmark: Data,
    generation: UInt64,
    rootID: String,
    rootDigest: Data
  ) -> Data? {
    guard !bookmark.isEmpty,
          let rootIDData = opaqueIDData(rootID),
          rootDigest.count == rootDigestBytes,
          bookmark.count <= maxEnvelopeBytes - envelopeHeaderSize - rootIDData.count else {
      return nil
    }
    var envelope = envelopeMagic
    envelope.append(iOSPlatform)
    var encodedGeneration = generation.bigEndian
    withUnsafeBytes(of: &encodedGeneration) { envelope.append(contentsOf: $0) }
    var rootLength = UInt16(rootIDData.count).bigEndian
    withUnsafeBytes(of: &rootLength) { envelope.append(contentsOf: $0) }
    envelope.append(rootIDData)
    envelope.append(rootDigest)
    var bookmarkLength = UInt32(bookmark.count).bigEndian
    withUnsafeBytes(of: &bookmarkLength) { envelope.append(contentsOf: $0) }
    envelope.append(bookmark)
    return envelope
  }

  static func iOSVaultEnvelope(fromEnvelope envelope: Data) -> IOSVaultEnvelope? {
    guard envelope.count > envelopeHeaderSize,
          envelope.prefix(envelopeMagic.count) == envelopeMagic,
          envelope[envelopeMagic.count] == iOSPlatform else { return nil }
    var index = envelopeMagic.count + 1
    guard let generation = readUInt64(envelope, index: &index),
          let rootLength = readUInt16(envelope, index: &index),
          rootLength > 0,
          index + Int(rootLength) + rootDigestBytes + 4 < envelope.count else { return nil }
    let rootData = envelope[index..<(index + Int(rootLength))]
    index += Int(rootLength)
    guard let rootID = String(data: rootData, encoding: .utf8), opaqueIDData(rootID) != nil else {
      return nil
    }
    let digest = Data(envelope[index..<(index + rootDigestBytes)])
    index += rootDigestBytes
    guard let bookmarkLength = readUInt32(envelope, index: &index),
          bookmarkLength > 0,
          Int(bookmarkLength) == envelope.count - index else { return nil }
    return IOSVaultEnvelope(
      bookmark: Data(envelope[index...]), generation: generation, rootID: rootID, rootDigest: digest
    )
  }

  static func hasVersion(_ values: [String: Any]) -> Bool {
    values["protocolVersion"] as? Int == version
  }

  static func hasExactKeys(_ values: [String: Any], _ expected: Set<String>) -> Bool {
    Set(values.keys) == expected
  }

  static func workspaceID(_ value: Any?) -> String? {
    guard let value = value as? String,
          !value.isEmpty,
          !value.contains("\0"),
          value.lengthOfBytes(using: .utf8) <= maxWorkspaceBytes else { return nil }
    return value
  }

  static func operationID(_ value: Any?) -> String? {
    guard let value = value as? String,
          !value.isEmpty,
          value.utf8.count <= maxOperationIDBytes,
          value.unicodeScalars.allSatisfy(isOpaqueCharacter) else { return nil }
    return value
  }

  static func stableID(_ value: Any?) -> String? {
    guard let value = value as? String,
          !value.isEmpty,
          value.utf8.count <= maxStableIDBytes,
          value.unicodeScalars.allSatisfy(isOpaqueCharacter) else { return nil }
    return value
  }

  static func boundedInt(_ value: Any?, minimum: Int, maximum: Int) -> Int? {
    guard let exact = exactInteger(value), exact >= Int64(minimum), exact <= Int64(maximum) else {
      return nil
    }
    return Int(exact)
  }

  static func nonNegativeInt64(_ value: Any?) -> Int64? {
    guard let exact = exactInteger(value), exact >= 0 else { return nil }
    return exact
  }

  static func remainingMillis(_ value: Any?) -> Int64? {
    guard let raw = exactInteger(value), raw >= 1, raw <= maxRemainingMillis else { return nil }
    return raw
  }

  private static func isOpaqueCharacter(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 45, 48...57, 65...90, 95, 97...122: return true
    default: return false
    }
  }

  private static let envelopeMagic = Data([0x57, 0x53, 0x45, 0x02])
  private static let iOSPlatform: UInt8 = 2
  private static let envelopeHeaderSize = 4 + 1 + 8 + 2 + 32 + 4
  private static let rootDigestBytes = 32

  private static func opaqueIDData(_ value: String) -> Data? {
    guard !value.isEmpty,
          value.utf8.count <= maxStableIDBytes,
          value.unicodeScalars.allSatisfy(isOpaqueCharacter) else { return nil }
    return Data(value.utf8)
  }

  private static func readUInt16(_ data: Data, index: inout Int) -> UInt16? {
    guard index + 2 <= data.count else { return nil }
    let value = data[index..<(index + 2)].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    index += 2
    return value
  }

  private static func readUInt32(_ data: Data, index: inout Int) -> UInt32? {
    guard index + 4 <= data.count else { return nil }
    let value = data[index..<(index + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    index += 4
    return value
  }

  private static func readUInt64(_ data: Data, index: inout Int) -> UInt64? {
    guard index + 8 <= data.count else { return nil }
    let value = data[index..<(index + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    index += 8
    return value
  }

  private static func exactInteger(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber else { return nil }
    let raw = number.int64Value
    // NSNumber can carry a floating-point value from malformed channel input.
    return number.doubleValue == Double(raw) ? raw : nil
  }
}
