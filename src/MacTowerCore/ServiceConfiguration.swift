import Darwin
import Foundation

public enum ServiceConfigurationError: Error, Equatable {
    case invalidPollInterval
    case invalidStaleInterval
    case invalidCIDR
    case invalidAccountID
    case invalidPort
    case invalidHost
    case invalidTopic
    case invalidPublicationSelection
}

public enum PublishedSensorField: String, CaseIterable, Codable, Hashable, Sendable {
    case quotaUsed = "quota_used"
    case quotaRemaining = "quota_remaining"
    case quotaWindowDuration = "quota_window_duration"
    case quotaResetsAt = "quota_resets_at"
    case resetCredits = "reset_credits"
    case balanceTotal = "balance_total"
    case balanceGranted = "balance_granted"
    case balanceToppedUp = "balance_topped_up"
}

public struct PublicationSelection: Codable, Equatable, Sendable {
    /// `nil` publishes every connected account, including accounts added later.
    public var accountIDs: Set<AccountID>?
    public var fields: Set<PublishedSensorField>

    public init(
        accountIDs: Set<AccountID>? = nil,
        fields: Set<PublishedSensorField> = Set(PublishedSensorField.allCases)
    ) throws {
        if let accountIDs {
            for id in accountIDs {
                guard id.rawValue.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil
                else { throw ServiceConfigurationError.invalidPublicationSelection }
            }
        }
        self.accountIDs = accountIDs
        self.fields = fields
    }

    public func includes(accountID: AccountID) -> Bool {
        accountIDs?.contains(accountID) ?? true
    }

    public func includes(_ field: PublishedSensorField) -> Bool {
        fields.contains(field)
    }

    public static var all: PublicationSelection {
        // Construction cannot fail for the built-in field set.
        try! PublicationSelection()
    }
}

public struct HTTPServiceConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var bindAddress: String
    public var port: Int
    public var allowedNetworks: [IPv4CIDR]

    public init(
        enabled: Bool = false,
        bindAddress: String = "127.0.0.1",
        port: Int = 8787,
        allowedNetworks: [IPv4CIDR] = []
    ) throws {
        guard (1...65_535).contains(port) else { throw ServiceConfigurationError.invalidPort }
        self.enabled = enabled
        self.bindAddress = bindAddress
        self.port = port
        self.allowedNetworks = allowedNetworks
    }
}

public struct MQTTServiceConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var username: String?
    public var passwordSecretName: String?
    public var topicPrefix: String

    public init(
        enabled: Bool = false,
        host: String = "localhost",
        port: Int = 1883,
        useTLS: Bool = false,
        username: String? = nil,
        passwordSecretName: String? = nil,
        topicPrefix: String = "mac_tower"
    ) throws {
        guard (1...65_535).contains(port) else { throw ServiceConfigurationError.invalidPort }
        guard host.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9.-]{0,252}/) != nil else {
            throw ServiceConfigurationError.invalidHost
        }
        guard !enabled || Self.isLocalBroker(host) else {
            throw ServiceConfigurationError.invalidHost
        }
        guard topicPrefix.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}/) != nil,
            !topicPrefix.contains("//")
        else {
            throw ServiceConfigurationError.invalidTopic
        }
        self.enabled = enabled
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
        self.passwordSecretName = passwordSecretName
        self.topicPrefix = topicPrefix
    }

    private static func isLocalBroker(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized.hasSuffix(".local")
            || !normalized.contains(".")
        {
            return true
        }
        guard let address = IPv4CIDR.parseHostAddress(normalized) else { return false }
        return IPv4CIDR.localAddressRanges.contains { address >= $0.start && address <= $0.end }
    }
}

public struct ServiceConfiguration: Codable, Equatable, Sendable {
    public var pollIntervalSeconds: Int
    public var staleAfterSeconds: Int
    public var http: HTTPServiceConfiguration
    public var mqtt: MQTTServiceConfiguration
    public var publication: PublicationSelection

    public init(
        pollIntervalSeconds: Int = 300,
        staleAfterSeconds: Int? = nil,
        http: HTTPServiceConfiguration? = nil,
        mqtt: MQTTServiceConfiguration? = nil,
        publication: PublicationSelection = .all
    ) throws {
        guard (60...86_400).contains(pollIntervalSeconds) else {
            throw ServiceConfigurationError.invalidPollInterval
        }
        let resolvedStaleAfter = staleAfterSeconds ?? pollIntervalSeconds * 3
        guard resolvedStaleAfter >= pollIntervalSeconds,
            resolvedStaleAfter <= 604_800
        else {
            throw ServiceConfigurationError.invalidStaleInterval
        }
        self.pollIntervalSeconds = pollIntervalSeconds
        self.staleAfterSeconds = resolvedStaleAfter
        self.http = try http ?? HTTPServiceConfiguration()
        self.mqtt = try mqtt ?? MQTTServiceConfiguration()
        self.publication = try PublicationSelection(
            accountIDs: publication.accountIDs,
            fields: publication.fields
        )
    }

