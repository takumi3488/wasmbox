import AppKit
import SwiftUI
import wasmboxFeature

@main
struct WasmboxApp: App {
  @NSApplicationDelegateAdaptor(WasmboxApplicationDelegate.self) private var delegate
  @StateObject private var model = WasmboxAppModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .onAppear { delegate.model = model }
    }
  }
}

@MainActor
final class WasmboxApplicationDelegate: NSObject, NSApplicationDelegate {
  weak var model: WasmboxAppModel?

  func applicationDidFinishLaunching(_ notification: Notification) {
    if ProcessInfo.processInfo.environment["WASMBOX_HEADLESS_TEST"] == "1" {
      NSApp.hide(nil)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    model?.stopForApplicationTermination() ?? .terminateNow
  }
}
