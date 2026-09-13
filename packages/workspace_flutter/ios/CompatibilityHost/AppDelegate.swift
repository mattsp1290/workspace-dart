import Flutter
import UIKit
import workspace_flutter

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  private var engine: FlutterEngine?
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let engine = FlutterEngine(name: "WorkspaceCompatibilityHost")
    engine.run()
    guard let registrar = engine.registrar(forPlugin: "WorkspaceFlutterPlugin") else {
      return false
    }
    WorkspaceFlutterPlugin.register(with: registrar)
    self.engine = engine

    let window = UIWindow(frame: UIScreen.main.bounds)
    let controller = UIViewController()
    controller.view.backgroundColor = .systemBackground
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}
