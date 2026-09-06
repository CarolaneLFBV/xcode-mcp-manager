import XCTest
@testable import MCPManager

final class MCPSidebarTests: XCTestCase {
    func testSidebarScenarios() throws {
        XCTAssertEqual(try MCPSidebarScenarios.run().count, 3)
    }
}
