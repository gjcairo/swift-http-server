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

public import NIOHTTP2
import NIOCore
import NIOHTTPTypes
import NIOHTTPTypesHTTP2

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// The transport-specific surface for resetting the stream carrying a request.
    ///
    /// A *coded* stream reset only exists on transports that have per-request
    /// streams. Aborting a request with a specific error code is an HTTP/2 (and,
    /// in future, HTTP/3) concept: HTTP/1.1 has no stream to reset — the only
    /// abrupt teardown available there is closing the connection.
    ///
    /// Rather than offer a `reset(with:)` that silently does the wrong thing on
    /// HTTP/1.1, ``NIOHTTPServer/ResponseSender/reset()`` and
    /// ``NIOHTTPServer/ResponseSender/Writer/reset()`` return this enum. Switch
    /// over it to reach the coded-reset API only where it is meaningful:
    ///
    /// ```swift
    /// switch writer.reset() {
    /// case .http2(let h2):
    ///     h2.reset(with: .connectError)   // e.g. upstream TCP failed on a CONNECT tunnel
    /// case .unavailable:
    ///     break                           // HTTP/1.1: nothing to reset; the exchange aborts on return
    /// }
    /// ```
    ///
    /// - Note: Obtaining a ``StreamReset`` consumes the response sender / writer
    ///   it came from, so the response can no longer be written once you have
    ///   decided to reset the stream.
    public enum StreamReset: ~Copyable {
        /// The connection is HTTP/2; ``HTTP2StreamReset`` sends an `RST_STREAM`.
        case http2(HTTP2StreamReset)

        /// The transport has no per-stream coded reset (for example HTTP/1.1).
        ///
        /// There is nothing to reset with a code here. Returning from the
        /// handler without concluding the response aborts the exchange and the
        /// connection is closed.
        case unavailable
    }

    /// Resets an HTTP/2 stream by sending an `RST_STREAM` frame with a chosen
    /// error code.
    ///
    /// Obtained from ``NIOHTTPServer/StreamReset`` after consuming a response
    /// sender or writer. Sending the reset is non-blocking and idempotent:
    /// repeated calls, or a reset after the stream has otherwise closed, are
    /// safe no-ops.
    public struct HTTP2StreamReset: ~Copyable {
        private let channel: any Channel

        init(channel: any Channel) {
            self.channel = channel
        }

        /// Sends an `RST_STREAM` for this stream with the given error code.
        ///
        /// For a proxy handling `CONNECT` / `CONNECT-UDP`, use ``NIOHTTP2/HTTP2ErrorCode/connectError``
        /// to signal a failure of the tunnelled connection (RFC 7540 § 8.3).
        ///
        /// - Parameter code: The `RST_STREAM` error code to send.
        public consuming func reset(with code: HTTP2ErrorCode) {
            // The `HTTP2FramePayloadToHTTPServerCodec` on the stream channel
            // translates this event into an `RST_STREAM` frame carrying `code`.
            self.channel.triggerUserOutboundEvent(
                NIOHTTP2FramePayloadToHTTPEvent.reset(code: code),
                promise: nil
            )
        }
    }

    /// How a request's stream can be reset, captured per connection.
    ///
    /// Stored on the ``ResponseSender`` / ``Writer`` so a handler can reset the
    /// stream regardless of whether it has started sending a response.
    enum ResetBacking: Sendable {
        /// HTTP/2: reset by writing an `RST_STREAM` on the given stream channel.
        case http2(channel: any Channel)

        /// HTTP/1.1: no per-stream coded reset.
        case http1_1

        /// Resolves this backing into the public, transport-specific reset surface.
        func makeStreamReset() -> NIOHTTPServer.StreamReset {
            switch self {
            case .http2(let channel):
                return .http2(NIOHTTPServer.HTTP2StreamReset(channel: channel))
            case .http1_1:
                return .unavailable
            }
        }
    }
}

@available(*, unavailable)
extension NIOHTTPServer.StreamReset: Sendable {}

@available(*, unavailable)
extension NIOHTTPServer.HTTP2StreamReset: Sendable {}
