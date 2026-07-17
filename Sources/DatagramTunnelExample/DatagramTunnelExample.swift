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
import NIOHTTPServer

//@main
//@available(anyAppleOS 26.0, *)
//struct DatagramTunnelExample {
//    static func main() async throws {
//        var mutableLogger = Logger(label: "DatagramTunnelExample")
//        mutableLogger.logLevel = .debug
//        let logger = mutableLogger
//
//        let server = NIOHTTPServer(
//            logger: logger,
//            configuration: try .init(
//                bindTarget: .hostAndPort(host: "127.0.0.1", port: 12346),
//                supportedHTTPVersions: [.http1_1],
//                transportSecurity: .plaintext
//            )
//        )
//
//        try await server.serve { request, _, reader, responseSender in
//            var tunnel = try await responseSender.acceptDatagramTunnel(
//                for: request,
//                reader: reader
//            )
//
//            let datagram = try await tunnel.reader.receiveDatagram()
//            logger.debug("received datagram of \(datagram!.readableBytes) bytes")
//
//            var payload = ByteBuffer()
//            payload.writeString("server datagram")
//            try await tunnel.writer.sendDatagram(payload)
//            try await tunnel.writer.finish()
//        }
//    }
//}


@main
@available(anyAppleOS 26.0, *)
struct ExtendedConnectExample {
    static func main() async throws {
        var mutableLogger = Logger(label: "ExtendedConnectExample")
        mutableLogger.logLevel = .debug
        let logger = mutableLogger

        let server = NIOHTTPServer(
            logger: logger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 12346),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        try await server.serve { request, _, reader, responseSender in
            var tunnel = try await responseSender.acceptTunnel(
                for: request,
                reader: reader,
                using: CapsuleProtocol.self
            )

            let message = try await tunnel.reader.receive()
            logger.debug("received capsule (type \(message!.type)) of \(message!.payload.readableBytes) bytes")

            var payload = ByteBuffer()
            payload.writeString("server datagram")
            try await tunnel.writer.send(HTTPCapsule(type: HTTPCapsule.datagramType, payload: payload))
            try await tunnel.writer.finish()
        }
    }
}
