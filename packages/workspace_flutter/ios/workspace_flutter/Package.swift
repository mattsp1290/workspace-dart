// swift-tools-version: 5.9
import PackageDescription

// Flutter discovers a plugin Swift package below ios/<plugin-name>.  CocoaPods
// consumes this target's source directory through the podspec, so production
// code has one physical home regardless of dependency manager.
let package = Package(
  name: "workspace_flutter",
  platforms: [.iOS("18.2")],
  products: [
    .library(name: "workspace-flutter", targets: ["workspace_flutter"]),
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "workspace_flutter",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ]
    ),
  ]
)
