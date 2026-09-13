import XCTest
@testable import WorkspaceFlutterNative

final class WorkspaceProtocolTests: XCTestCase {
  func testP01AcceptsOnlyProtocolVersionOne() {
    XCTAssertTrue(WorkspaceProtocol.hasVersion(["protocolVersion": 1]))
    XCTAssertFalse(WorkspaceProtocol.hasVersion(["protocolVersion": 2]))
    XCTAssertFalse(WorkspaceProtocol.hasVersion([:]))
  }

  func testP01RejectsUnknownRequestFields() {
    let expected: Set<String> = ["protocolVersion", "workspaceId"]
    XCTAssertTrue(WorkspaceProtocol.hasExactKeys(["protocolVersion": 1, "workspaceId": "workspace"], expected))
    XCTAssertFalse(WorkspaceProtocol.hasExactKeys(
      ["protocolVersion": 1, "workspaceId": "workspace", "unexpected": true], expected
    ))
  }

  func testP02RejectsMalformedIDs() {
    XCTAssertEqual(WorkspaceProtocol.workspaceID("workspace"), "workspace")
    XCTAssertNil(WorkspaceProtocol.workspaceID(""))
    XCTAssertNil(WorkspaceProtocol.workspaceID("bad\0id"))
    XCTAssertEqual(WorkspaceProtocol.operationID("abc_123-XYZ"), "abc_123-XYZ")
    XCTAssertNil(WorkspaceProtocol.operationID("not an id"))
    XCTAssertNil(WorkspaceProtocol.operationID(String(repeating: "a", count: 129)))
    XCTAssertEqual(WorkspaceProtocol.stableID("entry_123"), "entry_123")
    XCTAssertNil(WorkspaceProtocol.stableID("entry/path"))
    XCTAssertNil(WorkspaceProtocol.stableID(String(repeating: "a", count: 513)))
  }

  func testP02ValidatesDeadlineBoundaries() {
    XCTAssertEqual(WorkspaceProtocol.remainingMillis(Int64(1)), 1)
    XCTAssertEqual(WorkspaceProtocol.remainingMillis(Int64(86_400_000)), 86_400_000)
    XCTAssertNil(WorkspaceProtocol.remainingMillis(Int64(0)))
    XCTAssertNil(WorkspaceProtocol.remainingMillis(Int64(86_400_001)))
    XCTAssertNil(WorkspaceProtocol.remainingMillis(1.5))
  }

  func testP02PreservesSupportedIntegerWidths() {
    XCTAssertEqual(WorkspaceProtocol.nonNegativeInt64(Int64.max), Int64.max)
    XCTAssertNil(WorkspaceProtocol.nonNegativeInt64(-1))
    XCTAssertNil(WorkspaceProtocol.nonNegativeInt64(1.5))
    XCTAssertEqual(WorkspaceProtocol.boundedInt(Int64(1_000), minimum: 0, maximum: 1_000), 1_000)
    XCTAssertNil(WorkspaceProtocol.boundedInt(Int64(1_001), minimum: 0, maximum: 1_000))
  }

  func testP04AcceptsOnlyATaggedIOSVaultEnvelope() throws {
    let bookmark = Data([1, 2, 3])
    let envelope = try XCTUnwrap(WorkspaceProtocol.iOSEnvelope(
      bookmark: bookmark, generation: 7, rootID: "abcdefghijklmnopqrstuv", rootDigest: Data(repeating: 9, count: 32)
    ))
    XCTAssertEqual(WorkspaceProtocol.iOSVaultEnvelope(fromEnvelope: envelope), IOSVaultEnvelope(
      bookmark: bookmark, generation: 7, rootID: "abcdefghijklmnopqrstuv", rootDigest: Data(repeating: 9, count: 32)
    ))
    XCTAssertNil(WorkspaceProtocol.iOSVaultEnvelope(fromEnvelope: bookmark))
    XCTAssertNil(WorkspaceProtocol.iOSVaultEnvelope(fromEnvelope: Data(envelope.dropLast())))
    var wrongPlatform = envelope
    wrongPlatform[4] = 1
    XCTAssertNil(WorkspaceProtocol.iOSVaultEnvelope(fromEnvelope: wrongPlatform))
  }

  func testP08BoundsPrivateRelativeLineage() {
    XCTAssertEqual(WorkspaceLineage.components("nested/child")?.map(String.init), ["nested", "child"])
    XCTAssertNil(WorkspaceLineage.components("nested/../escape"))
    XCTAssertNil(WorkspaceLineage.components(Array(repeating: "child", count: 257).joined(separator: "/")))
  }
}
