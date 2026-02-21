//
//  Participant.swift
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

/// A participant in a LiveKit chat room.
public struct Participant: Codable, Sendable, Identifiable, Equatable {
    /// The participant's unique identity string.
    public let id: String

    /// Human-readable display name.
    public let name: String

    /// Role determining permissions.
    public var role: Role

    /// Connection state of this participant.
    public var state: ConnectionState

    /// Unix timestamp when the participant joined.
    public let joinedAt: TimeInterval

    /// Arbitrary key-value metadata.
    public var metadata: [String: String]

    /// Set of permission flags.
    public var permissions: Permissions

    /// Creates a new participant descriptor.
    public init(
        id: String,
        name: String,
        role: Role = .participant,
        state: ConnectionState = .connected,
        joinedAt: TimeInterval = Date().timeIntervalSince1970,
        metadata: [String: String] = [:],
        permissions: Permissions = .default
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.state = state
        self.joinedAt = joinedAt
        self.metadata = metadata
        self.permissions = permissions
    }
}

// MARK: - Role

extension Participant {
    /// The role assigned to a participant which determines their capabilities.
    public enum Role: String, Codable, Sendable {
        /// Full control: can manage rooms, participants, and execute commands.
        case admin
        /// Can send messages and execute commands.
        case participant
        /// Can only observe messages, no sending or executing.
        case viewer
    }
}

// MARK: - ConnectionState

extension Participant {
    /// The connection state of a participant.
    public enum ConnectionState: String, Codable, Sendable {
        case connecting
        case connected
        case disconnecting
        case disconnected
    }
}

// MARK: - Permissions

extension Participant {
    /// Fine-grained permission flags for a participant.
    public struct Permissions: Codable, Sendable, Equatable, OptionSet {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// Can send chat messages.
        public static let canSendMessages = Permissions(rawValue: 1 << 0)
        /// Can execute commands via the execution engine.
        public static let canExecuteCommands = Permissions(rawValue: 1 << 1)
        /// Can manage (kick/mute) other participants.
        public static let canManageParticipants = Permissions(rawValue: 1 << 2)
        /// Can modify room settings.
        public static let canManageRoom = Permissions(rawValue: 1 << 3)

        /// Default permissions for a regular participant.
        public static let `default`: Permissions = [.canSendMessages, .canExecuteCommands]
        /// Full permissions for an admin.
        public static let admin: Permissions = [.canSendMessages, .canExecuteCommands, .canManageParticipants, .canManageRoom]
        /// View-only permissions.
        public static let viewer = Permissions(rawValue: 0)
    }
}
