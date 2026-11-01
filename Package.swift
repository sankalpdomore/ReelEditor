// swift-tools-version:5.10
// Reel Editor for Mac: a native port of the ContentApp reel editor. ReelCore holds the edit decision list, the project
// files, the composition and the export, so the app and the MCP server run the same code on the same JSON files.
import PackageDescription

let package = Package(
  name: "ReelEditorMac",
  platforms: [.macOS("26.0")], // Liquid Glass (glassEffect, the glass button styles) is macOS 26 and later
  products: [
    .executable(name: "ReelEditor", targets: ["ReelEditor"]),
    .executable(name: "reel-mcp", targets: ["ReelMCP"]),
  ],
  targets: [
    .target(name: "ReelCore", path: "Sources/ReelCore"),
    .executableTarget(name: "ReelEditor", dependencies: ["ReelCore"], path: "Sources/ReelEditor"),
    .executableTarget(name: "ReelMCP", dependencies: ["ReelCore"], path: "Sources/ReelMCP"),
  ],
  swiftLanguageVersions: [.v5]
)
