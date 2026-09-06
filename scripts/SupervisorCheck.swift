import Foundation

@main
struct SupervisorCheck {
    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for result in try await SupervisorScenarios.run(directory: directory) {
            print("OK · \(result)")
        }
    }
}
