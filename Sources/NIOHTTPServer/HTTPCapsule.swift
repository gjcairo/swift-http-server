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

public import NIOCore

// NOTE: POC STUB.
//
// These types stand in for the real HTTP Capsule Protocol (RFC 9297)
// encoder/decoder that is being developed in a separate package. They do NOT
// implement any real framing — `encode` and `decode` are passthroughs whose
// only job is to let the datagram-tunnel API compile and round-trip a payload
// end to end. Replace with the real `HTTPCapsuleEncoder` / `HTTPCapsuleDecoder`
// (with their varint Type/Length framing) once that package lands.

/// A single HTTP Capsule (RFC 9297): a variable-length `Type` followed by a
/// length-prefixed value.
@available(anyAppleOS 26.0, *)
public struct HTTPCapsule: Sendable {
    /// The capsule type. `0x00` is the `DATAGRAM` capsule.
    public var type: UInt64

    /// The capsule value. For a `DATAGRAM` capsule this is the HTTP Datagram
    /// payload (in the general case prefixed by a context ID; ignored in the POC).
    public var payload: ByteBuffer

    public init(type: UInt64, payload: ByteBuffer) {
        self.type = type
        self.payload = payload
    }

    /// The `DATAGRAM` capsule type (RFC 9297 §3.5).
    public static let datagramType: UInt64 = 0x00
}

/// Serialises ``HTTPCapsule`` values to their on-the-wire byte representation.
@available(anyAppleOS 26.0, *)
public enum HTTPCapsuleEncoder {
    /// Encode a capsule to bytes.
    ///
    /// POC STUB: emits the payload verbatim, with no Type/Length framing.
    public static func encode(_ capsule: HTTPCapsule) -> ByteBuffer {
        capsule.payload
    }
}

/// Parses ``HTTPCapsule`` values out of a byte stream.
@available(anyAppleOS 26.0, *)
public enum HTTPCapsuleDecoder {
    /// Decode the next capsule from `buffer`, consuming the bytes it reads.
    /// Returns `nil` when there aren't enough bytes for a complete capsule yet.
    ///
    /// POC STUB: treats every non-empty buffer as one `DATAGRAM` capsule and
    /// drains it completely.
    public static func decode(_ buffer: inout ByteBuffer) -> HTTPCapsule? {
        guard buffer.readableBytes > 0 else { return nil }
        let payload = buffer.readSlice(length: buffer.readableBytes) ?? ByteBuffer()
        return HTTPCapsule(type: HTTPCapsule.datagramType, payload: payload)
    }
}
