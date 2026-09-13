// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "WorkspaceFlutterNative",
  platforms: [.iOS("18.2"), .macOS(.v13)],
  products: [
    .library(name: "WorkspaceFlutterNative", targets: ["WorkspaceFlutterNative"]),
  ],
  targets: [
    .target(name: "WorkspaceFlutterNative", path: "Classes/Internal"),
    .testTarget(name: "WorkspaceFlutterNativeTests", dependencies: ["WorkspaceFlutterNative"], path: "Tests"),
  ]
)
