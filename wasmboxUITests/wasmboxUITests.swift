import XCTest

#if canImport(AppIntentsTesting)
import AppIntentsTesting

@available(macOS 27.0, *)
final class WasmboxUITests: XCTestCase {
  private var app: XCUIApplication!
  private var definitions: IntentDefinitions!
  private var databaseURL: URL!
  private var wasmURL: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wasmbox-e2e-\(UUID().uuidString).sqlite")
    wasmURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wasmbox-e2e-\(UUID().uuidString).wasm")
    try Data().write(to: wasmURL)
    app.launchEnvironment["WASMBOX_TEST_DB_URL"] = databaseURL.path
    app.launchEnvironment["WASMBOX_HEADLESS_TEST"] = "1"
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    definitions = IntentDefinitions(bundleIdentifier: "com.takumi3488.wasmbox")
  }

  override func tearDownWithError() throws {
    app.terminate()
    if let databaseURL {
      try? FileManager.default.removeItem(at: databaseURL)
      try? FileManager.default.removeItem(
        at: databaseURL.deletingPathExtension().appendingPathExtension("sqlite.backup"))
      try? FileManager.default.removeItem(at: wasmURL)
    }
  }

  func testWorkloadConfigurationFlowOutOfProcess() async throws {

    let name = "e2e-\(UUID().uuidString.prefix(8))"
    let create = definitions.intents["CreateWorkloadIntent"].makeIntent(
      name: name,
      source: wasmURL.path,
      kind: "wasm",
      mode: "once"
    )
    let created = try await create.run()
    let createdID: String = try created.value
    XCTAssertFalse(createdID.isEmpty)

    let listed = try await definitions.intents["ListWorkloadsIntent"].makeIntent().run()
    let names: [String] = try listed.value
    XCTAssertTrue(names.contains(name))

    let exported = try await definitions.intents["ExportWorkloadsIntent"].makeIntent().run()
    let exportJSON: String = try exported.value
    XCTAssertTrue(exportJSON.contains(name))
    XCTAssertFalse(exportJSON.contains("RunCreated"))
  }

  func testStatusIntentUsesDerivedStateWithoutOpeningUi() async throws {
    let name = "status-\(UUID().uuidString.prefix(8))"
    _ = try await definitions.intents["CreateWorkloadIntent"].makeIntent(
      name: name,
      source: wasmURL.path,
      kind: "wasm",
      mode: "once"
    ).run()

    let result = try await definitions.intents["WorkloadStatusIntent"].makeIntent(name: name).run()
    let status: String = try result.value
    XCTAssertEqual(status, "Stopped")
  }
  func testVisibleCreateFlowExposesAccessibleControls() throws {
    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))

    let visibleApp = XCUIApplication()
    visibleApp.launchEnvironment["WASMBOX_TEST_DB_URL"] = databaseURL.path
    visibleApp.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    visibleApp.launchEnvironment["WASMBOX_UI_TEST"] = "1"
    visibleApp.launch()
    defer { visibleApp.terminate() }

    let newWorkload = visibleApp.buttons["new-workload"]
    XCTAssertTrue(newWorkload.waitForExistence(timeout: 5))
    newWorkload.click()

    let name = visibleApp.textFields["workload-name"]
    let source = visibleApp.textFields["workload-source"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertTrue(source.exists)
    name.click()
    name.typeText("ui-e2e")
    source.click()
    source.typeText(wasmURL.path)
    visibleApp.buttons["create-workload"].click()

    let createdRow = visibleApp.descendants(matching: .any)["workload-ui-e2e"]
    XCTAssertTrue(createdRow.waitForExistence(timeout: 5))
  }
}
#endif
