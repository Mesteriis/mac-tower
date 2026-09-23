import Foundation
import MacTowerCore
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

public final class SensorHTTPServer: @unchecked Sendable {
    private let router: SensorHTTPRouter
    private let bindAddress: String
    private let port: Int
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(router: SensorHTTPRouter, bindAddress: String, port: Int) {
        self.router = router
        self.bindAddress = bindAddress
        self.port = port
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func start() throws {
        guard channel == nil else { return }
        let router = router
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(SensorHTTPHandler(router: router))
                }
            }
            .bind(host: bindAddress, port: port)
            .wait()
    }

    public func stop() throws {
        if let channel {
            try channel.close().wait()
            self.channel = nil
        }
        try group.syncShutdownGracefully()
    }

    deinit {
        try? stop()
    }
}

private final class SensorHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: SensorHTTPRouter

    init(router: SensorHTTPRouter) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(let head) = unwrapInboundIn(data) else { return }
        let request = SensorHTTPRequest(
            method: head.method.rawValue,
            path: head.uri,
            peerAddress: context.channel.remoteAddress?.ipAddress ?? ""
        )
        let contextBox = SendableContext(context)

        context.eventLoop.makeFutureWithTask {
            await self.router.handle(request)
        }.whenSuccess { response in
            let context = contextBox.value
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: response.contentType)
            headers.add(name: "Content-Length", value: "\(response.body.count)")
            headers.add(name: "Connection", value: "close")
            let status = HTTPResponseStatus(statusCode: response.status)
            context.write(
                self.wrapOutboundOut(
                    .head(.init(version: head.version, status: status, headers: headers))),
                promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                contextBox.value.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private struct SendableContext: @unchecked Sendable {
    let value: ChannelHandlerContext

    init(_ value: ChannelHandlerContext) {
        self.value = value
    }
}
