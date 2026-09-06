import Foundation

/// Standalone entry point for synthetic catalog tests, independent of XCTest hosting.
@main
struct CatalogCheck {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "MCPManager/Resources/catalog.json"))
        for result in try MCPCatalogScenarios.run(data: data) { print("OK · \(result)") }
    }
}
