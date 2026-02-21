//
//  ChatEngine.swift
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

/// The chat engine manages chat sessions and coordinates message delivery
/// across LiveKit room connections.
///
/// It handles:
/// - Joining/leaving rooms and managing active sessions
/// - Sending and receiving chat messages via LiveKit data channels
/// - Routing incoming messages to the correct session
/// - Detecting command messages and forwarding them to the execution engine
public final class ChatEngine: @unchecked Sendable {
    /// Delegate for chat engine events that need external handling.
    public weak var delegate: (any ChatEngineDelegate)?

    private let configuration: LiveKitConfiguration
    private let service: LiveKitService
    private var sessions: [String: ChatSession] = [:]
    private var connections: [String: LiveKitRoomConnection] = [:]
    private let router: MessageRouter
    private let commandPrefix: String
    private let lock = NSLock()

    /// Creates a new chat engine.
    ///
    /// - Parameters:
    ///   - configuration: LiveKit server configuration.
    ///   - service: LiveKit API service for server-side operations.
    ///   - router: Message router for dispatching messages.
    ///   - commandPrefix: The prefix that indicates a message is a command (e.g., "/"). Defaults to "/".
    public init(
        configuration: LiveKitConfiguration,
        service: LiveKitService,
        router: MessageRouter,
        commandPrefix: String = "/"
    ) {
        self.configuration = configuration
        self.service = service
        self.router = router
        self.commandPrefix = commandPrefix
    }

    /// Joins a room and returns an active chat session.
    ///
    /// - Parameters:
    ///   - roomName: The name of the room to join.
    ///   - identity: The local participant's identity.
    ///   - displayName: The local participant's display name.
    /// - Returns: A `ChatSession` for interacting with the room.
    public func joinRoom(
        _ roomName: String,
        identity: String,
        displayName: String
    ) async throws -> ChatSession {
        // Generate access token
        let token = service.generateAccessToken(
            identity: identity,
            name: displayName,
            room: roomName
        )

        // Create room on server (idempotent)
        let room = try await service.createRoom(name: roomName)

        // Create session
        let session = ChatSession(
            room: room,
            localIdentity: identity,
            localName: displayName
        )

        // Create connection
        let connection = LiveKitRoomConnection(
            configuration: configuration,
            roomName: roomName,
            accessToken: token
        )

        lock.lock()
        sessions[roomName] = session
        connections[roomName] = connection
        lock.unlock()

        // Start listening for events
        let eventStream = connection.connect()
        Task { [weak self] in
            for await event in eventStream {
                await self?.handleConnectionEvent(event, roomName: roomName)
            }
        }

        // Broadcast a join message
        let joinMessage = ChatMessage(
            senderIdentity: identity,
            senderName: displayName,
            content: "\(displayName) joined the room",
            kind: .system
        )
        try? await connection.send(message: joinMessage)
        session.recordSentMessage(joinMessage)

        return session
    }

    /// Leaves a room and closes the associated session.
    ///
    /// - Parameter roomName: The name of the room to leave.
    public func leaveRoom(_ roomName: String) async {
        lock.lock()
        let session = sessions.removeValue(forKey: roomName)
        let connection = connections.removeValue(forKey: roomName)
        lock.unlock()

        if let session {
            let leaveMessage = ChatMessage(
                senderIdentity: session.localIdentity,
                senderName: session.localName,
                content: "\(session.localName) left the room",
                kind: .system
            )
            try? await connection?.send(message: leaveMessage)
            session.close()
        }

        connection?.disconnect()
    }

    /// Sends a text message to a room.
    ///
    /// - Parameters:
    ///   - text: The message text.
    ///   - roomName: The target room name.
    /// - Returns: The sent `ChatMessage`.
    @discardableResult
    public func sendMessage(_ text: String, to roomName: String) async throws -> ChatMessage {
        guard let session = getSession(roomName),
              let connection = getConnection(roomName) else {
            throw LiveKitError.roomNotFound(name: roomName)
        }

        // Check if this is a command
        if text.hasPrefix(commandPrefix) {
            let commandMessage = ChatMessage(
                senderIdentity: session.localIdentity,
                senderName: session.localName,
                content: text,
                kind: .command,
                topic: configuration.chatTopic
            )

            try await connection.send(message: commandMessage, topic: configuration.executionTopic)
            session.recordSentMessage(commandMessage)

            delegate?.chatEngine(self, didDetectCommand: text, from: session.localIdentity, in: roomName)
            return commandMessage
        }

        let message = ChatMessage(
            senderIdentity: session.localIdentity,
            senderName: session.localName,
            content: text,
            kind: .text,
            topic: configuration.chatTopic
        )

        try await connection.send(message: message)
        session.recordSentMessage(message)

        return message
    }

