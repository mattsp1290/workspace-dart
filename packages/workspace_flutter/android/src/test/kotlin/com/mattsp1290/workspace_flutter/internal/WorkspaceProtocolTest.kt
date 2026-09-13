package com.mattsp1290.workspace_flutter.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceProtocolTest {
  @Test fun `P01 accepts only protocol version one`() {
    assertTrue(WorkspaceProtocol.hasVersion(mapOf("protocolVersion" to 1)))
    assertFalse(WorkspaceProtocol.hasVersion(mapOf("protocolVersion" to 2)))
    assertFalse(WorkspaceProtocol.hasVersion(emptyMap<String, Any>()))
  }

  @Test fun `P01 rejects unknown request fields`() {
    val expected = setOf("protocolVersion", "workspaceId")
    assertTrue(WorkspaceProtocol.hasExactKeys(mapOf("protocolVersion" to 1, "workspaceId" to "workspace"), expected))
    assertFalse(WorkspaceProtocol.hasExactKeys(
      mapOf("protocolVersion" to 1, "workspaceId" to "workspace", "unexpected" to true), expected,
    ))
  }

  @Test fun `P02 rejects invalid workspace and operation ids`() {
    assertEquals("workspace", WorkspaceProtocol.workspaceId("workspace"))
    assertNull(WorkspaceProtocol.workspaceId(""))
    assertNull(WorkspaceProtocol.workspaceId("bad\u0000id"))
    assertEquals("abc_123-XYZ", WorkspaceProtocol.operationId("abc_123-XYZ"))
    assertNull(WorkspaceProtocol.operationId("not an id"))
    assertNull(WorkspaceProtocol.operationId("a".repeat(129)))
    assertEquals("entry_123", WorkspaceProtocol.stableId("entry_123"))
    assertNull(WorkspaceProtocol.stableId("entry/path"))
    assertNull(WorkspaceProtocol.stableId("a".repeat(513)))
  }

  @Test fun `P02 validates all deadline boundaries without narrowing`() {
    assertEquals(1L, WorkspaceProtocol.remainingMillis(1L))
    assertEquals(86_400_000L, WorkspaceProtocol.remainingMillis(86_400_000L))
    assertNull(WorkspaceProtocol.remainingMillis(0L))
    assertNull(WorkspaceProtocol.remainingMillis(86_400_001L))
    assertNull(WorkspaceProtocol.remainingMillis(1.5))
  }

  @Test fun `P02 preserves supported integer widths and bounds envelopes`() {
    assertEquals(Long.MAX_VALUE, WorkspaceProtocol.nonNegativeLong(Long.MAX_VALUE))
    assertNull(WorkspaceProtocol.nonNegativeLong(-1L))
    assertNull(WorkspaceProtocol.nonNegativeLong(1.5))
    assertEquals(1_000, WorkspaceProtocol.boundedInt(1_000L, 0, 1_000))
    assertNull(WorkspaceProtocol.boundedInt(1_001L, 0, 1_000))
    assertArrayEquals(byteArrayOf(1), WorkspaceProtocol.envelope(byteArrayOf(1)))
    assertNull(WorkspaceProtocol.envelope(ByteArray(1_048_577)))
  }

  @Test fun `P04 accepts only a tagged Android vault envelope`() {
    val tree = "content://example.test/tree/root"
    val envelope = requireNotNull(WorkspaceProtocol.androidEnvelope(
      tree, generation = 7, rootId = "abcdefghijklmnopqrstuv", rootDigest = ByteArray(32) { 9 },
    ))
    val decoded = requireNotNull(WorkspaceProtocol.androidVaultEnvelope(envelope))
    assertEquals(tree, decoded.treeUri)
    assertEquals(7, decoded.generation)
    assertEquals("abcdefghijklmnopqrstuv", decoded.rootId)
    assertArrayEquals(ByteArray(32) { 9 }, decoded.rootDigest)
    assertNull(WorkspaceProtocol.androidVaultEnvelope(tree.toByteArray()))
    assertNull(WorkspaceProtocol.androidVaultEnvelope(envelope.dropLast(1).toByteArray()))
    val wrongPlatform = envelope.copyOf()
    wrongPlatform[4] = 2
    assertNull(WorkspaceProtocol.androidVaultEnvelope(wrongPlatform))
  }
}
