import Foundation
import Testing

@testable import MacTowerCore
@testable import MacTowerTransport

@Suite("Safe NSPanel local client")
struct NSPanelClientTests {
    @Test("Pairing maps press-Done and paired envelopes")
    func pairing() async throws {
        let pressLoader = RecordingPanelLoader(
            result: .success(httpResponse(pairingBody(error: 401))))
        let pressClient = client(loader: pressLoader)
        #expect(try await pressClient.pair() == .pressDone)

        let tokenLoader = RecordingPanelLoader(
            result: .success(httpResponse(pairingBody(error: 0, token: "panel-token"))))
        let tokenClient = client(loader: tokenLoader)
        #expect(try await tokenClient.pair() == .paired(token: "panel-token"))

        let request = try #require(await tokenLoader.recordedRequests().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "192.168.1.20")
        #expect(request.url?.port == 8081)
        #expect(request.url?.path == "/open-api/v1/rest/bridge/access_token")
        #expect(request.url?.query == "app_name=MacTower")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Wake is an authenticated bodyless POST to the pinned numeric address")
    func wakeRequest() async throws {
        let loader = RecordingPanelLoader(result: .success(httpResponse(successBody)))
        let client = client(host: "panel.local", addresses: ["192.168.1.21"], loader: loader)

        try await client.wake(token: "top-secret")

        let request = try #require(await loader.recordedRequests().first)
        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString
                == "http://192.168.1.21:8081/open-api/v1/rest/screen/display/wake-up")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer top-secret")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("Sound request has the exact official JSON body")
    func soundRequest() async throws {
        let loader = RecordingPanelLoader(result: .success(httpResponse(successBody)))
        let client = client(loader: loader)

        try await client.play(
            sound: NSPanelSound(name: .alert1, volume: 50, countdownSeconds: 3),
            token: "token"
        )

        let request = try #require(await loader.recordedRequests().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/open-api/v1/rest/hardware/speaker")
        #expect(
            String(decoding: try #require(request.httpBody), as: UTF8.self)
                == #"{"sound":{"countdown":3,"name":"alert1","volume":50},"type":"play_sound"}"#)
    }

    @Test("Resolution rejects public, mixed, and missing IPv4 answers")
    func unsafeResolution() async {
        let loader = RecordingPanelLoader(result: .success(httpResponse(successBody)))

        for addresses in [["8.8.8.8"], ["192.168.1.20", "8.8.8.8"]] {
            let client = client(addresses: addresses, loader: loader)
            await #expect(throws: NSPanelClientError.unsafeAddress) {
                try await client.wake(token: "token")
            }
        }
        let missing = client(addresses: [], loader: loader)
        await #expect(throws: NSPanelClientError.addressResolutionFailed) {
            try await missing.wake(token: "token")
        }
        #expect(await loader.recordedRequests().isEmpty)
    }

    @Test("Every operation re-resolves and selects the sorted first private address")
    func resolutionPinning() async throws {
        let resolver = SequencePanelResolver([
            ["192.168.1.30", "192.168.1.20"],
            ["192.168.1.31"],
        ])
        let loader = RecordingPanelLoader(result: .success(httpResponse(successBody)))
        let client = NSPanelClient(
            configuration: NSPanelConfiguration(host: "panel.local", port: 8081),
            resolver: resolver,
            loader: loader
        )

        try await client.wake(token: "token")
        try await client.wake(token: "token")

        let requests = await loader.recordedRequests()
        #expect(requests.map(\.url?.host) == ["192.168.1.20", "192.168.1.31"])
        #expect(await resolver.callCount() == 2)
    }

    @Test("Redirect, non-HTTP, oversized, invalid JSON, API errors, and timeout are finite")
    func finiteFailures() async {
        let cases: [(PanelLoadResult, NSPanelClientError)] = [
            (.success(httpResponse(successBody, status: 302)), .redirect),
            (
                .success(
                    (
                        successBody,
                        URLResponse(
                            url: panelURL, mimeType: nil, expectedContentLength: 0,
                            textEncodingName: nil)
                    )),
                .invalidResponse
            ),
            (
                .success(
                    httpResponse(Data(repeating: 0, count: NSPanelClient.maximumResponseBytes + 1))),
                .responseTooLarge
            ),
            (.success(httpResponse(Data("not-json".utf8))), .invalidPayload),
            (.success(httpResponse(apiErrorBody)), .apiError(500)),
            (.failure(URLError(.timedOut)), .timeout),
        ]

        for (result, expected) in cases {
            let client = client(loader: RecordingPanelLoader(result: result))
            await #expect(throws: expected) {
                try await client.wake(token: "token")
            }
        }
    }

    @Test("Errors redact bearer tokens and response bodies")
    func errorsAreRedacted() async {
        let secretToken = "secret-bearer-value"
        let secretBody = Data(
            #"{"error":777,"data":{},"message":"private-response-content"}"#.utf8)
        let client = client(
            loader: RecordingPanelLoader(result: .success(httpResponse(secretBody))))

        do {
            try await client.wake(token: secretToken)
            Issue.record("Expected API failure")
        } catch {
            let description = String(describing: error)
            #expect(!description.contains(secretToken))
            #expect(!description.contains("private-response-content"))
            #expect(error as? NSPanelClientError == .apiError(777))
        }
    }

    private func client(
        host: String = "192.168.1.20",
        addresses: [String] = ["192.168.1.20"],
        loader: RecordingPanelLoader
    ) -> NSPanelClient {
        NSPanelClient(
            configuration: NSPanelConfiguration(host: host, port: 8081),
            resolver: FixedPanelResolver(addresses: addresses),
            loader: loader
        )
    }

    private func pairingBody(error: Int, token: String? = nil) -> Data {
        let tokenValue = token.map { #""\#($0)""# } ?? "null"
        return Data(
            #"{"data":{"token":\#(tokenValue)},"error":\#(error),"message":"ignored"}"#.utf8)
    }

    private var successBody: Data {
        Data(#"{"data":{},"error":0,"message":"ok"}"#.utf8)
    }

    private var apiErrorBody: Data {
        Data(#"{"data":{},"error":500,"message":"internal detail"}"#.utf8)
    }

    private func httpResponse(_ data: Data, status: Int = 200) -> (Data, URLResponse) {
        (
            data,
            HTTPURLResponse(url: panelURL, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }

    private var panelURL: URL {
        URL(string: "http://192.168.1.20:8081/")!
    }
}

private struct FixedPanelResolver: NSPanelAddressResolving {
    let addresses: [String]

    func resolveIPv4(host: String) async throws -> [String] {
        addresses
    }
}

private actor SequencePanelResolver: NSPanelAddressResolving {
    private var answers: [[String]]
    private var calls = 0

    init(_ answers: [[String]]) {
        self.answers = answers
    }

    func resolveIPv4(host: String) async throws -> [String] {
        calls += 1
        return answers.removeFirst()
    }

    func callCount() -> Int {
        calls
    }
}

private enum PanelLoadResult: @unchecked Sendable {
    case success((Data, URLResponse))
    case failure(Error)
}

private actor RecordingPanelLoader: NSPanelHTTPDataLoading {
    private let result: PanelLoadResult
    private var requests: [URLRequest] = []

    init(result: PanelLoadResult) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
