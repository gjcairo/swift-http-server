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

public import HTTPAPIs

/// Errors thrown when accepting or using an HTTP Datagram tunnel.
@available(anyAppleOS 26.0, *)
public enum DatagramTunnelError: Error, Sendable {
    /// The request does not establish a datagram tunnel on the negotiated
    /// transport (e.g. it isn't an extended `CONNECT` on HTTP/2, or lacks the
    /// `Upgrade` token on HTTP/1.1).
    case notADatagramRequest

    /// The connection did not negotiate the capability required to carry
    /// datagrams (e.g. HTTP/2 extended `CONNECT` was not enabled).
    case notNegotiated
}

@available(anyAppleOS 26.0, *)
extension HTTPServerCapability {
    /// A response-sender capability: accept an incoming `CONNECT` / `Upgrade`
    /// request and turn the request stream into a bidirectional HTTP Datagram
    /// tunnel carried by the Capsule Protocol (RFC 9297).
    ///
    /// This is the response-sender analogue of the request-context capabilities
    /// (``HTTPServerCapability/ConnectionInfo`` et al.): a handler generic over a
    /// server whose ``HTTPResponseSender`` conforms to this capability can accept
    /// datagram tunnels without depending on a concrete server type:
    ///
    /// ```swift
    /// where Handler.ResponseSender: HTTPServerCapability.DatagramTunnelSending
    /// ```
    ///
    /// Whether a *particular* stream can actually carry datagrams is a runtime
    /// property of the negotiated connection, so ``acceptDatagramTunnel(for:reader:headerFields:)``
    /// throws (see ``DatagramTunnelError``) rather than being statically
    /// guaranteed.
    public protocol DatagramTunnelSending: HTTPResponseSender, ~Copyable, ~Escapable
    where Self.Writer: ~Copyable, Self.Writer: ~Escapable {
        /// The bidirectional tunnel handle returned on a successful accept,
        /// bundling the inbound datagram reader and the outbound datagram writer.
        ///
        /// It is a single `~Copyable` value rather than a `(reader, writer)`
        /// tuple because Swift tuples cannot yet hold a noncopyable element (the
        /// reader is `~Copyable`). Bundling into one handle is also what lets a
        /// future HTTP/3 build add a native QUIC-datagram surface additively,
        /// without changing this signature.
        associatedtype Tunnel: ~Copyable

        /// The request body reader that is consumed and re-framed as the tunnel's
        /// inbound capsule stream.
        associatedtype RequestReader: ~Copyable

        /// Accept `request` as a datagram tunnel, sending the transport-appropriate
        /// success response (`101` on HTTP/1.1, `2xx` on HTTP/2/HTTP/3) and
        /// returning the tunnel handle.
        ///
        /// Consumes both the response sender and the request `reader`: after a
        /// successful accept the ordinary body reader and response writer are gone
        /// and only the returned tunnel remains.
        ///
        /// - Throws: ``DatagramTunnelError`` if the request/connection can't carry
        ///   datagrams.
        consuming func acceptDatagramTunnel(
            for request: HTTPRequest,
            reader: consuming sending RequestReader,
            headerFields: HTTPFields
        ) async throws -> Tunnel
    }
}
