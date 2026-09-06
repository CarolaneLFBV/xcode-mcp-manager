import XCTest
@testable import MCPManager

final class XcodeProjectTests: XCTestCase {
    func testProjectDiscoveryScenarios() async throws {
        let results = try await XcodeProjectScenarios.run()
        XCTAssertEqual(results.count, 4)
    }
}
