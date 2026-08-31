import AppKit
import SwiftUI
import wasmboxFeature

struct ContentView: View {
  @ObservedObject var model: WasmboxAppModel

  var body: some View {
    wasmboxFeature.ContentView(model: model)
      .onAppear { (NSApp.delegate as? WasmboxApplicationDelegate)?.model = model }
  }
}