    public static func decodeValidated(_ data: Data) throws -> ServiceConfiguration {
        let decoded: PersistedServiceConfiguration
        do {
            decoded = try JSONDecoder().decode(PersistedServiceConfiguration.self, from: data)
        } catch {
            throw ServiceConfigurationError.invalidPollInterval
        }
        return try ServiceConfiguration(
            pollIntervalSeconds: decoded.pollIntervalSeconds,
            staleAfterSeconds: decoded.staleAfterSeconds,
            http: HTTPServiceConfiguration(
                enabled: decoded.http.enabled,
                bindAddress: decoded.http.bindAddress,
                port: decoded.http.port,
                allowedNetworks: decoded.http.allowedNetworks
            ),
            mqtt: MQTTServiceConfiguration(
                enabled: decoded.mqtt.enabled,
                host: decoded.mqtt.host,
                port: decoded.mqtt.port,
                useTLS: decoded.mqtt.useTLS,
                username: decoded.mqtt.username,
                passwordSecretName: decoded.mqtt.passwordSecretName,
                topicPrefix: decoded.mqtt.topicPrefix
            ),
            publication: decoded.publication ?? .all
        ).validateForActivation()
    }

    @discardableResult
    public func validateForActivation() throws -> ServiceConfiguration {
        if http.enabled {
            guard !http.allowedNetworks.isEmpty,
                http.allowedNetworks.allSatisfy(\.isLocalNetwork),
                http.allowedNetworks.contains(where: { $0.contains(http.bindAddress) })
            else {
                throw ServiceConfigurationError.invalidCIDR
            }
        }
        return self
    }
}

private struct PersistedServiceConfiguration: Decodable {
    struct HTTP: Decodable {
        let enabled: Bool
        let bindAddress: String
        let port: Int
        let allowedNetworks: [IPv4CIDR]
    }

    struct MQTT: Decodable {
        let enabled: Bool
        let host: String
        let port: Int
        let useTLS: Bool
        let username: String?
        let passwordSecretName: String?
        let topicPrefix: String
    }

    let pollIntervalSeconds: Int
    let staleAfterSeconds: Int
    let http: HTTP
    let mqtt: MQTT
    let publication: PublicationSelection?
}

extension ServiceConfiguration {
    public func applyingMQTTSecretPolicy(
        existingSecretName: String?,
        replacementPassword: String?
    ) -> ServiceConfiguration {
        var result = self
        if let replacementPassword {
            result.mqtt.passwordSecretName = replacementPassword.isEmpty ? nil : "mqtt-password"
        } else {
            result.mqtt.passwordSecretName = existingSecretName
        }
        return result
    }
}

public struct IPv4CIDR: Codable, Equatable, Hashable, Sendable {
    public let network: UInt32
    public let prefixLength: UInt8

    public init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let prefix = UInt8(parts[1]),
            prefix <= 32,
            let address = Self.parseAddress(String(parts[0]))
        else {
            throw ServiceConfigurationError.invalidCIDR
        }

        prefixLength = prefix
        network = address & Self.mask(prefixLength: prefix)
    }

    public func contains(_ address: String) -> Bool {
        guard let parsed = Self.parseAddress(address) else { return false }
        return parsed & Self.mask(prefixLength: prefixLength) == network
    }

    public var description: String {
        return
            "\((network >> 24) & 0xff).\((network >> 16) & 0xff).\((network >> 8) & 0xff).\(network & 0xff)/\(prefixLength)"
    }

    public var isLocalNetwork: Bool {
        let end = network | ~Self.mask(prefixLength: prefixLength)
        return Self.localAddressRanges.contains { block in
            network >= block.start && end <= block.end
        }
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    fileprivate static func parseHostAddress(_ value: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func parseAddress(_ value: String) -> UInt32? {
        parseHostAddress(value)
    }

    private static func mask(prefixLength: UInt8) -> UInt32 {
        guard prefixLength > 0 else { return 0 }
        return UInt32.max << (32 - UInt32(prefixLength))
    }

    fileprivate static let localAddressRanges: [(start: UInt32, end: UInt32)] = [
        (0x0A00_0000, 0x0AFF_FFFF),
        (0xAC10_0000, 0xAC1F_FFFF),
        (0xC0A8_0000, 0xC0A8_FFFF),
        (0x7F00_0000, 0x7FFF_FFFF),
        (0xA9FE_0000, 0xA9FE_FFFF),
    ]
}

public struct ManagedAccountPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func directory(for id: AccountID) throws -> URL {
        guard id.rawValue.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil else {
            throw ServiceConfigurationError.invalidAccountID
        }
        return root.appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    public func removeDirectory(for id: AccountID) throws {
        let directory = try directory(for: id)
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw PrivateFileStoreError.ioFailure
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw PrivateFileStoreError.ioFailure
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw PrivateFileStoreError.ioFailure
        }
    }
}

public struct PollPolicy: Sendable {
    public let intervalSeconds: Int
    public let retryBaseSeconds: Int

    public init(intervalSeconds: Int, retryBaseSeconds: Int = 5) {
        self.intervalSeconds = intervalSeconds
        self.retryBaseSeconds = retryBaseSeconds
    }

    public var delayAfterSuccess: Int { intervalSeconds }

    public func delay(afterConsecutiveFailures failures: Int) -> Int {
        guard failures > 0 else { return intervalSeconds }
        let exponent = min(failures - 1, 20)
        let multiplied = retryBaseSeconds.multipliedReportingOverflow(by: 1 << exponent)
        return min(intervalSeconds, multiplied.overflow ? intervalSeconds : multiplied.partialValue)
    }
}
