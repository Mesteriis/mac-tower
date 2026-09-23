import Foundation

public enum CodexAppServerProcessError: Error, Equatable {
    case invalidBinaryPath
    case unmanagedHome
    case alreadyRunning
    case notRunning
    case invalidMessage
}

public struct CodexAppServerProcessConfiguration: Sendable {
    public let binaryURL: URL
    public let homeURL: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(binaryURL: URL, homeURL: URL, managedAccountsRoot: URL) throws {
        guard binaryURL.isFileURL,
            binaryURL.baseURL == nil,
            binaryURL.path.hasPrefix("/")
        else {
            throw CodexAppServerProcessError.invalidBinaryPath
        }

        let root = managedAccountsRoot.standardizedFileURL.path
        let home = homeURL.standardizedFileURL.path
        guard home.hasPrefix(root + "/"), home != root else {
            throw CodexAppServerProcessError.unmanagedHome
        }

        self.binaryURL = binaryURL.standardizedFileURL
        self.homeURL = homeURL.standardizedFileURL
        arguments = ["app-server"]
        environment = [
            "CODEX_HOME": self.homeURL.path,
            "PATH": "/usr/bin:/bin",
        ]
    }
}

public final class CodexAppServerProcess: @unchecked Sendable {
    public typealias MessageHandler = @Sendable (Data) -> Void

    private let configuration: CodexAppServerProcessConfiguration
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()

    public init(configuration: CodexAppServerProcessConfiguration) {
        self.configuration = configuration
    }

    public func start(
        messageHandler: @escaping MessageHandler,
        terminationHandler: @escaping @Sendable () -> Void = {}
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { throw CodexAppServerProcessError.alreadyRunning }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = configuration.binaryURL
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data, handler: messageHandler)
        }
        process.terminationHandler = { _ in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            terminationHandler()
        }
        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting
    }

    public func send(_ message: Data) throws {
        guard message.last == 0x0A,
            (try? JSONSerialization.jsonObject(with: message.dropLast())) != nil
        else {
            throw CodexAppServerProcessError.invalidMessage
        }
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning == true, let input else {
            throw CodexAppServerProcessError.notRunning
        }
        try input.write(contentsOf: message)
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        input?.closeFile()
        input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private func consume(_ data: Data, handler: MessageHandler) {
        lock.lock()
        outputBuffer.append(data)
        var messages: [Data] = []
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let message = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            if !message.isEmpty { messages.append(Data(message)) }
        }
        lock.unlock()
        for message in messages { handler(message) }
    }

    deinit {
        stop()
    }
}

public struct CodexAppServerMessage: Equatable, Sendable {
    public struct RPCError: Equatable, Sendable {
        public let code: Int
        public let message: String
    }

    public let id: Int?
    public let method: String?
    public let result: JSONValue?
    public let params: JSONValue?
    public let error: RPCError?
}

public struct CodexAppServerMessageParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> CodexAppServerMessage {
        let root: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw CodexAppServerProcessError.invalidMessage
            }
            root = decoded
        } catch {
            throw CodexAppServerProcessError.invalidMessage
        }

        let rpcError: CodexAppServerMessage.RPCError?
        if let value = root["error"] as? [String: Any],
            let code = value["code"] as? Int,
            let message = value["message"] as? String
        {
            rpcError = .init(code: code, message: message)
        } else {
            rpcError = nil
        }

        return CodexAppServerMessage(
            id: root["id"] as? Int,
            method: root["method"] as? String,
            result: root["result"].map(JSONValue.init),
            params: root["params"].map(JSONValue.init),
            error: rpcError
        )
    }
}

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ value: Any) {
        switch value {
        case is NSNull: self = .null
        case let value as Bool: self = .bool(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map(JSONValue.init))
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    var jsonObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.jsonObject)
        case .object(let value): value.mapValues(\.jsonObject)
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }
}

public struct CodexRateLimitsResultDecoder: Sendable {
    public init() {}

    public func snapshot(
        from message: CodexAppServerMessage,
        accountID: AccountID,
        label: String,
        observedAt: Date
    ) throws -> AccountSnapshot {
        guard message.error == nil, let result = message.result else {
            throw CodexAppServerProcessError.invalidMessage
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: result.jsonObject)
        } catch {
            throw CodexAppServerProcessError.invalidMessage
        }
        return try CodexRateLimitsParser().parse(
            data,
            accountID: accountID,
            label: label,
            observedAt: observedAt
        )
    }
}
