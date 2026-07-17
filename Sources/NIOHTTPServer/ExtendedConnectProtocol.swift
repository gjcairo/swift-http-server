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
public import NIOCore

// POC (alternative, generalised API): model *any* protocol that runs over an
// upgraded / extended-CONNECT stream as an `ExtendedConnectProtocol`. A CONNECT
// tunnel is a raw byte stream in both directions, so the only thing a protocol
// varies is its domain message (the decoded element) and how it frames that
// element to/from bytes — plus its handshake. The server hosts those transforms
// on generic tunnel reader/writer that mirror the underlying `NIOHTTPServer.Reader`
// / `ResponseSender.Writer`, just with `Message` as the element instead of bytes.

/// Errors an ``ExtendedConnectProtocol`` handshake can throw to reject a request.
@available(anyAppleOS 26.0, *)
public enum ExtendedConnectTunnelError: Error, Sendable {
    /// The request cannot establish this protocol's tunnel on the negotiated
    /// transport.
    case notAcceptable
}

/// Describes a protocol carried over an accepted extended-CONNECT / Upgrade
/// tunnel: its domain message, how that message frames to/from the raw byte
/// stream, and its handshake.
///
/// There is a single ``Message`` associated type — the decoded domain element
/// (e.g. an ``HTTPCapsule``) that the tunnel reader yields and the tunnel writer
/// accepts. The wire form is always bytes, so there is no separate inbound /
/// outbound byte type. All requirements are `static`, so a conformer is a pure
/// type-level namespace: no instance is ever created, and ``acceptTunnel(for:reader:using:)``
/// takes the conformer's type rather than a value.
@available(anyAppleOS 26.0, *)
public protocol ExtendedConnectProtocol: Sendable {
    /// The decoded domain element read from and written to the tunnel.
    associatedtype Message

    /// Validate `request` and produce the response that accepts the tunnel.
    ///
    /// Inspects the request (throwing — e.g. ``ExtendedConnectTunnelError`` — to
    /// reject it) and returns the response to send. It receives the negotiated
    /// ``NIOHTTPServer/HTTPVersion`` so it can choose the transport-appropriate
    /// status (`101` on HTTP/1.1 vs `2xx` on HTTP/2/HTTP/3) alongside any
    /// protocol-specific headers (e.g. `Sec-WebSocket-Accept`, `Capsule-Protocol: ?1`).
    static func handshake(
        for request: HTTPRequest,
        version: NIOHTTPServer.HTTPVersion
    ) async throws -> HTTPResponse

    /// Encode one message to its wire bytes.
    static func encode(_ message: Message) -> ByteBuffer

    /// Decode the next message from `buffer`, consuming the bytes it reads.
    /// Returns `nil` when the buffer doesn't yet hold a complete message.
    static func decode(_ buffer: inout ByteBuffer) -> Message?
}

// MARK: - Concrete protocols (POC)

/// Carries HTTP Datagrams as Capsule-Protocol (RFC 9297) capsules. Its message
/// is the domain ``HTTPCapsule``, framed with the (stubbed) ``HTTPCapsuleEncoder``
/// / ``HTTPCapsuleDecoder``.
@available(anyAppleOS 26.0, *)
public enum CapsuleProtocol: ExtendedConnectProtocol {
    public typealias Message = HTTPCapsule

    /// Accept as extended CONNECT (HTTP/2/HTTP/3) or Upgrade (HTTP/1.1).
    public static func handshake(
        for request: HTTPRequest,
        version: NIOHTTPServer.HTTPVersion
    ) async throws -> HTTPResponse {
        switch version {
        case .http2:
            guard request.method == .connect, request.extendedConnectProtocol != nil else {
                throw ExtendedConnectTunnelError.notAcceptable
            }
            return HTTPResponse(status: .ok)  // + Capsule-Protocol: ?1 in a real impl
        case .http1_1:
            let hasUpgrade = HTTPField.Name("Upgrade").map { request.headerFields[$0] != nil } ?? false
            guard hasUpgrade else { throw ExtendedConnectTunnelError.notAcceptable }
            return HTTPResponse(status: .switchingProtocols)
        }
    }

    public static func encode(_ message: HTTPCapsule) -> ByteBuffer {
        HTTPCapsuleEncoder.encode(message)
    }

    public static func decode(_ buffer: inout ByteBuffer) -> HTTPCapsule? {
        HTTPCapsuleDecoder.decode(&buffer)
    }
}

/// A raw byte tunnel (classic `CONNECT`): the stream is passed through with no
/// framing. Demonstrates that the mechanism isn't datagram-specific.
@available(anyAppleOS 26.0, *)
public enum RawTunnelProtocol: ExtendedConnectProtocol {
    public typealias Message = ByteBuffer

    /// Accept any `CONNECT` request with a `2xx` (or `101` on HTTP/1.1).
    public static func handshake(
        for request: HTTPRequest,
        version: NIOHTTPServer.HTTPVersion
    ) async throws -> HTTPResponse {
        guard request.method == .connect else { throw ExtendedConnectTunnelError.notAcceptable }
        return HTTPResponse(status: version == .http1_1 ? .switchingProtocols : .ok)
    }

    public static func encode(_ message: ByteBuffer) -> ByteBuffer { message }

    public static func decode(_ buffer: inout ByteBuffer) -> ByteBuffer? {
        buffer.readableBytes > 0 ? buffer.readSlice(length: buffer.readableBytes) : nil
    }
}
