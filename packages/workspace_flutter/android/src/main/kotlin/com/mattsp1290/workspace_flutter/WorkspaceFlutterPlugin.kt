package com.mattsp1290.workspace_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.SystemClock
import android.provider.DocumentsContract
import com.mattsp1290.workspace_flutter.internal.WorkspaceProtocol
import com.mattsp1290.workspace_flutter.internal.ReadPositioning
import com.mattsp1290.workspace_flutter.internal.SequentialOffsetLimitExceeded
import com.mattsp1290.workspace_flutter.internal.EntryLineage
import com.mattsp1290.workspace_flutter.internal.EntryRecord
import com.mattsp1290.workspace_flutter.internal.AndroidDocumentProvider
import com.mattsp1290.workspace_flutter.internal.ContentResolverDocumentProvider
import com.mattsp1290.workspace_flutter.internal.WorkspaceNativeOperation
import com.mattsp1290.workspace_flutter.internal.WorkspaceOperationEngine
import com.mattsp1290.workspace_flutter.internal.WorkspaceOperationFailure
import com.mattsp1290.workspace_flutter.internal.WorkspaceDocumentProviderOverride
import com.mattsp1290.workspace_flutter.internal.AndroidEntryStore
import com.mattsp1290.workspace_flutter.internal.AndroidRootRecord
import com.mattsp1290.workspace_flutter.internal.AndroidVaultEnvelope
import com.mattsp1290.workspace_flutter.internal.AndroidGrantStore
import com.mattsp1290.workspace_flutter.internal.AndroidAcquisitionRecord
import com.mattsp1290.workspace_flutter.internal.AndroidPickerGrant
import com.mattsp1290.workspace_flutter.internal.WorkspaceStateExecutor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

private typealias NativeFailure = WorkspaceOperationFailure

private data class PendingPicker(
  val workspaceId: String,
  val result: MethodChannel.Result,
)

private data class TreeAuthority(
  val uri: Uri,
  val vault: AndroidVaultEnvelope,
)

/** A process-local, single-use page cursor. It deliberately stores no URI. */
private data class ListSnapshot(
  val workspaceId: String,
  val directoryId: String,
  val rows: List<Map<String, Any>>,
  val nextIndex: Int,
  val expiresAt: Long,
  val maxEntries: Int,
  val maxBytes: Int,
)

