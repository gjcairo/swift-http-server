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

public import BasicContainers
public import HTTPAPIs
import NIOCore
import NIOHTTPTypes

// MARK: - Tunnel writer (outbound messages)

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// A ``CallerAsyncWriter`` whose element is `TunnelProtocol.Message`: it wraps
    /// the response body ``ResponseSender/Writer``, encoding each message to bytes
    /// with `TunnelProtocol.encode` before writing. Same interface as the
    /// underlying writer, one transform higher.
    ///
    /// Not `Sendable`: it holds the single-use, non-`Sendable`
    /// ``ResponseSender/Writer``, so send and receive share one task.
    public struct ExtendedConnectTunnelWriter<TunnelProtocol: ExtendedConnectProtocol>: ~Copyable, CallerAsyncWriter {
        public typealias WriteElement = TunnelProtocol.Message
        public typealias WriteFailure = any Error
        public typealias FinalElement = HTTPFields?

        var bodyWriter: NIOHTTPServer.ResponseSender.Writer

        init(bodyWriter: consuming NIOHTTPServer.ResponseSender.Writer) {
            self.bodyWriter = bodyWriter
        }

        public mutating func write(
            buffer: inout some RangeReplaceableContainer<WriteElement> & ~Copyable
        ) async throws {
            var encoded = Self.encode(&buffer)
            try await self.bodyWriter.write(buffer: &encoded)
        }

        public consuming func finish(
            buffer: inout some RangeReplaceableContainer<WriteElement> & ~Copyable,
            finalElement: consuming HTTPFields?
        ) async throws {
            var encoded = Self.encode(&buffer)
            try await self.bodyWriter.finish(buffer: &encoded, finalElement: finalElement)
        }

        /// Encode every message in `buffer` into a single byte buffer.
        private static func encode(
            _ buffer: inout some RangeReplaceableContainer<WriteElement> & ~Copyable
        ) -> UniqueArray<UInt8> {
            var bytes = UniqueArray<UInt8>()
            var consumer = buffer.consumeAll()
            while let message = consumer.next() {
                let encoded = TunnelProtocol.encode(message)
                bytes.append(copying: encoded.readableBytesUInt8Span)
            }
            return bytes
        }

        // Convenience single-message API on top of the `CallerAsyncWriter` requirements.

        /// Send one message.
        public mutating func send(_ message: WriteElement) async throws {
            var buffer = UniqueArray<WriteElement>()
            buffer.append(message)
            try await self.write(buffer: &buffer)
        }

        /// Close the tunnel's outbound half with no trailing fields.
        public consuming func finish() async throws {
            var empty = UniqueArray<WriteElement>()
            try await self.finish(buffer: &empty, finalElement: nil)
        }
    }
}

// MARK: - Tunnel reader (inbound messages)

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// An ``AsyncReader`` whose element is `TunnelProtocol.Message`: it wraps the
    /// request body ``Reader``, decoding messages off the byte stream with
    /// `TunnelProtocol.decode`. Same interface as the underlying reader, one
    /// transform higher.
    ///
    /// `~Copyable` and not `Sendable`: move it into a single read loop.
    public struct ExtendedConnectTunnelReader<TunnelProtocol: ExtendedConnectProtocol>: ~Copyable, AsyncReader {
        public typealias ReadElement = TunnelProtocol.Message
        public typealias Buffer = UniqueArray<TunnelProtocol.Message>
        public typealias ReadFailure = any Error
        public typealias FinalElement = HTTPFields?

        var reader: NIOHTTPServer.Reader

        init(reader: consuming NIOHTTPServer.Reader) {
            self.reader = reader
        }

        public mutating func read<Return: ~Copyable, Failure: Error>(
            body: (inout Buffer, consuming HTTPFields??) async throws(Failure) -> Return
        ) async throws(EitherError<ReadFailure, Failure>) -> Return {
            // Phase 1: pull one chunk of bytes + trailers out of the underlying
            // byte reader. Wrap its failures as `.first`, matching `Reader.read`.
            var wire = ByteBuffer()
            var trailers: HTTPFields?? = nil
            do {
                try await self.reader.read { byteBuffer, finalElement in
                    wire.reserveCapacity(byteBuffer.count)
                    var consumer = byteBuffer.consumeAll()
                    var done = false
                    while !done {
                        let span = consumer.drainNext()
                        if span.isEmpty {
                            done = true
                        } else {
                            unsafe wire.writeBytes(span.span.bytes)
                        }
                    }
                    trailers = finalElement
                }
            } catch {
                throw .first(error)
            }

            // Phase 2: decode all complete messages out of the chunk and hand
            // them to the caller's body. Wrap its failures as `.second`.
            // (POC: no cross-chunk buffering of partial frames.)
            var messages = Buffer()
            while let message = TunnelProtocol.decode(&wire) {
                messages.append(message)
            }
            do {
                return try await body(&messages, trailers)
            } catch {
                throw .second(error)
            }
        }

        /// Convenience: receive the next message, or `nil` at end of stream.
        public mutating func receive() async throws -> ReadElement? {
            try await self.read { messages, _ in
                var consumer = messages.consumeAll()
                return consumer.next()
            }
        }
    }
}

@available(*, unavailable)
extension NIOHTTPServer.ExtendedConnectTunnelReader: Sendable {}

// MARK: - Tunnel handle

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// A bidirectional tunnel returned by
    /// ``ResponseSender/acceptTunnel(for:reader:using:)``, speaking
    /// `TunnelProtocol`.
    ///
    /// `@frozen` so consumers in other modules can partially consume it — e.g.
    /// `tunnel.writer.finish()` moves out just the writer while the reader loop
    /// continues.
    @frozen
    public struct ExtendedConnectTunnel<TunnelProtocol: ExtendedConnectProtocol>: ~Copyable {
        /// Inbound messages (client -> server).
        public var reader: ExtendedConnectTunnelReader<TunnelProtocol>

        /// Outbound messages (server -> client).
        public var writer: ExtendedConnectTunnelWriter<TunnelProtocol>

        init(
            reader: consuming ExtendedConnectTunnelReader<TunnelProtocol>,
            writer: consuming ExtendedConnectTunnelWriter<TunnelProtocol>
        ) {
            self.reader = reader
            self.writer = writer
        }
    }
}

// MARK: - Accepting a tunnel (the response-sender capability)

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer.ResponseSender: HTTPServerCapability.ExtendedConnectTunnelSupport {
    public consuming func acceptTunnel<TunnelProtocol: ExtendedConnectProtocol>(
        for request: HTTPRequest,
        reader: consuming sending NIOHTTPServer.Reader,
        using tunnelProtocol: TunnelProtocol.Type
    ) async throws -> NIOHTTPServer.ExtendedConnectTunnel<TunnelProtocol> {
        // The protocol's handshake owns validation + the accept response; it
        // receives the negotiated version so it can pick 101 vs 2xx and add any
        // protocol-specific headers. It throws to reject the request.
        let response = try await tunnelProtocol.handshake(for: request, version: self.context.httpVersion)
        try await self.writer.write(.head(response))
        let bodyWriter = NIOHTTPServer.ResponseSender.Writer(writer: self.writer, writerState: self.writerState)

        return NIOHTTPServer.ExtendedConnectTunnel(
            reader: NIOHTTPServer.ExtendedConnectTunnelReader<TunnelProtocol>(reader: reader),
            writer: NIOHTTPServer.ExtendedConnectTunnelWriter<TunnelProtocol>(bodyWriter: bodyWriter)
        )
    }
}
