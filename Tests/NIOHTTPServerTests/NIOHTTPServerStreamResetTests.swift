//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOCore
import NIOEmbedded
import NIOHPACK
import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP2
import NIOSSL
import Testing

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServerStreamResetTests {
    /// Builds an `EmbeddedChannel` carrying the same `HTTP2FramePayloadToHTTPServerCodec`
    /// a real HTTP/2 stream channel has, so we can observe the raw `RST_STREAM` frame
    /// a reset produces.
    @available(anyAppleOS 26.0, *)
    private func makeHTTP2StreamChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.connect(to: try .init(ipAddress: "127.0.0.1", port: 0)).wait()
        try channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTPServerCodec())
        return channel
    }

    @Test("reset() reports the reset surface as unavailable on HTTP/1.1")
    @available(anyAppleOS 26.0, *)
    func testResetUnavailableOnHTTP1() async throws {
        let (writer, _) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let sender = NIOHTTPServer.ResponseSender(
            writer: writer,
            writerState: .init(),
            resetBacking: .http1_1
        )

        switch sender.reset() {
        case .unavailable:
            break
        case .http2:
            Issue.record("Expected .unavailable on HTTP/1.1, got .http2")
        }
    }

    @Test("Resetting the response sender before sending sends RST_STREAM with the chosen code")
    @available(anyAppleOS 26.0, *)
    func testResetSenderSendsRSTStream() async throws {
        let streamChannel = try self.makeHTTP2StreamChannel()
        let (writer, _) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let sender = NIOHTTPServer.ResponseSender(
            writer: writer,
            writerState: .init(),
            resetBacking: .http2(channel: streamChannel)
        )

        switch sender.reset() {
        case .http2(let h2):
            h2.reset(with: .connectError)
        case .unavailable:
            Issue.record("Expected .http2 reset surface, got .unavailable")
        }

        streamChannel.embeddedEventLoop.run()

        switch try streamChannel.readOutbound(as: HTTP2Frame.FramePayload.self) {
        case .rstStream(let code):
            #expect(code == .connectError)
        case let other:
            Issue.record("Expected an RST_STREAM frame, got \(String(describing: other))")
        }
    }

    @Test("Resetting the writer mid-response sends RST_STREAM with the chosen code")
    @available(anyAppleOS 26.0, *)
    func testResetWriterSendsRSTStream() async throws {
        let streamChannel = try self.makeHTTP2StreamChannel()
        let (writer, _) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let responseWriter = NIOHTTPServer.ResponseSender.Writer(
            writer: writer,
            writerState: .init(),
            resetBacking: .http2(channel: streamChannel)
        )

        switch responseWriter.reset() {
        case .http2(let h2):
            h2.reset(with: .internalError)
        case .unavailable:
            Issue.record("Expected .http2 reset surface, got .unavailable")
        }

        streamChannel.embeddedEventLoop.run()

        switch try streamChannel.readOutbound(as: HTTP2Frame.FramePayload.self) {
        case .rstStream(let code):
            #expect(code == .internalError)
        case let other:
            Issue.record("Expected an RST_STREAM frame, got \(String(describing: other))")
        }
    }

    @Test("End-to-end: an HTTP/2 handler that resets the stream sends RST_STREAM to the client")
    @available(anyAppleOS 26.0, *)
    func testEndToEndHTTP2ResetSendsRSTStream() async throws {
        let serverChain = try TestCA.makeSelfSignedChain()
        var clientTLSConfig = TLSConfiguration.makeClientConfiguration()
        clientTLSConfig.trustRoots = try .init(treatingNilAsSystemTrustRoots: [serverChain.ca])
        clientTLSConfig.certificateVerification = .noHostnameVerification
        clientTLSConfig.applicationProtocols = ["h2"]

        try await TestingChannelSecureUpgradeServer.serve(
            logger: Logger(label: "NIOHTTPServerStreamResetTests"),
            transportSecurity: .tls(
                credentials: .inMemory(
                    certificateChain: serverChain.chain,
                    privateKey: serverChain.privateKey
                )
            ),
            supportedHTTPVersions: [.http2(config: .defaults)],
            handler: HTTPServerClosureRequestHandler { request, reqContext, reqReader, resSender in
                // Establish the response (as a CONNECT tunnel would), then reset it.
                let writer = try await resSender.send(.init(status: .ok))
                switch writer.reset() {
                case .http2(let h2):
                    h2.reset(with: .connectError)
                case .unavailable:
                    Issue.record("Expected an HTTP/2 reset surface on an HTTP/2 connection.")
                }
            }
        ) { server in
            try await server.withConnectedClient(clientTLSConfig: clientTLSConfig) { negotiatedConnectionChannel in
                guard case .http2(let http2StreamManager) = negotiatedConnectionChannel else {
                    Issue.record("Failed to negotiate HTTP/2 despite the client requiring HTTP/2.")
                    return
                }

                let rawStream = try await http2StreamManager.openRawStream()
                try await rawStream.executeThenClose { inbound, outbound in
                    let requestHeaders: HPACKHeaders = [
                        ":method": "GET",
                        ":scheme": "https",
                        ":authority": "localhost",
                        ":path": "/",
                    ]
                    try await outbound.write(.headers(.init(headers: requestHeaders, endStream: true)))

                    var sawReset = false
                    for try await payload in inbound {
                        if case .rstStream(let code) = payload {
                            #expect(code == .connectError)
                            sawReset = true
                            break
                        }
                    }
                    #expect(sawReset, "Server never sent an RST_STREAM frame.")
                }
            }
        }
    }
}
