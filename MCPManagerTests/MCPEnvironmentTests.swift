import XCTest
@testable import MCPManager

final class MCPEnvironmentTests: XCTestCase {
    func testScopedEnvironmentScenarios() async throws {
        let results = try await MCPEnvironmentScenarios.run()
        XCTAssertEqual(results.count, 4)
    }
}
