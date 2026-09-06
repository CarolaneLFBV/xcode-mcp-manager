import XCTest
@testable import MCPManager

final class MCPLocalCredentialTests: XCTestCase {
    func testLocalSourceCredentials() throws {
        XCTAssertEqual(try MCPLocalCredentialScenarios.run().count, 3)
    }
}
