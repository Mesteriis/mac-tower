/// The daemon's deliberately small command-line interface.
public enum ServiceCommand: Equatable, Sendable {
    case run
    case help
    case version

    /// Parses arguments after the executable name.
    public static func parse(_ arguments: [String]) throws -> Self {
        switch arguments {
        case []:
            return .run
        case ["--help"]:
            return .help
        case ["--version"]:
            return .version
        default:
            throw ServiceCommandError.invalidArguments
        }
    }
}

public enum ServiceCommandError: Error, Equatable, Sendable {
    case invalidArguments
}
