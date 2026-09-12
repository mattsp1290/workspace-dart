import Flutter
import UIKit

public final class WorkspaceFlutterPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private var channel: FlutterMethodChannel!
  private var pickerResult: FlutterResult?
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = WorkspaceFlutterPlugin()
    instance.channel = FlutterMethodChannel(name: "workspace_flutter/read_only", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: instance.channel)
  }
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "selectDirectory": select(result)
    case "restore": restore(call, result: result)
    case "cancelAll": pickerResult?(FlutterError(code: "cancelled", message: nil, details: nil)); pickerResult = nil; result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }
  private func select(_ result: @escaping FlutterResult) {
    guard pickerResult == nil, let controller = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first?.rootViewController }).first else { result(FlutterError(code: "unsupported", message: nil, details: nil)); return }
    pickerResult = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    picker.allowsMultipleSelection = false; picker.delegate = self; controller.present(picker, animated: true)
  }
  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { pickerResult?(nil); pickerResult = nil }
  public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    defer { pickerResult = nil }; guard let url = urls.first else { pickerResult?(nil); return }
    do { pickerResult?(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)) }
    catch { pickerResult?(FlutterError(code: "providerFailure", message: nil, details: nil)) }
  }
  private func restore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any], let data = arguments["envelope"] as? FlutterStandardTypedData else { result(FlutterError(code: "permissionLost", message: nil, details: nil)); return }
    var stale = false
    do { let url = try URL(resolvingBookmarkData: data.data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale); guard !stale && url.startAccessingSecurityScopedResource() else { result(FlutterError(code: "permissionLost", message: nil, details: nil)); return }; defer { url.stopAccessingSecurityScopedResource() }; result(["token": "root", "name": url.lastPathComponent]) }
    catch { result(FlutterError(code: "permissionLost", message: nil, details: nil)) }
  }
}
