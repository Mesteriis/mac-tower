import MacTowerCore
import Testing

@Suite("Daemon command-line parsing")
struct ServiceCommandTests {
    @Test("No arguments select the daemon")
    func noArguments() throws {
        #expect(try ServiceCommand.parse([]) == .run)
    }

    @Test("Help is accepted on its own")
    func help() throws {
        #expect(try ServiceCommand.parse(["--help"]) == .help)
    }

    @Test("Version is accepted on its own")
    func version() throws {
        #expect(try ServiceCommand.parse(["--version"]) == .version)
    }

    @Test(
        "Unknown, duplicated, and mixed arguments are rejected",
        arguments: [
            ["--unknown"],
            ["run"],
            [""],
            ["--"],
            ["--help", "--version"],
            ["--version", "--help"],
            ["--help", "--help"],
            ["--version", "--version"],
            ["--help", "extra"],
            ["extra", "--version"],
        ])
    func invalidArguments(arguments: [String]) {
        #expect(throws: ServiceCommandError.invalidArguments) {
            try ServiceCommand.parse(arguments)
        }
    }
}
