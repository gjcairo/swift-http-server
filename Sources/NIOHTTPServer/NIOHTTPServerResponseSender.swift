//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTPTypes
import Synchronization

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    public struct ResponseSender: HTTPResponseSender, ~Copyable {
        let writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>
        let writerState: WriterState
        let resetBacking: NIOHTTPServer.ResetBacking

        public mutating func sendInformational(_ response: HTTPResponse) async throws {
            precondition(response.status.kind == .informational)
            try await self.writer.write(.head(response))
        }

        public consuming func send(_ response: HTTPResponse) async throws -> Writer {
            precondition(response.status.kind != .informational)
            try await self.writer.write(.head(response))
            return Writer(writer: self.writer, writerState: self.writerState, resetBacking: self.resetBacking)
        }

        /// Abandons the response and resets the stream carrying this request.
        ///
        /// Call this instead of ``send(_:)`` when the request should be aborted
        /// before any response head is sent. This consumes the sender, so no
        /// response can be sent afterwards.
        ///
        /// The returned ``NIOHTTPServer/StreamReset`` exposes the coded-reset API
        /// only on transports that support it; see ``NIOHTTPServer/StreamReset``.
        public consuming func reset() -> NIOHTTPServer.StreamReset {
            self.writerState.markReset(self.resetBacking)
            return self.resetBacking.makeStreamReset()
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer.ResponseSender {
    final class WriterState: Sendable {
        struct Wrapped: ~Copyable {
            var finishedWriting: Bool = false
        }

        let wrapped: Mutex<Wrapped> = .init(.init())

        /// Records that the handler chose to reset the stream instead of
        /// concluding the response normally.
        ///
        /// On HTTP/2 the stream is reset with an explicit `RST_STREAM`, which is
        /// itself a clean conclusion of the exchange, so the response is marked
        /// as concluded to avoid an erroneous "did not conclude the response"
        /// teardown. On HTTP/1.1 there is no stream-level reset: leaving the
        /// response unconcluded is deliberate, so the connection is torn down.
        func markReset(_ backing: NIOHTTPServer.ResetBacking) {
            switch backing {
            case .http2:
                self.wrapped.withLock { $0.finishedWriting = true }
            case .http1_1:
                ()
            }
        }
    }

    public struct Writer: CallerAsyncWriter, ~Copyable {
        public typealias WriteElement = UInt8

        public typealias WriteFailure = any Error

        public typealias FinalElement = HTTPFields?

        /// The underlying NIO writer for HTTP response parts.
        let writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>

        let writerState: WriterState

        let resetBacking: NIOHTTPServer.ResetBacking

        public mutating func write(
            buffer: inout some RangeReplaceableContainer<UInt8> & ~Copyable
        ) async throws(WriteFailure) {
            var byteBuffer = ByteBuffer()
            byteBuffer.reserveCapacity(buffer.count)

            var consumer = buffer.consumeAll()
            // `while !done { ... }` instead of `while true { ... break }` to
            // dodge a SIL ownership-verifier crash on the nightly main
            // toolchain (https://github.com/swiftlang/swift/issues/89639).
            var done = false
            while !done {
                let span = consumer.drainNext()
                if span.isEmpty {
                    done = true
                } else {
                    unsafe byteBuffer.writeBytes(span.span.bytes)
                }
            }

            try await self.writer.write(.body(byteBuffer))
        }

        public consuming func finish(
            buffer: inout some RangeReplaceableContainer<UInt8> & ~Copyable,
            finalElement: consuming HTTPFields?
        ) async throws(WriteFailure) {
            if !buffer.isEmpty {
                var byteBuffer = ByteBuffer()
                byteBuffer.reserveCapacity(buffer.count)

                var consumer = buffer.consumeAll()
                // `while !done { ... }` instead of `while true { ... break }` to
                // dodge a SIL ownership-verifier crash on the nightly main
                // toolchain (https://github.com/swiftlang/swift/issues/89639).
                var done = false
                while !done {
                    let span = consumer.drainNext()
                    if span.isEmpty {
                        done = true
                    } else {
                        unsafe byteBuffer.writeBytes(span.span.bytes)
                    }
                }

                try await self.writer.write(.body(byteBuffer))
            }
            try await self.writer.write(.end(finalElement))
            self.writerState.wrapped.withLock { $0.finishedWriting = true }
        }

        /// Abandons the in-flight response and resets the stream carrying this
        /// request.
        ///
        /// Call this instead of ``finish(buffer:finalElement:)`` when a response
        /// that has already started (its head is sent) must be aborted — for
        /// example when a `CONNECT` tunnel's upstream connection fails. This
        /// consumes the writer, so no further body or trailers can be written.
        ///
        /// The returned ``NIOHTTPServer/StreamReset`` exposes the coded-reset API
        /// only on transports that support it; see ``NIOHTTPServer/StreamReset``.
        public consuming func reset() -> NIOHTTPServer.StreamReset {
            self.writerState.markReset(self.resetBacking)
            return self.resetBacking.makeStreamReset()
        }
    }
}

@available(*, unavailable)
extension NIOHTTPServer.ResponseSender: Sendable {}

@available(*, unavailable)
extension NIOHTTPServer.ResponseSender.Writer: Sendable {}
