import Darwin
import Dispatch
import Foundation
import MacTowerCore
import MacTowerTransport
import OSLog

@main
struct MacTowerDaemon {
    private static let logger = Logger(subsystem: "dev.mactower", category: "daemon")

    static func main() {
        let command: ServiceCommand
        do {
            command = try ServiceCommand.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            writeError("Invalid arguments. Use --help for usage.")
            exit(EX_USAGE)
        }

        switch command {
        case .help:
            print(
                """
                Usage: mac-tower-daemon [--help | --version]

                With no arguments, run the Mac Tower daemon as root.
                --help       Show this help.
                --version    Show the version.

                Network publishing is disabled until configured through the menu bar app.
                """)
        case .version:
            print("mac-tower-daemon 0.1.0")
        case .run:
            run()
        }
    }

    private static func run() -> Never {
        guard geteuid() == 0 else {
            writeError("The daemon requires root. The menu bar app runs as the logged-in user.")
            exit(EX_NOPERM)
        }

        let runtime: DaemonNetworkRuntime
        let xpcServer: DaemonXPCServer
        do {
            let root = URL(
                fileURLWithPath: "/Library/Application Support/MacTower",
                isDirectory: true
            )
            let controller = try ManagementController(root: root)
            let windowControl = try WindowControlService(root: root)
            runtime = try DaemonNetworkRuntime(
                root: root, controller: controller, windowControl: windowControl)
            xpcServer = try DaemonXPCServer(
                controller: controller,
                windowControl: windowControl,
                trustManifestURL: URL(
                    fileURLWithPath: "/Library/Preferences/dev.mactower.trust.json")
            )
            xpcServer.start()
            try runtime.start()
        } catch {
            writeError("Failed to start service. Configuration or storage is invalid.")
            exit(EX_CONFIG)
        }

        // Let dispatch deliver these signals on the main queue, outside a signal handler.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource.setEventHandler {
            Task {
                await runtime.stop()
                logger.info("Daemon stopping after SIGTERM.")
                exit(EXIT_SUCCESS)
            }
        }

        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interruptSource.setEventHandler {
            Task {
                await runtime.stop()
                logger.info("Daemon stopping after SIGINT.")
                exit(EXIT_SUCCESS)
            }
        }

        terminationSource.resume()
        interruptSource.resume()
        logger.info("Daemon started.")

        // Keep signal sources alive while dispatch sleeps until an event arrives.
        withExtendedLifetime((terminationSource, interruptSource, runtime, xpcServer)) {
            dispatchMain()
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("mac-tower-daemon: \(message)\n".utf8))
    }
}
