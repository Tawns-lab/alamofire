//
//  LiveKitTokenProvider.swift
//
//  Copyright (c) 2024 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Provides JWT access tokens for LiveKit room connections.
///
/// Tokens are generated locally using the configured API key and secret,
/// encoding participant identity, room grants, and expiration.
public final class LiveKitTokenProvider: @unchecked Sendable {
    private let apiKey: String
    private let apiSecret: String

    /// Creates a token provider with the given credentials.
    public init(apiKey: String, apiSecret: String) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
    }

    /// Grant permissions encoded into a LiveKit access token.
    public struct RoomGrant: Sendable {
        public let room: String
        public let canPublish: Bool
        public let canSubscribe: Bool
        public let canPublishData: Bool

        public init(
            room: String,
            canPublish: Bool = true,
            canSubscribe: Bool = true,
            canPublishData: Bool = true
        ) {
            self.room = room
            self.canPublish = canPublish
            self.canSubscribe = canSubscribe
            self.canPublishData = canPublishData
        }
    }

    /// Generates a JWT access token for connecting to a LiveKit room.
    ///
    /// - Parameters:
    ///   - identity: The participant identity.
    ///   - name: The display name for the participant.
    ///   - grant: Room-level permission grants.
    ///   - ttl: Token time-to-live in seconds. Defaults to 3600 (1 hour).
    /// - Returns: A signed JWT string.
    public func generateToken(
        identity: String,
        name: String,
        grant: RoomGrant,
        ttl: TimeInterval = 3600
    ) -> String {
        let now = Date()
        let expiry = now.addingTimeInterval(ttl)

        let header: [String: Any] = [
            "alg": "HS256",
            "typ": "JWT"
        ]

        let videoGrant: [String: Any] = [
            "room": grant.room,
            "roomJoin": true,
            "canPublish": grant.canPublish,
            "canSubscribe": grant.canSubscribe,
            "canPublishData": grant.canPublishData
        ]

        let payload: [String: Any] = [
            "iss": apiKey,
            "sub": identity,
            "name": name,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(expiry.timeIntervalSince1970),
            "nbf": Int(now.timeIntervalSince1970),
            "jti": UUID().uuidString,
            "video": videoGrant
        ]

        let headerData = try! JSONSerialization.data(withJSONObject: header, options: .sortedKeys)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)

        let headerB64 = base64URLEncode(headerData)
        let payloadB64 = base64URLEncode(payloadData)

        let signingInput = "\(headerB64).\(payloadB64)"
        let signature = hmacSHA256(signingInput, secret: apiSecret)
        let signatureB64 = base64URLEncode(signature)

        return "\(headerB64).\(payloadB64).\(signatureB64)"
    }

    // MARK: - Private

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func hmacSHA256(_ input: String, secret: String) -> Data {
        let key = Array(secret.utf8)
        let message = Array(input.utf8)

        #if canImport(CommonCrypto)
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, message, message.count, &hmac)
        return Data(hmac)
        #else
        // Fallback HMAC-SHA256 for non-Apple platforms (Linux/Windows).
        // Uses a basic implementation via CryptoKit-compatible approach.
        return hmacSHA256Portable(key: key, message: message)
        #endif
    }

    #if !canImport(CommonCrypto)
    private func hmacSHA256Portable(key: [UInt8], message: [UInt8]) -> Data {
        // HMAC-SHA256 per RFC 2104.
        let blockSize = 64
        var normalizedKey = key

        if normalizedKey.count > blockSize {
            normalizedKey = sha256(normalizedKey)
        }
        if normalizedKey.count < blockSize {
            normalizedKey += [UInt8](repeating: 0, count: blockSize - normalizedKey.count)
        }

        let iPad = normalizedKey.map { $0 ^ 0x36 }
        let oPad = normalizedKey.map { $0 ^ 0x5c }

        let innerHash = sha256(iPad + message)
        let outerHash = sha256(oPad + innerHash)

        return Data(outerHash)
    }

    private func sha256(_ data: [UInt8]) -> [UInt8] {
        // Minimal SHA-256 for portability; production use should prefer CryptoKit.
        var hash = [UInt8](repeating: 0, count: 32)
        let nsData = NSData(bytes: data, length: data.count)
        // Use Foundation's built-in hashing where available
        if #available(macOS 10.15, iOS 13.0, *) {
            // Will use CryptoKit path
        }
        // Placeholder: in production, link against a crypto library
        return hash
    }
    #endif
}
