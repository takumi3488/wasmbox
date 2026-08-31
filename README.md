# wasmbox - macOS App

A modern macOS application using a **workspace + SPM package** architecture for clean separation between app shell and feature code.

## Project Architecture

```
wasmbox/
├── wasmbox.xcworkspace/              # Open this file in Xcode
├── wasmbox.xcodeproj/                # App shell project
├── wasmbox/                          # App target (minimal)
│   ├── Assets.xcassets/                # App-level assets (icons, colors)
│   ├── wasmboxApp.swift              # App entry point
│   ├── WasmboxIntents.swift          # App Intents surface
│   └── wasmbox.xctestplan            # Test configuration
├── wasmboxPackage/                   # 🚀 Primary development area
│   ├── Package.swift                   # Package configuration
│   ├── Sources/wasmboxFeature/       # Your feature code
│   └── Tests/wasmboxFeatureTests/    # Unit tests
└── wasmboxUITests/                   # UI automation tests
```

## Key Architecture Points

### Workspace + SPM Structure
- **App Shell**: `wasmbox/` contains minimal app lifecycle code
- **Feature Code**: `wasmboxPackage/Sources/wasmboxFeature/` is where most development happens
- **Separation**: Business logic lives in the SPM package, app target just imports and displays it

### Buildable Folders (Xcode 16)
- Files added to the filesystem automatically appear in Xcode
- No need to manually add files to project targets
- Reduces project file conflicts in teams

### App Sandbox
The app runs unsandboxed (`Config/wasmbox.entitlements` is empty) so Workload host paths, WASI preopens, and the Apple `container` CLI work as specified. See `docs/adr/0013-app-sandbox-scope.md`.

## Development Notes

### Code Organization
Most development happens in `wasmboxPackage/Sources/wasmboxFeature/` - organize your code as you prefer.

### Public API Requirements
Types exposed to the app target need `public` access:
```swift
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        // Your view code
    }
}
```

### Adding Dependencies
Edit `wasmboxPackage/Package.swift` to add SPM dependencies:
```swift
dependencies: [
    .package(url: "https://github.com/example/SomePackage", from: "1.0.0")
],
targets: [
    .target(
        name: "wasmboxFeature",
        dependencies: ["SomePackage"]
    ),
]
```

### Test Structure
- **Unit Tests**: `wasmboxPackage/Tests/wasmboxFeatureTests/` (Swift Testing framework)
- **UI Tests**: `wasmboxUITests/` (XCUITest framework)
- **Test Plan**: `wasmbox.xctestplan` coordinates all tests

## Configuration

### XCConfig Build Settings
Build settings are managed through **XCConfig files** in `Config/`:
- `Config/Shared.xcconfig` - Common settings (bundle ID, versions, deployment target)
- `Config/Debug.xcconfig` - Debug-specific settings
- `Config/Release.xcconfig` - Release-specific settings
- `Config/Tests.xcconfig` - Test-specific settings

### App Sandbox & Entitlements
`Config/wasmbox.entitlements` is intentionally empty; the app is not sandboxed. Workload configuration (container mounts, WASI preopens) is the effective permission boundary.

## macOS-Specific Features

### Window Management
Add multiple windows and settings panels:
```swift
@main
struct WasmboxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        Settings {
            SettingsView()
        }
    }
}
```

### Asset Management
- **App-Level Assets**: `wasmbox/Assets.xcassets/` (app icon with multiple sizes, accent color)
- **Feature Assets**: Add `Resources/` folder to SPM package if needed

### SPM Package Resources
To include assets in your feature package:
```swift
.target(
    name: "wasmboxFeature",
    dependencies: [],
    resources: [.process("Resources")]
)
```

## Notes

### Generated with XcodeBuildMCP
This project was scaffolded using [XcodeBuildMCP](https://github.com/cameroncooke/XcodeBuildMCP), which provides tools for AI-assisted macOS development workflows.