    /// Sends binary data to a room on a specific topic.
    ///
    /// - Parameters:
    ///   - data: The data to send.
    ///   - roomName: The target room name.
    ///   - topic: The data channel topic.
    public func sendData(_ data: Data, to roomName: String, topic: String) async throws {
        guard let connection = getConnection(roomName) else {
            throw LiveKitError.roomNotFound(name: roomName)
        }
        try await connection.send(data: data, topic: topic)
    }

    /// Returns the active session for a room, if any.
    public func session(for roomName: String) -> ChatSession? {
        getSession(roomName)
    }

    /// Returns all active room names.
    public func activeRooms() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.keys)
    }

    // MARK: - Private

    private func getSession(_ roomName: String) -> ChatSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[roomName]
    }

    private func getConnection(_ roomName: String) -> LiveKitRoomConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections[roomName]
    }

    private func handleConnectionEvent(_ event: LiveKitRoomConnection.Event, roomName: String) async {
        guard let session = getSession(roomName) else { return }

        switch event {
        case .connected:
            delegate?.chatEngine(self, didConnectToRoom: roomName)

        case .dataReceived(let data, let topic, let senderIdentity):
            router.route(data: data, topic: topic, senderIdentity: senderIdentity)

            // Also deliver to the session directly for chat messages
            if topic == configuration.chatTopic || topic == "default" {
                if let message = try? ChatMessage.decode(from: data) {
                    if message.senderIdentity != session.localIdentity {
                        session.handleIncomingMessage(message)
                    }
                }
            }

        case .participantJoined(let identity, let name):
            let participant = Participant(id: identity, name: name)
            session.handleParticipantJoined(participant)
            delegate?.chatEngine(self, participantJoined: identity, in: roomName)

        case .participantLeft(let identity):
            session.handleParticipantLeft(identity)
            delegate?.chatEngine(self, participantLeft: identity, from: roomName)

        case .disconnected(let reason):
            delegate?.chatEngine(self, didDisconnectFromRoom: roomName, reason: reason)

        case .error(let error):
            session.handleError(error)
        }
    }
}

// MARK: - ChatEngineDelegate

/// Delegate protocol for receiving chat engine lifecycle events.
public protocol ChatEngineDelegate: AnyObject, Sendable {
    /// Called when the engine connects to a room.
    func chatEngine(_ engine: ChatEngine, didConnectToRoom room: String)

    /// Called when the engine disconnects from a room.
    func chatEngine(_ engine: ChatEngine, didDisconnectFromRoom room: String, reason: String)

    /// Called when a command message is detected.
    func chatEngine(_ engine: ChatEngine, didDetectCommand command: String, from sender: String, in room: String)

    /// Called when a participant joins a room.
    func chatEngine(_ engine: ChatEngine, participantJoined identity: String, in room: String)

    /// Called when a participant leaves a room.
    func chatEngine(_ engine: ChatEngine, participantLeft identity: String, from room: String)
}

/// Default no-op implementations for optional delegate methods.
extension ChatEngineDelegate {
    public func chatEngine(_ engine: ChatEngine, didConnectToRoom room: String) {}
    public func chatEngine(_ engine: ChatEngine, didDisconnectFromRoom room: String, reason: String) {}
    public func chatEngine(_ engine: ChatEngine, didDetectCommand command: String, from sender: String, in room: String) {}
    public func chatEngine(_ engine: ChatEngine, participantJoined identity: String, in room: String) {}
    public func chatEngine(_ engine: ChatEngine, participantLeft identity: String, from room: String) {}
}
