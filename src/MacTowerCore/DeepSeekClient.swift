import Foundation

public enum DeepSeekClientError: Error, Equatable {
    case emptyAPIKey
    case invalidResponse
    case unauthorized
    case serviceUnavailable(Int)
}

public struct DeepSeekRequestBuilder: Sendable {
    public init() {}

    public func balanceRequest(apiKey: String) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekClientError.emptyAPIKey
        }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func redactedDescription(of request: URLRequest) -> String {
        "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<invalid-url>") Authorization: <redacted>"
    }
}

public struct DeepSeekBalanceClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(
        apiKey: String,
        accountID: AccountID,
        label: String,
        observedAt: Date = Date()
    ) async throws -> AccountSnapshot {
        let request = try DeepSeekRequestBuilder().balanceRequest(apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw DeepSeekClientError.invalidResponse
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw DeepSeekClientError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw DeepSeekClientError.serviceUnavailable(response.statusCode)
        }
        return try DeepSeekBalanceParser().parse(
            data,
            accountID: accountID,
            label: label,
            observedAt: observedAt
        )
    }
}
