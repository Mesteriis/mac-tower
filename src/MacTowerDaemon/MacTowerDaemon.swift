import Darwin
import Dispatch
import Foundation
import MacTowerCore
import MacTowerPowerControl
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
        let powerControl: PowerControlService
        let notificationService: NotificationService?
        let lifecycle: DaemonLifecycle
        do {
            let root = URL(
                fileURLWithPath: "/Library/Application Support/MacTower",
                isDirectory: true
            )
            let controller = try ManagementController(root: root)
            let windowControl = try WindowControlService(root: root)
            do {
                notificationService = try NotificationService(root: root)
            } catch {
                notificationService = nil
                logger.error(
                    "Notifications unavailable because their private state is invalid; other subsystems continue."
                )
            }
            do {
                powerControl = try PowerControlService(root: root)
            } catch {
                powerControl = PowerControlService(
                    store: UnavailablePowerModeStore(),
                    backend: IOKitPowerAssertionBackend()
                )
                logger.error("Power settings unavailable; running without sleep assertions.")
            }
            runtime = try DaemonNetworkRuntime(
                root: root,
                controller: controller,
                windowControl: windowControl,
                notificationService: notificationService
            )
            xpcServer = try DaemonXPCServer(
                controller: controller,
                windowControl: windowControl,
                powerControl: powerControl,
                notificationService: notificationService,
                trustManifestURL: URL(
                    fileURLWithPath: "/Library/Preferences/dev.mactower.trust.json")
            )
            lifecycle = DaemonLifecycle(
                power: powerControl,
                network: runtime,
                notifications: notificationService
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
                await lifecycle.stop()
                logger.info("Daemon stopping after SIGTERM.")
                exit(EXIT_SUCCESS)
            }
        }

        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interruptSource.setEventHandler {
            Task {
                await lifecycle.stop()
                logger.info("Daemon stopping after SIGINT.")
                exit(EXIT_SUCCESS)
            }
        }

        terminationSource.resume()
        interruptSource.resume()
        logger.info("Daemon started.")

        // Keep signal sources alive while dispatch sleeps until an event arrives.
        withExtendedLifetime(
            (terminationSource, interruptSource, runtime, xpcServer, powerControl, lifecycle)
        ) {
            dispatchMain()
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("mac-tower-daemon: \(message)\n".utf8))
    }
}

private struct UnavailablePowerModeStore: PowerModeStore {
    private enum Failure: Error { case unavailable }

    func load() throws -> PowerMode? { throw Failure.unavailable }
    func save(_ mode: PowerMode) throws { throw Failure.unavailable }
}
