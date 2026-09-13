import Foundation

/// Validates the app-private relative lineage stored behind an opaque entry ID.
enum WorkspaceLineage {
  static let maxDepth = 256

  static func components(_ relativePath: String) -> [Substring]? {
    let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count <= maxDepth,
          parts.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
    return parts
  }
}
