import XCTest
@testable import MCPManager

final class MCPOAuthTests: XCTestCase {
    @MainActor
    func testOAuthSecurityAndLifecycle() async throws {
        let result = try await MCPOAuthScenarios.run()
        XCTAssertEqual(result.count, 4)
    }
}
