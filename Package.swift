// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "overseer",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "overseer", targets: ["overseer"])
  ],
  targets: [
    .executableTarget(
      name: "overseer",
      path: "App",
      sources: [
        "CLI",
        "Core",
      ]
    ),
    .testTarget(
      name: "OverseerTests",
      dependencies: ["overseer"],
      path: "Tests"
    ),
  ]
)
