//
//  ChatRoom.swift
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

/// Represents a LiveKit room used for chat and command execution.
public struct ChatRoom: Codable, Sendable, Identifiable, Equatable {
    /// Unique room name (used as the LiveKit room identifier).
    public let id: String

    /// Human-readable display name for the room.
    public let name: String

    /// Current status of the room.
    public var status: Status

    /// Maximum number of participants allowed (0 = unlimited).
    public let maxParticipants: Int

    /// Unix timestamp of room creation.
    public let createdAt: TimeInterval

    /// Room-level metadata.
    public var metadata: [String: String]

    /// Identities of participants currently in the room.
    public var participantIdentities: [String]

    /// Creates a new chat room descriptor.
    public init(
        id: String = UUID().uuidString,
        name: String,
        status: Status = .active,
        maxParticipants: Int = 0,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        metadata: [String: String] = [:],
        participantIdentities: [String] = []
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.maxParticipants = maxParticipants
        self.createdAt = createdAt
        self.metadata = metadata
        self.participantIdentities = participantIdentities
    }
}

// MARK: - Status

extension ChatRoom {
    /// The lifecycle status of a chat room.
    public enum Status: String, Codable, Sendable {
        case active
        case closed
        case suspended
    }
}
