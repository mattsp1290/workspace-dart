package com.mattsp1290.workspace_flutter.internal

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

internal data class AndroidVaultEnvelope(
  val treeUri: String,
  val generation: Long,
  val rootId: String,
  val rootDigest: ByteArray,
)

/** Protocol-v1 validation shared by the channel handler and JVM tests. */
internal object WorkspaceProtocol {
  const val version = 1
  const val maxWorkspaceBytes = 512
  const val maxOperationIdBytes = 128
  const val maxStableIdBytes = 512
  const val maxEnvelopeBytes = 1_048_576
  const val maxRemainingMillis = 86_400_000L

  fun workspaceId(value: Any?): String? = (value as? String)
    ?.takeIf { it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= maxWorkspaceBytes && !it.contains('\u0000') }

  fun operationId(value: Any?): String? = (value as? String)
    ?.takeIf { it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= maxOperationIdBytes && it.all(::isOpaqueCharacter) }

  fun stableId(value: Any?): String? = (value as? String)
    ?.takeIf { it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= maxStableIdBytes && it.all(::isOpaqueCharacter) }

  fun envelope(value: Any?): ByteArray? = (value as? ByteArray)
    ?.takeIf { it.isNotEmpty() && it.size <= maxEnvelopeBytes }

  /**
   * The vault credential is binary and platform tagged. Its URI payload remains
   * opaque to Dart; accepting bare UTF-8 here would make a tree URI a public
   * channel convention again.
   */
  fun androidEnvelope(
    uri: String,
    generation: Long,
    rootId: String,
    rootDigest: ByteArray,
  ): ByteArray? {
    val payload = uri.toByteArray(StandardCharsets.UTF_8)
    val rootIdBytes = rootId.toByteArray(StandardCharsets.UTF_8)
    if (payload.isEmpty() || generation <= 0 || stableId(rootId) == null || rootDigest.size != rootDigestBytes ||
      payload.size > maxEnvelopeBytes - envelopeHeaderSize - rootIdBytes.size
    ) return null
    return ByteBuffer.allocate(envelopeHeaderSize + rootIdBytes.size + payload.size)
      .put(envelopeMagic)
      .put(androidPlatform)
      .putLong(generation)
      .putShort(rootIdBytes.size.toShort())
      .put(rootIdBytes)
      .put(rootDigest)
      .putInt(payload.size)
      .put(payload)
      .array()
  }

  fun androidVaultEnvelope(value: Any?): AndroidVaultEnvelope? {
    val bytes = envelope(value) ?: return null
    if (bytes.size <= envelopeHeaderSize || !bytes.copyOfRange(0, envelopeMagic.size).contentEquals(envelopeMagic)) {
      return null
    }
    val buffer = ByteBuffer.wrap(bytes)
    buffer.position(envelopeMagic.size)
    if (buffer.get() != androidPlatform) return null
    val generation = buffer.long
    val rootLength = buffer.short.toInt() and 0xffff
    if (generation <= 0 || rootLength <= 0 || rootLength > buffer.remaining() - rootDigestBytes - 4) return null
    val rootIdBytes = ByteArray(rootLength)
    buffer.get(rootIdBytes)
    val rootId = runCatching { StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(rootIdBytes)).toString() }.getOrNull()
      ?: return null
    if (stableId(rootId) == null) return null
    val digest = ByteArray(rootDigestBytes)
    buffer.get(digest)
    val length = buffer.int
    if (length <= 0 || length != buffer.remaining()) return null
    val payload = ByteArray(length)
    buffer.get(payload)
    val uri = runCatching {
      StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(payload)).toString()
    }.getOrNull() ?: return null
    return AndroidVaultEnvelope(uri, generation, rootId, digest)
  }

  fun boundedInt(value: Any?, minimum: Int, maximum: Int): Int? {
    val number = exactLong(value) ?: return null
    return number.takeIf { it in minimum.toLong()..maximum.toLong() }?.toInt()
  }

  fun nonNegativeLong(value: Any?): Long? = exactLong(value)?.takeIf { it >= 0 }

  fun remainingMillis(value: Any?): Long? {
    val asLong = exactLong(value) ?: return null
    return asLong.takeIf { it in 1..maxRemainingMillis }
  }

  fun hasVersion(arguments: Map<*, *>): Boolean = arguments["protocolVersion"] == version

  fun hasExactKeys(arguments: Map<*, *>, expected: Set<String>): Boolean =
    arguments.keys.all { it is String } && arguments.keys == expected

  private fun isOpaqueCharacter(value: Char): Boolean =
    value in 'A'..'Z' || value in 'a'..'z' || value in '0'..'9' || value == '-' || value == '_'

  private val envelopeMagic = byteArrayOf('W'.code.toByte(), 'S'.code.toByte(), 'E'.code.toByte(), 2)
  private const val androidPlatform: Byte = 1
  private const val rootDigestBytes = 32
  private const val envelopeHeaderSize = 4 + 1 + 8 + 2 + rootDigestBytes + 4

  private fun exactLong(value: Any?): Long? {
    val number = value as? Number ?: return null
    val asLong = number.toLong()
    // StandardMessageCodec can represent several Number types. Do not silently
    // truncate fractional values or accept a wrapping conversion.
    return asLong.takeIf { number.toDouble() == asLong.toDouble() }
  }
}
