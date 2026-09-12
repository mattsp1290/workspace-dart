package com.mattsp1290.workspace_flutter

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.result.ActivityResult
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/** Read-only SAF bridge. Tree URIs only cross the trusted Dart vault seam. */
class WorkspaceFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
  private lateinit var channel: MethodChannel
  private var activity: Activity? = null
  private var pending: MethodChannel.Result? = null
  private val requestCode = 9182

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "workspace_flutter/read_only")
    channel.setMethodCallHandler(this)
  }
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) { pending?.error("cancelled", null, null); pending = null; channel.setMethodCallHandler(null) }
  override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity; binding.addActivityResultListener { code, result, data -> handleResult(code, result, data) } }
  override fun onDetachedFromActivityForConfigChanges() { activity = null }
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { onAttachedToActivity(binding) }
  override fun onDetachedFromActivity() { activity = null; pending?.error("cancelled", null, null); pending = null }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "selectDirectory" -> select(result)
      "restore" -> root(call, result)
      "list" -> list(call, result)
      "read" -> read(call, result)
      "cancelAll" -> { pending?.error("cancelled", null, null); pending = null; result.success(null) }
      else -> result.notImplemented()
    }
  }
  private fun select(result: MethodChannel.Result) {
    val host = activity ?: return result.error("unsupported", "No activity attached", null)
    if (pending != null) return result.error("providerFailure", "Picker already active", null)
    pending = result
    host.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION), requestCode)
  }
  private fun handleResult(code: Int, resultCode: Int, data: Intent?): Boolean {
    if (code != requestCode) return false
    val reply = pending ?: return true; pending = null
    val uri = data?.data
    if (resultCode != Activity.RESULT_OK || uri == null) { reply.success(null); return true }
    try { activity!!.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION); reply.success(uri.toString().toByteArray()) }
    catch (_: SecurityException) { reply.error("permissionLost", null, null) }
    return true
  }
  private fun tree(call: MethodCall): Uri? = (call.argument<ByteArray>("envelope") ?: return null).let { Uri.parse(String(it, Charsets.UTF_8)) }
  private fun root(call: MethodCall, result: MethodChannel.Result) {
    val uri = tree(call) ?: return result.error("permissionLost", null, null)
    try { val id = DocumentsContract.getTreeDocumentId(uri); result.success(mapOf("token" to id, "name" to "workspace")) }
    catch (_: Exception) { result.error("permissionLost", null, null) }
  }
  private fun list(call: MethodCall, result: MethodChannel.Result) {
    val uri = tree(call) ?: return result.error("permissionLost", null, null)
    val parent = call.argument<String>("directoryToken") ?: return result.error("invalidReference", null, null)
    val max = call.argument<Int>("maxEntries") ?: 0
    val rows = mutableListOf<Map<String, Any>>()
    try {
      activity!!.contentResolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(uri, parent), arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE), null, null, null)?.use { cursor ->
        while (cursor.moveToNext() && rows.size < max) { val mime = cursor.getString(2); rows.add(mapOf("token" to cursor.getString(0), "name" to cursor.getString(1), "type" to if (mime == DocumentsContract.Document.MIME_TYPE_DIR) "directory" else "file", "byteLength" to cursor.getLong(3))) }
      } ?: return result.error("providerFailure", null, null)
      result.success(mapOf("entries" to rows, "completion" to "complete", "consistency" to "unverified", "usedEntries" to rows.size, "usedBytes" to 0))
    } catch (_: SecurityException) { result.error("permissionLost", null, null) } catch (_: Exception) { result.error("providerFailure", null, null) }
  }
  private fun read(call: MethodCall, result: MethodChannel.Result) {
    val tree = tree(call) ?: return result.error("permissionLost", null, null); val id = call.argument<String>("fileToken") ?: return result.error("invalidReference", null, null)
    val offset = call.argument<Int>("offset")?.toLong() ?: 0; val count = call.argument<Int>("count") ?: 0; if (count < 0 || offset < 0) return result.error("invalidRequest", null, null)
    try { activity!!.contentResolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, id))?.use { input -> input.skip(offset); val bytes = input.readNBytes(count); result.success(mapOf("bytes" to bytes, "offset" to offset, "eof" to bytes.size < count, "actualRevision" to "native-unverified", "stability" to "unverified")) } ?: result.error("unavailable", null, null) }
    catch (_: SecurityException) { result.error("permissionLost", null, null) } catch (_: Exception) { result.error("providerFailure", null, null) }
  }
}
