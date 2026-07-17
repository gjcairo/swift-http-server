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

import BasicContainers
public import HTTPAPIs
public import NIOCore
public import NIOHTTPTypes
import Synchronization

// POC: server -> client HTTP Datagrams carried as Capsule-Protocol (RFC 9297)
// capsules over the request stream. This is the capsule-only path, which is
// identical on HTTP/1.1, HTTP/2 and HTTP/3; the only per-version difference is
// the accept response (101 vs 2xx), handled inside `acceptDatagramTunnel`.
// (Native HTTP/3 QUIC-datagram delivery is a separate, later surface.)

// MARK: - Tunnel writer (outbound datagrams)

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// Sends server -> client HTTP Datagrams on an accepted tunnel.
    ///
    /// Each ``sendDatagram(_:)`` encodes the payload as a `DATAGRAM` capsule and
    /// writes it to the tunnel's data stream. `Sendable`, so it can drive a send
    /// loop on a task separate from the ``DatagramReader`` read loop — unlike the
    /// ordinary response ``ResponseSender/Writer``, which is single-use and
    /// non-`Sendable`.
    public struct DatagramWriter: ~Copyable, Sendable {
        let writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>
        let writerState: ResponseSender.WriterState

        /// Send one HTTP Datagram.
        public func sendDatagram(_ payload: ByteBuffer) async throws {
            let capsule = HTTPCapsule(type: HTTPCapsule.datagramType, payload: payload)
            let bytes = HTTPCapsuleEncoder.encode(capsule)
            try await self.writer.write(.body(bytes))
        }

        /// Close the tunnel's outbound half, terminating the response stream.
        public consuming func finish() async throws {
            try await self.writer.write(.end(nil))
            self.writerState.wrapped.withLock { $0.finishedWriting = true }
        }
    }
}

// MARK: - Tunnel reader (inbound datagrams)

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// Yields client -> server HTTP Datagrams on an accepted tunnel.
    ///
    /// `~Copyable` and not `Sendable`: move it into a single read loop. It wraps
    /// the consumed request-body ``Reader`` and decodes capsules off the data
    /// stream.
    public struct DatagramReader: ~Copyable {
        var reader: NIOHTTPServer.Reader

        init(reader: consuming NIOHTTPServer.Reader) {
            self.reader = reader
        }

        /// Receive the next HTTP Datagram, or `nil` when the tunnel's inbound
        /// stream ends.
        public mutating func receiveDatagram() async throws -> ByteBuffer? {
            // POC: pull the next chunk of stream bytes and decode a capsule from
            // it (one chunk == one datagram here).
            let chunk: ByteBuffer? = try await self.reader.read { buffer, _ -> ByteBuffer? in
                guard !buffer.isEmpty else { return nil }
                var byteBuffer = ByteBuffer()
                byteBuffer.reserveCapacity(buffer.count)
                var consumer = buffer.consumeAll()
                var done = false
                while !done {
                    let span = consumer.drainNext()
                    if span.isEmpty {
                        done = true
                    } else {
                        unsafe byteBuffer.writeBytes(span.span.bytes)
                    }
                }
                return byteBuffer
            }
            guard var chunk, chunk.readableBytes > 0 else { return nil }
            return HTTPCapsuleDecoder.decode(&chunk)?.payload
        }
    }
}

@available(*, unavailable)
extension NIOHTTPServer.DatagramReader: Sendable {}

// MARK: - Tunnel handle

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// A bidirectional HTTP Datagram tunnel returned by
    /// ``ResponseSender/acceptDatagramTunnel(for:reader:headerFields:)``.
    ///
    /// Bundles the inbound ``DatagramReader`` and outbound ``DatagramWriter`` into
    /// one `~Copyable` handle. The ``writer`` is `Sendable` and `Copyable`, so it
    /// can be copied out and moved to a separate send task while the reader stays
    /// in this handle's read loop:
    ///
    /// ```swift
    /// var tunnel = try await responseSender.acceptDatagramTunnel(for: request, reader: reader)
    /// let writer = tunnel.writer            // Sendable copy for another task
    /// while let payload = try await tunnel.reader.receiveDatagram() { ... }
    /// ```
    @frozen
    public struct DatagramTunnel: ~Copyable {
        /// Inbound datagrams (client -> server).
        public var reader: DatagramReader

        /// Outbound datagrams (server -> client).
        public let writer: DatagramWriter

        init(reader: consuming DatagramReader, writer: consuming DatagramWriter) {
            self.reader = reader
            self.writer = writer
        }
    }
}

// MARK: - Accepting a tunnel (the response-sender capability)

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer.ResponseSender: HTTPServerCapability.DatagramTunnelSending {
    public consuming func acceptDatagramTunnel(
        for request: HTTPRequest,
        reader: consuming sending NIOHTTPServer.Reader,
        headerFields: HTTPFields = [:]
    ) async throws -> NIOHTTPServer.DatagramTunnel {
        // Validate that this request establishes a datagram tunnel on the
        // negotiated transport, and pick the transport-appropriate success
        // status. The per-version detail is hidden from the handler here.
        let status: HTTPResponse.Status
        switch self.context.httpVersion {
        case .http2:
            // HTTP/2: extended CONNECT (RFC 8441) — :method = CONNECT + :protocol.
            guard request.method == .connect, request.extendedConnectProtocol != nil else {
                throw DatagramTunnelError.notADatagramRequest
            }
            status = .ok
        case .http1_1:
            // HTTP/1.1: the Upgrade mechanism — no :protocol pseudo-header exists.
            let hasUpgrade = HTTPField.Name("Upgrade").map { request.headerFields[$0] != nil } ?? false
            guard hasUpgrade else {
                throw DatagramTunnelError.notADatagramRequest
            }
            status = .switchingProtocols
        }

        try await self.writer.write(.head(HTTPResponse(status: status, headerFields: headerFields)))

        return NIOHTTPServer.DatagramTunnel(
            reader: NIOHTTPServer.DatagramReader(reader: reader),
            writer: NIOHTTPServer.DatagramWriter(writer: self.writer, writerState: self.writerState)
        )
    }
}
