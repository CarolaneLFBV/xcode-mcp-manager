import XCTest
@testable import MCPManager

final class XcodeManagementTests: XCTestCase {
    func testLifecycleAndRecoveryScenarios() async throws {
        let results = try await XcodeManagementScenarios.run()
        XCTAssertEqual(results.count, 7)
    }
}
