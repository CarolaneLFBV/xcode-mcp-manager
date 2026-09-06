import XCTest
@testable import MCPManager

final class PresentationTests: XCTestCase {
    @MainActor
    func testFormScenarios() async throws {
        let results = try await PresentationScenarios.runForms()
        XCTAssertEqual(results.count, 3)
    }
    @MainActor
    func testSyntheticPresentationScenarios() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mcp-presentation-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try MCPCatalog.load(bundle: Bundle(for: MCPServerStore.self))
        XCTAssertEqual(try PresentationScenarios.run(catalog: catalog, directory: directory).count, 3)
    }
}
