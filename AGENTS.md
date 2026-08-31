# wasmbox

wasmbox is a SwiftUI macOS app scaffolded with XcodeBuildMCP.

## Project Layout

- `wasmbox.xcworkspace` — build/open this workspace (scheme: `wasmbox`)
- `wasmbox.xcodeproj` — thin app shell project
- `wasmbox/` — app entry point, assets, and test plan
- `wasmboxPackage/` — SwiftPM package holding the app code (`Sources/wasmboxFeature`) and unit tests (`Tests/wasmboxFeatureTests`)
- `wasmboxUITests/` — XCUITest UI tests
- `Config/` — xcconfig build settings and entitlements

Put feature code in `wasmboxPackage/Sources/wasmboxFeature` and keep the app target a thin shell.

## Build / Test / Run

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.
- Use the `xcodebuildmcp` CLI (skill: `.claude/skills/xcodebuildmcp-cli/SKILL.md`) instead of raw `xcodebuild` / `xcrun` / `simctl`.
- Install it if missing: `brew tap getsentry/xcodebuildmcp && brew install xcodebuildmcp`, or `npm install -g xcodebuildmcp@2.7.0`.
- Examples:
  - `xcodebuildmcp macos build-and-run --workspace-path wasmbox.xcworkspace --scheme wasmbox`
  - `xcodebuildmcp macos test --workspace-path wasmbox.xcworkspace --scheme wasmbox`


## End-to-End Testing

- For end-to-end tests of App Intents and system integrations, use [AppIntentsTesting](https://developer.apple.com/documentation/AppIntentsTesting) to run tests out of process without occupying the screen.

## Formatting

- Run `swift format format --in-place --recursive wasmbox wasmboxPackage/Sources wasmboxPackage/Tests wasmboxPackage/Package.swift wasmboxUITests` (also runs automatically via the Claude Code / OMP post-edit hooks).
