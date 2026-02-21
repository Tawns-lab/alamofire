//
//  ChatMessage.swift
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

/// Represents a message exchanged within a LiveKit chat session.
public struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
    /// Unique identifier for the message.
    public let id: String

    /// Identity of the participant who sent the message.
    public let senderIdentity: String

    /// Display name of the sender, if available.
    public let senderName: String?

    /// The content of the message.
    public let content: String

    /// The type of message content.
    public let kind: Kind

    /// Timestamp when the message was created (Unix epoch seconds).
    public let timestamp: TimeInterval

    /// Optional metadata attached to the message.
    public let metadata: [String: String]?

    /// The topic/channel this message was sent on, if any.
    public let topic: String?

    /// Creates a new chat message.
    public init(
        id: String = UUID().uuidString,
        senderIdentity: String,
        senderName: String? = nil,
        content: String,
        kind: Kind = .text,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        metadata: [String: String]? = nil,
        topic: String? = nil
    ) {
        self.id = id
        self.senderIdentity = senderIdentity
        self.senderName = senderName
        self.content = content
        self.kind = kind
        self.timestamp = timestamp
        self.metadata = metadata
        self.topic = topic
    }
}

// MARK: - Kind

extension ChatMessage {
    /// Describes the type of message content.
    public enum Kind: String, Codable, Sendable {
        /// Plain text message.
        case text
        /// A command to be executed by the execution engine.
        case command
        /// A result returned from command execution.
        case executionResult
        /// A system-generated message (join/leave notifications, errors, etc.).
        case system
        /// Binary data encoded as base64.
        case binary
    }
}

// MARK: - Wire Format

extension ChatMessage {
    /// Lightweight wire format for sending over LiveKit data channels.
    struct Wire: Codable, Sendable {
        let id: String
        let si: String   // senderIdentity
        let sn: String?  // senderName
        let c: String    // content
        let k: Kind      // kind
        let ts: TimeInterval
        let m: [String: String]?
        let t: String?   // topic

        init(from message: ChatMessage) {
            id = message.id
            si = message.senderIdentity
            sn = message.senderName
            c = message.content
            k = message.kind
            ts = message.timestamp
            m = message.metadata
            t = message.topic
        }

        func toChatMessage() -> ChatMessage {
            ChatMessage(
                id: id,
                senderIdentity: si,
                senderName: sn,
                content: c,
                kind: k,
                timestamp: ts,
                metadata: m,
                topic: t
            )
        }
    }

    /// Encode this message to JSON data for transmission.
    public func encodeToData() throws -> Data {
        try JSONEncoder().encode(Wire(from: self))
    }

    /// Decode a message from JSON data received over the wire.
    public static func decode(from data: Data) throws -> ChatMessage {
        try JSONDecoder().decode(Wire.self, from: data).toChatMessage()
    }
}
