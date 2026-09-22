import Darwin
import Foundation
import MacTowerCore

@main
struct MacTowerClaudeBridge {
    static func main() {
        if CommandLine.arguments.dropFirst() == ["--help"] {
            print(
                "Usage: mac-tower-claude-bridge --account-id ID --label LABEL --output-directory PATH"
            )
            return
        }

        do {
            let command = try ClaudeBridgeCommand.parse(Array(CommandLine.arguments.dropFirst()))
            let input = FileHandle.standardInput.readDataToEndOfFile()
            _ = try ClaudeBridgeProcessor().process(input, command: command)
        } catch {
            FileHandle.standardError.write(Data("mac-tower-claude-bridge: invalid input\n".utf8))
            exit(EX_DATAERR)
        }
    }
}
