import Darwin
import Foundation
import MacTowerCore

public protocol NSPanelAddressResolving: Sendable {
    func resolveIPv4(host: String) async throws -> [String]
}

public protocol NSPanelHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public enum NSPanelPairingResult: Equatable, Sendable {
    case pressDone
    case paired(token: String)
}

public enum NSPanelClientError: Error, Equatable, Sendable {
    case addressResolutionFailed
    case unsafeAddress
    case invalidURL
    case invalidToken
    case timeout
    case transport
    case invalidResponse
    case redirect
    case httpStatus(Int)
    case responseTooLarge
    case invalidPayload
    case apiError(Int)
    case missingToken
}

public struct NSPanelClient: Sendable {
    public static let maximumResponseBytes = 65_536

    private let configuration: NSPanelConfiguration
    private let resolver: any NSPanelAddressResolving
    private let loader: any NSPanelHTTPDataLoading

    public init(
        configuration: NSPanelConfiguration,
        resolver: any NSPanelAddressResolving,
        loader: any NSPanelHTTPDataLoading
    ) {
        self.configuration = configuration
        self.resolver = resolver
        self.loader = loader
    }

    public static func live(configuration: NSPanelConfiguration) -> NSPanelClient {
        NSPanelClient(
            configuration: configuration,
            resolver: SystemNSPanelAddressResolver(),
            loader: URLSessionNSPanelDataLoader()
        )
    }

    public func pair() async throws -> NSPanelPairingResult {
        let request = try await request(
            path: "/open-api/v1/rest/bridge/access_token",
            queryItems: [URLQueryItem(name: "app_name", value: "MacTower")],
            method: "GET",
            token: nil,
            body: nil
        )
        let response: Response<TokenData> = try await load(request)
        if response.error == 401 {
            return .pressDone
        }
        guard response.error == 0 else {
            throw NSPanelClientError.apiError(response.error)
        }
        guard let token = response.data.token, !token.isEmpty else {
            throw NSPanelClientError.missingToken
        }
        return .paired(token: token)
    }

    public func wake(token: String) async throws {
        let request = try await request(
            path: "/open-api/v1/rest/screen/display/wake-up",
            method: "POST",
            token: token,
            body: nil
        )
        let response: Response<EmptyData> = try await load(request)
        try validateSuccess(response.error)
    }

    public func play(sound: NSPanelSound, token: String) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(
            SoundRequest(
                type: "play_sound",
                sound: SoundPayload(
                    name: sound.name.rawValue,
                    volume: sound.volume,
                    countdown: sound.countdownSeconds
                )
            ))
        let request = try await request(
            path: "/open-api/v1/rest/hardware/speaker",
            method: "POST",
            token: token,
            body: body
        )
        let response: Response<EmptyData> = try await load(request)
        try validateSuccess(response.error)
    }

    private func request(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String,
        token: String?,
        body: Data?
    ) async throws -> URLRequest {
        if let token, token.isEmpty {
            throw NSPanelClientError.invalidToken
        }
        let addresses: [String]
        do {
            addresses = try await resolver.resolveIPv4(host: configuration.host)
        } catch {
            throw NSPanelClientError.addressResolutionFailed
        }
        guard !addresses.isEmpty else {
            throw NSPanelClientError.addressResolutionFailed
        }
        guard addresses.allSatisfy(IPv4CIDR.isLocalHostAddress) else {
            throw NSPanelClientError.unsafeAddress
        }
        guard let address = addresses.sorted().first else {
            throw NSPanelClientError.addressResolutionFailed
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = address
        components.port = configuration.port
        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw NSPanelClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func load<Value: Decodable>(_ request: URLRequest) async throws -> Response<Value> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw NSPanelClientError.timeout
        } catch {
            throw NSPanelClientError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw NSPanelClientError.invalidResponse
        }
        guard !(300..<400).contains(http.statusCode) else {
            throw NSPanelClientError.redirect
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSPanelClientError.httpStatus(http.statusCode)
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw NSPanelClientError.responseTooLarge
        }
        do {
            return try JSONDecoder().decode(Response<Value>.self, from: data)
        } catch {
            throw NSPanelClientError.invalidPayload
        }
    }

    private func validateSuccess(_ error: Int) throws {
        guard error == 0 else {
            throw NSPanelClientError.apiError(error)
        }
    }
}

public struct SystemNSPanelAddressResolver: NSPanelAddressResolving {
    public init() {}

    public func resolveIPv4(host: String) async throws -> [String] {
        try Self.resolve(host: host)
    }

    private static func resolve(host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let head else {
            throw NSPanelClientError.addressResolutionFailed
        }
        defer { freeaddrinfo(head) }

        var addresses = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = head
        while let info = current {
            if let socketAddress = info.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let ipv4 = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                var mutableIPv4 = ipv4
                if inet_ntop(AF_INET, &mutableIPv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    addresses.insert(String(decoding: bytes, as: UTF8.self))
                }
            }
            current = info.pointee.ai_next
        }
        return addresses.sorted()
    }
}

public final class URLSessionNSPanelDataLoader: NSObject, NSPanelHTTPDataLoading,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private let session: URLSession

    public override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        super.init()
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request, delegate: self)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

private struct Response<Value: Decodable>: Decodable {
    let error: Int
    let data: Value
    let message: String
}

private struct TokenData: Decodable {
    let token: String?
}

private struct EmptyData: Decodable {}

private struct SoundRequest: Encodable {
    let type: String
    let sound: SoundPayload
}

private struct SoundPayload: Encodable {
    let name: String
    let volume: Int
    let countdown: Int
}
