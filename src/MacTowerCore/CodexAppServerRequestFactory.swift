import Foundation

public struct CodexAppServerRequestFactory: Sendable {
    public init() {}

    public func initialize(id: Int) throws -> Data {
        try encode(
            id: id,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "mac-tower",
                    "title": "MacTower",
                    "version": "0.1.0",
                ]
            ]
        )
    }

    public func initialized() throws -> Data {
        try encodeNotification(method: "initialized")
    }

    public func rateLimits(id: Int) throws -> Data {
        try encode(id: id, method: "account/rateLimits/read")
    }

    public func readAccount(id: Int, refreshToken: Bool = false) throws -> Data {
        try encode(id: id, method: "account/read", params: ["refreshToken": refreshToken])
    }

    public func startChatGPTLogin(id: Int) throws -> Data {
        try encode(id: id, method: "account/login/start", params: ["type": "chatgpt"])
    }

    public func cancelLogin(id: Int, loginID: String) throws -> Data {
        try encode(id: id, method: "account/login/cancel", params: ["loginId": loginID])
    }

    public func logout(id: Int) throws -> Data {
        try encode(id: id, method: "account/logout")
    }

    private func encode(id: Int, method: String, params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = ["id": id, "method": method]
        if let params { object["params"] = params }
        return try newlineTerminatedJSON(object)
    }

    private func encodeNotification(method: String) throws -> Data {
        try newlineTerminatedJSON(["method": method])
    }

    private func newlineTerminatedJSON(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }
}
