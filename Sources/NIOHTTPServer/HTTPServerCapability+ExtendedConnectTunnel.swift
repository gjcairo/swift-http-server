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

@available(anyAppleOS 26.0, *)
extension HTTPServerCapability {
    /// A response-sender capability: accept an incoming extended-CONNECT /
    /// Upgrade request and run an arbitrary ``ExtendedConnectProtocol`` over the
    /// resulting bidirectional stream (capsules, raw `CONNECT`, WebSocket, …).
    ///
    /// This is the generalised form of ``HTTPServerCapability/DatagramTunnelSending``:
    /// the protocol carried by the tunnel is a parameter — its message types, a
    /// stateful codec, and its handshake. The protocol fully owns its wire
    /// contract, so the accept call takes no per-request closures or tokens.
    public protocol ExtendedConnectTunnelSupport: HTTPResponseSender, ~Copyable, ~Escapable
    where Self.Writer: ~Copyable, Self.Writer: ~Escapable {
        /// The request body reader that is consumed and re-framed as the tunnel's
        /// inbound stream.
        associatedtype RequestReader: ~Copyable

        /// Accept `request` as a tunnel speaking `tunnelProtocol`.
        ///
        /// Runs `tunnelProtocol`'s ``ExtendedConnectProtocol/handshake(for:version:)``
        /// to validate the request (which throws to reject) and produce the accept
        /// response, sends it, and returns the tunnel. `tunnelProtocol` is the
        /// conformer's *type* — the protocol has only `static` requirements.
        ///
        /// Consumes both the response sender and the request `reader`: after a
        /// successful accept only the returned tunnel remains.
        consuming func acceptTunnel<TunnelProtocol: ExtendedConnectProtocol>(
            for request: HTTPRequest,
            reader: consuming sending RequestReader,
            using tunnelProtocol: TunnelProtocol.Type
        ) async throws -> NIOHTTPServer.ExtendedConnectTunnel<TunnelProtocol>
    }
}
