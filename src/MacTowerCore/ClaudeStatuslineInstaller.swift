import Darwin
import Foundation

public enum ClaudeStatuslineInstallerError: Error, Equatable {
    case invalidSettings
    case invalidBridge
}

public struct ClaudeStatuslineInstaller: Sendable {
    private let settingsName = "settings.json"
    private let backupName = "mactower-statusline-backup.json"
    private let wrapperName = "mactower-statusline.sh"
    private let originalCommandName = "mactower-statusline-original.command"

    public init() {}

    @discardableResult
    public func install(
        configDirectory: URL,
        accountID: AccountID,
        label: String,
        outputDirectory: URL,
        bridgeURL: URL
    ) throws -> URL {
        guard bridgeURL.isFileURL, bridgeURL.path.hasPrefix("/") else {
            throw ClaudeStatuslineInstallerError.invalidBridge
        }
        _ = try AccountRegistration.claude(
            id: accountID,
            label: label,
            snapshotPath: outputDirectory.appending(path: "\(accountID.rawValue).json").path
        )

        let storage = try PrivateFileStore(root: configDirectory)
        var settings = try loadSettings(from: storage)
        let hasBackup = try storage.read(named: backupName) != nil
        if !hasBackup {
            let backup: [String: Any] = [
                "hadStatusLine": settings["statusLine"] != nil,
                "statusLine": settings["statusLine"] ?? NSNull(),
            ]
            try storage.write(
                try JSONSerialization.data(withJSONObject: backup, options: [.sortedKeys]),
                named: backupName
            )
            let originalCommand =
                (settings["statusLine"] as? [String: Any])?["command"] as? String
                ?? ""
            try storage.write(Data(originalCommand.utf8), named: originalCommandName)
        }

        let existing = settings["statusLine"] as? [String: Any]

        let wrapperURL = storage.root.appending(path: wrapperName)
        let originalCommandURL = storage.root.appending(path: originalCommandName)
        let wrapper = wrapperScript(
            bridgeURL: bridgeURL,
            accountID: accountID,
            label: label,
            outputDirectory: outputDirectory,
            originalCommandURL: originalCommandURL
        )
        try storage.write(Data(wrapper.utf8), named: wrapperName)
        guard chmod(wrapperURL.path, 0o700) == 0 else {
            throw PrivateFileStoreError.ioFailure
        }

        var statusLine = existing ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = wrapperURL.path
        settings["statusLine"] = statusLine
        try writeSettings(settings, to: storage)
        return outputDirectory.appending(path: "\(accountID.rawValue).json").standardizedFileURL
    }

    public func uninstall(configDirectory: URL) throws {
        let storage = try PrivateFileStore(root: configDirectory)
        guard let backupData = try storage.read(named: backupName),
            let backup = try JSONSerialization.jsonObject(with: backupData) as? [String: Any],
            let hadStatusLine = backup["hadStatusLine"] as? Bool
        else {
            return
        }

        var settings = try loadSettings(from: storage)
        if hadStatusLine, let original = backup["statusLine"], !(original is NSNull) {
            settings["statusLine"] = original
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings, to: storage)
        try storage.remove(named: wrapperName)
        try storage.remove(named: originalCommandName)
        try storage.remove(named: backupName)
    }

    private func loadSettings(from storage: PrivateFileStore) throws -> [String: Any] {
        guard let data = try storage.read(named: settingsName) else { return [:] }
        guard data.count <= 1_048_576,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ClaudeStatuslineInstallerError.invalidSettings
        }
        return object
    }

    private func writeSettings(_ settings: [String: Any], to storage: PrivateFileStore) throws {
        guard JSONSerialization.isValidJSONObject(settings) else {
            throw ClaudeStatuslineInstallerError.invalidSettings
        }
        try storage.write(
            try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
            named: settingsName
        )
    }

    private func wrapperScript(
        bridgeURL: URL,
        accountID: AccountID,
        label: String,
        outputDirectory: URL,
        originalCommandURL: URL
    ) -> String {
        """
        #!/bin/sh
        set -u
        input_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/mactower-statusline.XXXXXX")" || exit 1
        trap '/bin/rm -f "$input_file"' EXIT HUP INT TERM
        /bin/cat >"$input_file"
        \(shellQuote(bridgeURL.path)) --account-id \(shellQuote(accountID.rawValue)) --label \(shellQuote(label)) --output-directory \(shellQuote(outputDirectory.standardizedFileURL.path)) <"$input_file" >/dev/null 2>/dev/null || true
        if [ -s \(shellQuote(originalCommandURL.path)) ]; then
            original_command="$(/bin/cat \(shellQuote(originalCommandURL.path)))"
            /bin/sh -c "$original_command" <"$input_file"
        fi
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
