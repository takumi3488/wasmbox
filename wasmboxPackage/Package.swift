// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "wasmboxFeature",
  platforms: [.macOS(.v15)],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "wasmboxFeature",
      targets: ["wasmboxFeature"]
    )
  ],
  targets: [
    .target(
      name: "WasmtimeShim",
      path: "Sources/WasmtimeShim",
      publicHeadersPath: "include"
    ),
    .target(
      name: "wasmboxFeature",
      dependencies: ["WasmtimeShim"],
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .testTarget(
      name: "wasmboxFeatureTests",
      dependencies: [
        "wasmboxFeature"
      ]
    ),
  ]
)