/** Read-only SAF bridge. Tree URIs and provider document IDs remain app-private. */
class WorkspaceFlutterPlugin private constructor(
  private val documentProviderFactory: (Context) -> AndroidDocumentProvider,
) :
  FlutterPlugin,
  MethodChannel.MethodCallHandler,
  ActivityAware {
  /** Constructor used by Flutter's generated plugin registrant. */
  constructor() : this({ appContext ->
      WorkspaceDocumentProviderOverride.documentProvider(appContext)
      ?: ContentResolverDocumentProvider(appContext.contentResolver)
  })

  /** Test-only injection point; production code always uses the resolver seam. */
  internal constructor(documentProvider: AndroidDocumentProvider) : this({ documentProvider })

  private lateinit var channel: MethodChannel
  private lateinit var context: Context
  private lateinit var documentProvider: AndroidDocumentProvider
  private lateinit var entryStore: AndroidEntryStore
  private lateinit var grantJournal: AndroidGrantStore
  private var activity: Activity? = null
  private var activityBinding: ActivityPluginBinding? = null
  private var pendingPicker: PendingPicker? = null
  private val requestCode = 9182
  // Provider calls run outside this lane. It serializes only the private
  // lineage read/issue/write transaction so concurrent listings cannot mint
  // different opaque IDs for the same provider lineage.
  private val stateExecutor = WorkspaceStateExecutor()
  private val operationEngine = WorkspaceOperationEngine()
  private val cursors = ConcurrentHashMap<String, ListSnapshot>()
  private val activityResultListener =
    io.flutter.plugin.common.PluginRegistry.ActivityResultListener { code, result, data ->
      handlePickerResult(code, result, data)
    }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    documentProvider = documentProviderFactory(context)
    entryStore = AndroidEntryStore(context)
    grantJournal = AndroidGrantStore(context)
    stateExecutor.attach()
    // The legacy journal had no generation/root binding and must never be
    // restored. A tombstone survives any release interruption and is retried
    // by the explicit reconciliation call below.
    runCatching(::reconcileLegacyGrantCleanup)
    operationEngine.attach()
    channel = MethodChannel(binding.binaryMessenger, "workspace_flutter/read_only")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    pendingPicker?.result?.error("cancelled", null, null)
    pendingPicker = null
    // Keep operation ownership until each worker closes its provider resource.
    // A detached engine must not receive a late MethodChannel reply.
    cursors.clear()
    operationEngine.detach()
    stateExecutor.close()
    channel.setMethodCallHandler(null)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    activityBinding = binding
    binding.addActivityResultListener(activityResultListener)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    detachActivity(cancelPicker = false)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
    detachActivity(cancelPicker = true)
  }

  private fun detachActivity(cancelPicker: Boolean) {
    activityBinding?.removeActivityResultListener(activityResultListener)
    activityBinding = null
    activity = null
    if (cancelPicker) {
      pendingPicker?.result?.error("cancelled", null, null)
      pendingPicker = null
    }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "selectDirectory" -> select(call, result)
      "restore" -> restore(call, result)
      "list" -> list(call, result)
      "read" -> read(call, result)
      "cancel" -> cancel(call, result)
      "cancelWorkspace" -> cancelWorkspace(call, result)
      "commitSelection" -> commitSelection(call, result)
      "abandonSelection" -> abandonSelection(call, result)
      "forgetWorkspace" -> forgetWorkspace(call, result)
      "reconcileAcquisitions" -> reconcileAcquisitions(call, result)
      else -> result.notImplemented()
    }
  }

  private fun select(call: MethodCall, result: MethodChannel.Result) {
    val host = activity ?: return result.error("unsupported", "No activity attached", null)
    val workspaceId = callWorkspaceId(call, result) ?: return
    if (pendingPicker != null) {
      result.error("providerFailure", "Picker already active", null)
      return
    }
    pendingPicker = PendingPicker(workspaceId, result)
    host.startActivityForResult(
      Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
      ),
      requestCode,
    )
  }

  private fun handlePickerResult(code: Int, resultCode: Int, data: Intent?): Boolean {
    if (code != requestCode) return false
    val pending = pendingPicker ?: return true
    pendingPicker = null
    val reply = pending.result
    val uri = data?.data
    if (resultCode != Activity.RESULT_OK || uri == null) {
      reply.success(null)
      return true
    }
    if (!AndroidPickerGrant.hasReadAndPersistableAccess(data.flags)) {
      reply.error("permissionLost", null, null)
      return true
    }
    val rootDocumentId = treeDocumentId(uri) ?: run {
      reply.error("invalidRequest", null, null)
      return true
    }
    val rootStableId = randomOpaqueId()
    val vault = AndroidVaultEnvelope(
      treeUri = uri.toString(),
      generation = randomGeneration(),
      rootId = rootStableId,
      rootDigest = rootDigest(uri),
    )
    val envelope = WorkspaceProtocol.androidEnvelope(
      uri = vault.treeUri,
      generation = vault.generation,
      rootId = vault.rootId,
      rootDigest = vault.rootDigest,
    ) ?: run {
      reply.error("providerFailure", null, null)
      return true
    }
    try {
      val existing = context.contentResolver.persistedUriPermissions.any {
        it.uri == uri && it.isReadPermission
      }
      if (!writeAcquisition(pending.workspaceId, uri, "prepared", !existing, vault)) {
        reply.error("providerFailure", null, null)
        return true
      }
      context.contentResolver.takePersistableUriPermission(
        uri,
        Intent.FLAG_GRANT_READ_URI_PERMISSION,
      )
      if (!writeAcquisition(pending.workspaceId, uri, "acquired", !existing, vault)) {
        if (!existing) {
          context.contentResolver.releasePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
          )
        }
        clearAcquisition(pending.workspaceId)
        reply.error("providerFailure", null, null)
        return true
      }
      if (!bindRoot(pending.workspaceId, rootDocumentId, vault) ||
        issueEntries(
          pending.workspaceId, parentId = null, documentIds = listOf(rootDocumentId),
          preferredIds = mapOf(rootDocumentId to rootStableId),
        )?.get(rootDocumentId) != rootStableId
      ) {
        if (!existing && hasPersistedRead(uri)) {
          context.contentResolver.releasePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
          )
        }
        clearAcquisition(pending.workspaceId)
        runCatching { clearEntries(pending.workspaceId) }
        reply.error("providerFailure", null, null)
        return true
      }
      reply.success(envelope)
    } catch (_: SecurityException) {
      clearAcquisition(pending.workspaceId)
      reply.error("permissionLost", null, null)
    }
    return true
  }

  private fun restore(call: MethodCall, result: MethodChannel.Result) {
    val values = call.arguments as? Map<*, *> ?: return result.error("invalidRequest", null, null)
    if (!WorkspaceProtocol.hasExactKeys(values, setOf("protocolVersion", "workspaceId", "envelope"))) {
      result.error("invalidRequest", null, null)
      return
    }
    val workspaceId = WorkspaceProtocol.workspaceId(values["workspaceId"])
      ?: return result.error("invalidRequest", null, null)
    val tree = tree(call, result) ?: return
    try {
      val rootId = treeDocumentId(tree.uri) ?: return result.error("invalidRequest", null, null)
      if (!bindRoot(workspaceId, rootId, tree.vault)) {
        result.error("permissionLost", null, null)
        return
      }
      if (!grantJournal.ensureRestoredActive(workspaceId, AndroidAcquisitionRecord(
          uri = tree.vault.treeUri,
          phase = "active",
          owned = false,
          generation = tree.vault.generation,
          rootId = tree.vault.rootId,
          digest = tree.vault.rootDigest,
        ))) {
        result.error("permissionLost", null, null)
        return
      }
      val stableId = issueEntries(
        workspaceId, parentId = null, documentIds = listOf(rootId),
        preferredIds = mapOf(rootId to tree.vault.rootId),
      )?.get(rootId)
        ?: return result.error("providerFailure", null, null)
      if (stableId != tree.vault.rootId) return result.error("permissionLost", null, null)
      result.success(mapOf("entryId" to stableId, "name" to "workspace"))
    } catch (_: Exception) {
      result.error("permissionLost", null, null)
    }
  }

  private fun list(call: MethodCall, result: MethodChannel.Result) {
    val arguments = operationArguments(call, result) ?: return
    val workspaceId = arguments.workspaceId
    val values = call.arguments as? Map<*, *> ?: return result.error("invalidRequest", null, null)
    if (!WorkspaceProtocol.hasExactKeys(values, setOf(
        "protocolVersion", "workspaceId", "envelope", "directoryId", "maxEntries", "maxBytes", "cursor",
        "operationId", "remainingMillis",
      ))) return result.error("invalidRequest", null, null)
    val tree = tree(call, result) ?: return
    if (!matchesRoot(workspaceId, tree)) {
      result.error("permissionLost", null, null)
      return
    }
    val stableParent = WorkspaceProtocol.stableId(values["directoryId"])
      ?: return result.error("invalidRequest", null, null)
    val parent = resolveEntry(workspaceId, stableParent)
      ?: return result.error("invalidReference", null, null)
    try {
      validatedDocumentUri(tree.uri, parent.documentId)
    } catch (_: SecurityException) {
      result.error("permissionLost", null, null)
      return
    } catch (_: Exception) {
      result.error("invalidReference", null, null)
      return
    }
    val maxEntries = WorkspaceProtocol.boundedInt(values["maxEntries"], 0, MAX_ENTRIES)
    val maxBytes = WorkspaceProtocol.boundedInt(values["maxBytes"], 0, MAX_BYTES)
    if (maxEntries == null || maxBytes == null) {
      result.error("invalidRequest", null, null)
      return
    }
    val cursorToken = values["cursor"] as? String
    if (values["cursor"] != null && WorkspaceProtocol.stableId(cursorToken) == null) {
      result.error("invalidRequest", null, null)
      return
    }
    runOperation(arguments, result) { operation, deadline ->
      if (cursorToken != null) {
        return@runOperation resumePage(
          cursorToken, workspaceId, stableParent, maxEntries, maxBytes, deadline,
        )
      }
      val rows = mutableListOf<Map<String, Any>>()
      val documentIds = mutableListOf<String>()
      var snapshotBytes = 0
      documentProvider.forEachChild(tree.uri, parent.documentId, operation.cancellation) { child ->
          checkOperation(operation, deadline)
          if (rows.size >= MAX_SNAPSHOT_ENTRIES) {
            // A cursor must not turn an unbounded provider enumeration into an
            // unbounded in-process buffer.
            throw NativeFailure("unsupported")
          }
          val name = child.displayName ?: throw NativeFailure("providerFailure")
          if (!isSafeDisplayName(name)) return@forEachChild true
          val metadataBytes = name.toByteArray(Charsets.UTF_8).size
          if (snapshotBytes + metadataBytes > MAX_BYTES) {
            throw NativeFailure("unsupported")
          }
          val documentId = child.documentId ?: throw NativeFailure("providerFailure")
          val mime = child.mimeType
          val isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR
          if (!isDirectory && (child.byteLength == null || child.byteLength < 0)) {
            // Do not manufacture a false zero length. Providers that omit
            // size need a descriptor probe, which this bounded query seam
            // cannot safely perform here.
            throw NativeFailure("unsupported")
          }
          documentIds.add(documentId)
          val row = mutableMapOf<String, Any>(
            "documentId" to documentId,
            "name" to name,
            "type" to if (isDirectory) "directory" else "file",
          )
          if (!isDirectory) row["byteLength"] = requireNotNull(child.byteLength)
          rows.add(row)
          snapshotBytes += metadataBytes
          true
      }
      // Provider enumeration order is not stable enough to back a resumable
      // cursor. Private document lineage is the deterministic sort key.
      rows.sortBy { it["documentId"] as String }
      val issued = issueEntries(workspaceId, parentId = stableParent, documentIds = documentIds)
        ?: throw NativeFailure("providerFailure")
      val publicRows = rows.map { row ->
        row - "documentId" + ("entryId" to (issued[row["documentId"] as String]
          ?: throw NativeFailure("providerFailure")))
      }
      if (publicRows.any { (it["entryId"] as String).isEmpty() }) {
        throw NativeFailure("providerFailure")
      }
      pageFromSnapshot(workspaceId, stableParent, publicRows, 0, maxEntries, maxBytes, deadline)
    }
  }

  private fun resumePage(
    cursorToken: String,
    workspaceId: String,
    directoryId: String,
    maxEntries: Int,
    maxBytes: Int,
    deadline: Long,
  ): Map<String, Any?> {
    if (!cursorToken.matches(Regex("^[A-Za-z0-9_-]{1,512}$"))) {
      throw NativeFailure("invalidCursor")
    }
    val snapshot = cursors.remove(cursorToken) ?: throw NativeFailure("invalidCursor")
    if (snapshot.workspaceId != workspaceId || snapshot.directoryId != directoryId ||
      snapshot.maxEntries != maxEntries || snapshot.maxBytes != maxBytes ||
      SystemClock.elapsedRealtime() >= snapshot.expiresAt || SystemClock.elapsedRealtime() >= deadline
    ) throw NativeFailure("invalidCursor")
    return pageFromSnapshot(
      workspaceId, directoryId, snapshot.rows, snapshot.nextIndex, maxEntries, maxBytes, snapshot.expiresAt,
    )
  }

  private fun pageFromSnapshot(
    workspaceId: String,
    directoryId: String,
    rows: List<Map<String, Any>>,
    startIndex: Int,
    maxEntries: Int,
    maxBytes: Int,
    expiresAt: Long,
  ): Map<String, Any?> {
    var next = startIndex
    var usedBytes = 0
    val page = mutableListOf<Map<String, Any>>()
    while (next < rows.size && page.size < maxEntries) {
      val row = rows[next]
      val rowBytes = (row["name"] as String).toByteArray(Charsets.UTF_8).size
      if (usedBytes + rowBytes > maxBytes) break
      page.add(row)
      usedBytes += rowBytes
      next += 1
    }
    if (next == startIndex && next < rows.size) throw NativeFailure("budgetExceeded")
    val cursor = if (next < rows.size) randomOpaqueId() else null
    if (cursor != null) {
      stateExecutor.call {
        if (operationEngine.isWorkspaceClosing(workspaceId)) throw NativeFailure("closed")
        cursors[cursor] = ListSnapshot(
          workspaceId, directoryId, rows, next, expiresAt, maxEntries, maxBytes,
        )
      }
    }
    return mapOf(
      "entries" to page,
      "completion" to if (cursor == null) "complete" else "hasMore",
      "consistency" to "unverified",
      "usedEntries" to page.size,
      "usedBytes" to usedBytes,
      "cursor" to cursor,
    )
  }

  private fun read(call: MethodCall, result: MethodChannel.Result) {
    val arguments = operationArguments(call, result) ?: return
    val workspaceId = arguments.workspaceId
    val values = call.arguments as? Map<*, *> ?: return result.error("invalidRequest", null, null)
    if (!WorkspaceProtocol.hasExactKeys(values, setOf(
        "protocolVersion", "workspaceId", "envelope", "fileId", "offset", "count", "maxBytes",
        "expectedRevision", "operationId", "remainingMillis",
      ))) return result.error("invalidRequest", null, null)
    val tree = tree(call, result) ?: return
    if (!matchesRoot(workspaceId, tree)) {
      result.error("permissionLost", null, null)
      return
    }
    val stableFile = WorkspaceProtocol.stableId(values["fileId"])
      ?: return result.error("invalidRequest", null, null)
    val entry = resolveEntry(workspaceId, stableFile)
      ?: return result.error("invalidReference", null, null)
    val offset = WorkspaceProtocol.nonNegativeLong(values["offset"])
    val count = WorkspaceProtocol.boundedInt(values["count"], 0, MAX_BYTES)
    val maxBytes = WorkspaceProtocol.boundedInt(values["maxBytes"], 0, MAX_BYTES)
    if (offset == null || count == null || maxBytes == null || offset > Long.MAX_VALUE - count ||
      count > maxBytes || !validExpectedRevision(values["expectedRevision"])
    ) {
      result.error("invalidRequest", null, null)
      return
    }
    runOperation(arguments, result) { operation, deadline ->
      checkOperation(operation, deadline)
      val uri = validatedDocumentUri(tree.uri, entry.documentId)
      ensureFile(uri, operation, deadline)
      val descriptor = documentProvider.openRead(uri, operation.cancellation)
        ?: throw NativeFailure("unavailable")
      descriptor.use { parcel ->
        val input = parcel.input
          val reachedOffset = try {
            ReadPositioning.position(
              input = input,
              offset = offset,
              trySeek = parcel::seek,
              check = { checkOperation(operation, deadline) },
            )
          } catch (_: SequentialOffsetLimitExceeded) {
            throw NativeFailure("unsupported")
          }
          if (!reachedOffset) {
            return@use mapOf(
              "bytes" to ByteArray(0),
              "offset" to offset,
              "eof" to true,
              "actualRevision" to null,
              "stability" to "unverified",
            )
          }
          val bytes = ByteArray(count)
          var total = 0
          while (total < count) {
            checkOperation(operation, deadline)
            val read = input.read(bytes, total, count - total)
            if (read < 0) break
            total += read
          }
          val statSize = parcel.statSize
          mapOf(
            "bytes" to bytes.copyOf(total),
            "offset" to offset,
            "eof" to if (statSize >= 0) offset + total >= statSize else total < count,
            "actualRevision" to null,
            "stability" to "unverified",
          )
      }
    }
  }

  private fun runOperation(
    arguments: OperationArguments,
    result: MethodChannel.Result,
    body: (WorkspaceNativeOperation, Long) -> Any,
  ) {
    if (!operationEngine.run(
      operationId = arguments.operationId,
      workspaceId = arguments.workspaceId,
      remainingMillis = arguments.remainingMillis,
      result = result,
      body = body,
    )) {
      result.error(
        if (operationEngine.isWorkspaceClosing(arguments.workspaceId)) "closed" else "invalidRequest",
        null,
        null,
      )
    }
  }

  private fun cancel(call: MethodCall, result: MethodChannel.Result) {
    val values = call.arguments as? Map<*, *>
    val operationId = values?.get("operationId")?.let(WorkspaceProtocol::operationId)
    if (values == null || !WorkspaceProtocol.hasVersion(values) ||
      !WorkspaceProtocol.hasExactKeys(values, setOf("protocolVersion", "operationId")) || operationId == null
    ) {
      result.error("invalidRequest", null, null)
      return
    }
    operationEngine.cancel(operationId)
    result.success(null)
  }

  private fun cancelWorkspace(call: MethodCall, result: MethodChannel.Result) {
    val workspaceId = callWorkspaceId(call, result) ?: return
    if (pendingPicker?.workspaceId == workspaceId) {
      pendingPicker?.result?.error("cancelled", null, null)
      pendingPicker = null
    }
    operationEngine.closeWorkspace(workspaceId)
    clearWorkspaceCursors(workspaceId)
    // Cancellation is cooperative. The close barrier must not acknowledge
    // while a query/descriptor still belongs to an operation.
    operationEngine.afterWorkspaceCleanup(workspaceId) {
      operationEngine.postToMain { result.success(null) }
    }
  }

  private fun commitSelection(call: MethodCall, result: MethodChannel.Result) {
    val workspaceId = callWorkspaceId(call, result) ?: return
    try {
      promoteAcquisition(workspaceId)
      result.success(null)
    } catch (_: Exception) {
      result.error("providerFailure", null, null)
    }
  }

  private fun abandonSelection(call: MethodCall, result: MethodChannel.Result) {
    val workspaceId = callWorkspaceId(call, result) ?: return
    try {
      abandonAcquisition(workspaceId)
      result.success(null)
    } catch (_: SecurityException) {
      result.error("permissionLost", null, null)
    }
  }

  private fun forgetWorkspace(call: MethodCall, result: MethodChannel.Result) {
    val workspaceId = callWorkspaceId(call, result) ?: return
    if (pendingPicker?.workspaceId == workspaceId) {
      pendingPicker?.result?.error("cancelled", null, null)
      pendingPicker = null
    }
    operationEngine.closeWorkspace(workspaceId)
    clearWorkspaceCursors(workspaceId)
    // Do not delete private lineage or release a grant until provider-backed
    // operations have closed their descriptors/cursors.
    operationEngine.afterWorkspaceCleanup(workspaceId) {
      try {
        forgetWorkspace(workspaceId)
        operationEngine.postToMain { result.success(null) }
      } catch (_: SecurityException) {
        operationEngine.postToMain { result.error("permissionLost", null, null) }
      } catch (_: Exception) {
        operationEngine.postToMain { result.error("providerFailure", null, null) }
      }
    }
  }

  private fun reconcileAcquisitions(call: MethodCall, result: MethodChannel.Result) {
    val values = call.arguments as? Map<*, *>
    val rawIds = values?.get("activeWorkspaceIds") as? List<*>
    if (values == null || !WorkspaceProtocol.hasVersion(values) ||
      !WorkspaceProtocol.hasExactKeys(values, setOf("protocolVersion", "activeWorkspaceIds")) || rawIds == null
    ) {
      result.error("invalidRequest", null, null)
      return
    }
    val activeIds = rawIds.map { WorkspaceProtocol.workspaceId(it) }.toSet()
    if (activeIds.contains(null)) {
      result.error("invalidRequest", null, null)
      return
    }
    try {
      reconcileLegacyGrantCleanup()
      deletingWorkspaceIds().forEach(::completeDeletion)
      acquisitionIds().forEach { workspaceId ->
        if (workspaceId in activeIds) promoteAcquisition(workspaceId)
        else abandonAcquisition(workspaceId)
      }
      activeWorkspaceIds().filterNot { it in activeIds }.forEach { forgetWorkspace(it) }
      entryStore.workspaceIDs().filterNot { it in activeIds }.forEach { clearEntries(it) }
      result.success(null)
    } catch (_: SecurityException) {
      result.error("permissionLost", null, null)
    } catch (_: Exception) {
      result.error("providerFailure", null, null)
    }
  }

  private fun checkOperation(operation: WorkspaceNativeOperation, deadline: Long) {
    if (operation.isCancelled()) throw NativeFailure("cancelled")
    if (SystemClock.elapsedRealtime() >= deadline) throw NativeFailure("budgetExceeded")
  }

  /** Revalidate type at use time; a provider may mutate a previously listed row. */
  private fun ensureFile(uri: Uri, operation: WorkspaceNativeOperation, deadline: Long) {
    val mime = documentProvider.mimeType(uri, operation.cancellation)
      ?: throw NativeFailure("notFound")
    checkOperation(operation, deadline)
    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) throw NativeFailure("unsupported")
  }

  private fun operationArguments(
    call: MethodCall,
    result: MethodChannel.Result,
  ): OperationArguments? {
    val values = call.arguments as? Map<*, *> ?: run {
      result.error("invalidRequest", null, null)
      return null
    }
    val operationId = WorkspaceProtocol.operationId(values["operationId"])
    val workspaceId = WorkspaceProtocol.workspaceId(values["workspaceId"])
    val remainingMillis = WorkspaceProtocol.remainingMillis(values["remainingMillis"])
    if (!WorkspaceProtocol.hasVersion(values) || operationId == null || workspaceId == null ||
      remainingMillis == null
    ) {
      result.error("invalidRequest", null, null)
      return null
    }
    return OperationArguments(operationId, workspaceId, remainingMillis)
  }

  private fun tree(call: MethodCall, result: MethodChannel.Result): TreeAuthority? {
    val values = call.arguments as? Map<*, *> ?: run {
      result.error("invalidRequest", null, null)
      return null
    }
    val vault = WorkspaceProtocol.androidVaultEnvelope(values["envelope"]) ?: run {
      result.error("invalidRequest", null, null)
      return null
    }
    val uri = Uri.parse(vault.treeUri)
    if (uri.scheme != "content") {
      result.error("invalidRequest", null, null)
      return null
    }
    if (treeDocumentId(uri) == null) {
      result.error("invalidRequest", null, null)
      return null
    }
    return TreeAuthority(uri, vault)
  }

  private fun validExpectedRevision(value: Any?): Boolean {
    if (value == null) return true
    val revision = value as? Map<*, *> ?: return false
    val kind = revision["kind"] as? String ?: return false
    val revisionValue = revision["value"] as? String ?: return false
    if (revisionValue.isEmpty() || revisionValue.toByteArray(Charsets.UTF_8).size > 4_096 ||
      revisionValue.contains('\u0000')
    ) return false
    return when (kind) {
      "wholeContentSha256" -> revision.keys == setOf("kind", "value") &&
        revisionValue.matches(Regex("^[a-f0-9]{64}$"))
      "platform" -> {
        val namespace = revision["namespace"] as? String
        revision.keys == setOf("kind", "namespace", "value") && namespace != null &&
          namespace.isNotEmpty() && namespace.length <= 128 &&
          namespace.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' }
      }
      else -> false
    }
  }

  private fun callWorkspaceId(
    call: MethodCall,
    result: MethodChannel.Result,
  ): String? {
    val values = call.arguments as? Map<*, *>
    if (values == null || !WorkspaceProtocol.hasVersion(values) ||
      !WorkspaceProtocol.hasExactKeys(values, setOf("protocolVersion", "workspaceId"))
    ) {
      result.error("invalidRequest", null, null)
      return null
    }
    val workspaceId = WorkspaceProtocol.workspaceId(values["workspaceId"])
    if (workspaceId == null) result.error("invalidRequest", null, null)
    return workspaceId
  }

  private fun writeAcquisition(
    workspaceId: String,
    uri: Uri,
    phase: String,
    owned: Boolean,
    vault: AndroidVaultEnvelope,
  ): Boolean = grantJournal.writeAcquisition(
    workspaceId, uri.toString(), phase, owned, vault.generation, vault.rootId, vault.rootDigest,
  )

  private fun clearAcquisition(workspaceId: String): Boolean = grantJournal.clearAcquisition(workspaceId)

  private fun promoteAcquisition(workspaceId: String) {
    if (!grantJournal.promoteAcquisition(workspaceId)) throw NativeFailure("providerFailure")
  }

  private fun abandonAcquisition(workspaceId: String) {
    val acquisition = grantJournal.acquisition(workspaceId) ?: run {
      // A restore can establish an externally-owned logical lease before Dart
      // commits it. Abandoning that selection must also remove the lease so a
      // replacement authority is not fenced by stale private state.
      forgetWorkspace(workspaceId)
      return
    }
    val uri = Uri.parse(acquisition.uri)
    val owned = acquisition.owned
    if (uri != null && owned && hasPersistedRead(uri)) releaseRead(uri)
    if (!clearAcquisition(workspaceId)) throw NativeFailure("providerFailure")
    clearEntries(workspaceId)
  }

  private fun forgetWorkspace(workspaceId: String) {
    clearWorkspaceCursors(workspaceId)
    val active = grantJournal.active(workspaceId)
    if (active == null) {
      if (grantJournal.hasActiveState(workspaceId) && !grantJournal.clearActive(workspaceId)) {
        throw NativeFailure("providerFailure")
      }
      clearEntries(workspaceId)
      return
    }
    val replacement = activeWorkspaceIds().firstNotNullOfOrNull { otherId ->
      grantJournal.active(otherId)?.takeIf { otherId != workspaceId && it.uri == active.uri }?.let { otherId }
    }
    if (grantJournal.beginDeletion(workspaceId, replacement) == null) {
      throw NativeFailure("providerFailure")
    }
    completeDeletion(workspaceId)
  }

  private fun acquisitionIds(): Set<String> = grantJournal.acquisitionIDs()

  private fun activeWorkspaceIds(): Set<String> = grantJournal.activeWorkspaceIDs()

  private fun deletingWorkspaceIds(): Set<String> = grantJournal.deletingWorkspaceIDs()

  private fun clearWorkspaceCursors(workspaceId: String) {
    stateExecutor.call { cursors.entries.removeIf { (_, cursor) -> cursor.workspaceId == workspaceId } }
  }

  private fun reconcileLegacyGrantCleanup() {
    val records = grantJournal.stageLegacyCleanup() ?: throw NativeFailure("providerFailure")
    records.forEach { record ->
      if (record.owned) {
        val uri = Uri.parse(record.uri)
        if (hasPersistedRead(uri)) releaseRead(uri)
      }
      if (!grantJournal.finishLegacyCleanup(record)) throw NativeFailure("providerFailure")
    }
  }

  /** Retries a deletion left durable before a process death or SAF failure. */
  private fun completeDeletion(workspaceId: String) {
    val deletion = grantJournal.deleting(workspaceId) ?: return
    val replacementExists = activeWorkspaceIds().any { otherId ->
      grantJournal.active(otherId)?.let { other -> otherId != workspaceId && other.uri == deletion.uri } == true
    }
    if (deletion.owned && !replacementExists) {
      val uri = Uri.parse(deletion.uri)
      if (hasPersistedRead(uri)) releaseRead(uri)
    }
    if (!grantJournal.clearDeleting(workspaceId)) throw NativeFailure("providerFailure")
    clearEntries(workspaceId)
  }

  private fun hasPersistedRead(uri: Uri): Boolean =
    context.contentResolver.persistedUriPermissions.any {
      it.uri == uri && it.isReadPermission
    }

  private fun releaseRead(uri: Uri) {
    context.contentResolver.releasePersistableUriPermission(
      uri,
      Intent.FLAG_GRANT_READ_URI_PERMISSION,
    )
  }

  private fun clearEntries(workspaceId: String) {
    if (!entryStore.clearWorkspace(workspaceId)) throw NativeFailure("providerFailure")
  }

  private fun validatedDocumentUri(tree: Uri, documentId: String): Uri {
    val candidate = documentProvider.documentUri(tree, documentId)
    // buildDocumentUriUsingTree keeps the URI tree-scoped on every supported
    // API. The platform descendant check itself was added in API 29.
    if (!documentProvider.isDescendant(tree, documentId)) {
      throw NativeFailure("invalidReference")
    }
    return candidate
  }

  private fun issueEntries(
    workspaceId: String,
    parentId: String?,
    documentIds: Collection<String>,
    preferredIds: Map<String, String> = emptyMap(),
  ): Map<String, String>? = stateExecutor.call {
    issueEntriesLocked(workspaceId, parentId, documentIds, preferredIds)
  }

  private fun issueEntriesLocked(
    workspaceId: String,
    parentId: String?,
    documentIds: Collection<String>,
    preferredIds: Map<String, String>,
  ): Map<String, String>? {
    val records = entryStore.records(workspaceId) ?: return null
    val existing = records.entries
      .associate { (entryId, record) -> (record.parentId to record.documentId) to entryId }
    val issued = documentIds.distinct().associateWith { documentId ->
      existing[parentId to documentId] ?: preferredIds[documentId] ?: randomOpaqueId()
    }
    val projected = records.toMap() + issued.entries.associate { (documentId, entryId) ->
      entryId to EntryRecord(parentId, documentId)
    }
    if (projected.size > MAX_ENTRY_RECORDS || entryStoreBytes(workspaceId, projected) > MAX_ENTRY_BYTES) {
      return null
    }
    val additions = issued.entries.associate { (documentId, entryId) ->
      entryId to EntryRecord(parentId, documentId)
    }
    return if (entryStore.putRecords(workspaceId, additions)) issued else null
  }

  private fun randomOpaqueId(): String {
    val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    val bytes = ByteArray(22)
    SecureRandom().nextBytes(bytes)
    return bytes.joinToString("") { alphabet[(it.toInt() and 0x3f)].toString() }
  }

  private fun entryStoreBytes(workspaceId: String, records: Map<String, EntryRecord>): Long {
    val workspaceBytes = workspaceId.toByteArray(Charsets.UTF_8).size.toLong()
    return records.entries.sumOf { (entryId, record) ->
      workspaceBytes + entryId.toByteArray(Charsets.UTF_8).size.toLong() +
        (record.parentId?.toByteArray(Charsets.UTF_8)?.size?.toLong() ?: 0L) +
        record.documentId.toByteArray(Charsets.UTF_8).size.toLong() + ENTRY_RECORD_FIXED_BYTES
    }
  }

  private fun isSafeDisplayName(name: String): Boolean =
    name.isNotEmpty() && name.toByteArray(Charsets.UTF_8).size <= 4_096 &&
      !name.contains('\u0000') && !name.startsWith('/') && !name.startsWith('\\') &&
      !Regex("^[A-Za-z]:").containsMatchIn(name) && name != "." && name != ".." &&
      !name.contains('\\')

  private fun resolveEntry(workspaceId: String, stableId: String): EntryRecord? {
    val rootId = entryStore.rootDocumentId(workspaceId) ?: return null
    return EntryLineage.resolve(stableId, rootId) { entryId ->
      entryStore.record(workspaceId, entryId)
    }
  }

  /** Root document IDs are private store metadata, never public entry IDs. */
  private fun bindRoot(workspaceId: String, rootId: String, vault: AndroidVaultEnvelope): Boolean {
    if (!vault.rootDigest.contentEquals(rootDigest(Uri.parse(vault.treeUri)))) return false
    return entryStore.bindRoot(workspaceId, AndroidRootRecord(rootId, vault.generation, vault.rootId, vault.rootDigest))
  }

  private fun treeDocumentId(tree: Uri): String? {
    if (tree.scheme != "content") return null
    val segments = tree.pathSegments
    if (segments.size != 2 || segments[0] != "tree") return null
    return segments[1].takeIf { it.isNotEmpty() }
  }

  private fun matchesRoot(workspaceId: String, tree: TreeAuthority): Boolean {
    val record = entryStore.rootRecord(workspaceId) ?: return false
    val journal = grantJournal.active(workspaceId) ?: return false
    return record.documentId == treeDocumentId(tree.uri) && record.generation == tree.vault.generation &&
      record.rootId == tree.vault.rootId && record.digest.contentEquals(tree.vault.rootDigest) &&
      journal.uri == tree.vault.treeUri && journal.generation == tree.vault.generation &&
      journal.rootId == tree.vault.rootId && journal.digest.contentEquals(tree.vault.rootDigest) &&
      tree.vault.rootDigest.contentEquals(rootDigest(tree.uri))
  }

  private fun rootDigest(uri: Uri): ByteArray =
    MessageDigest.getInstance("SHA-256").digest(uri.normalizeScheme().toString().toByteArray(Charsets.UTF_8))

  private fun randomGeneration(): Long = SecureRandom().nextLong().and(Long.MAX_VALUE).coerceAtLeast(1)

  private data class OperationArguments(
    val operationId: String,
    val workspaceId: String,
    val remainingMillis: Long,
  )

  private class NativeFailure(code: String) : WorkspaceOperationFailure(code)

  private companion object {
    const val MAX_ENTRIES = 1_000
    const val MAX_SNAPSHOT_ENTRIES = 1_000
    const val MAX_ENTRY_RECORDS = 100_000
    const val MAX_ENTRY_BYTES = 16L * 1024 * 1024
    const val ENTRY_RECORD_FIXED_BYTES = 32L
    const val MAX_BYTES = 8 * 1024 * 1024
  }
}
