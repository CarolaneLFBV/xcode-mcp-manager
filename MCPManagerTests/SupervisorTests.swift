import XCTest
@testable import MCPManager

final class SupervisorTests: XCTestCase {
    @MainActor
    func testSyntheticLifecycleScenarios() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mcp-supervisor-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try await SupervisorScenarios.run(directory: directory)
        XCTAssertEqual(results.count, 11)
    }
}
