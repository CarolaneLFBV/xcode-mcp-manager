import XCTest
@testable import MCPManager

final class MCPCatalogTests: XCTestCase {
    func testBundledCatalogAndPresence() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "catalog", withExtension: "json"))
        XCTAssertEqual(try MCPCatalogScenarios.run(data: Data(contentsOf: url)).count, 3)
    }
}
