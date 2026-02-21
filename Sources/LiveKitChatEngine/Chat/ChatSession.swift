//
//  ChatSession.swift
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

/// Manages an active chat session within a LiveKit room.
///
/// A `ChatSession` maintains the local message history, tracks participants,
/// and provides an `AsyncStream` of incoming events (new messages, participant
/// changes, execution results).
public final class ChatSession: @unchecked Sendable {
    /// Events emitted by the chat session.
    public enum Event: Sendable {
        /// A new message was received.
        case messageReceived(ChatMessage)
        /// A message was sent successfully.
        case messageSent(ChatMessage)
        /// A participant joined the room.
        case participantJoined(Participant)
        /// A participant left the room.
        case participantLeft(String)
        /// An execution result was received.
        case executionResultReceived(ExecutionResult)
        /// The session encountered an error.
        case error(any Error)
    }

    /// The room this session is connected to.
    public let room: ChatRoom

    /// The local participant's identity.
    public let localIdentity: String

    /// The local participant's display name.
    public let localName: String

    private var messages: [ChatMessage] = []
    private var participants: [String: Participant] = [:]
    private let messagesLock = NSLock()
    private let participantsLock = NSLock()
    private var eventContinuation: AsyncStream<Event>.Continuation?

    /// The maximum number of messages to retain in the local history.
    public let maxHistorySize: Int

    /// Creates a new chat session.
    ///
    /// - Parameters:
    ///   - room: The room descriptor.
    ///   - localIdentity: The local participant's identity.
    ///   - localName: The local participant's display name.
    ///   - maxHistorySize: Maximum messages to keep in memory. Defaults to 1000.
    public init(
        room: ChatRoom,
        localIdentity: String,
        localName: String,
        maxHistorySize: Int = 1000
    ) {
        self.room = room
        self.localIdentity = localIdentity
        self.localName = localName
        self.maxHistorySize = maxHistorySize
    }

    /// Returns an async stream of session events.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.eventContinuation = continuation
        return stream
    }

    /// Returns the current message history.
    public func messageHistory() -> [ChatMessage] {
        messagesLock.lock()
        defer { messagesLock.unlock() }
        return messages
    }

    /// Returns the current list of participants.
    public func currentParticipants() -> [Participant] {
        participantsLock.lock()
        defer { participantsLock.unlock() }
        return Array(participants.values)
    }

    /// Returns a specific participant by identity.
    public func participant(withIdentity identity: String) -> Participant? {
        participantsLock.lock()
        defer { participantsLock.unlock() }
        return participants[identity]
    }

    // MARK: - Internal Event Handlers

    /// Records a message that was sent by the local participant.
    func recordSentMessage(_ message: ChatMessage) {
        appendMessage(message)
        eventContinuation?.yield(.messageSent(message))
    }

    /// Processes an incoming message from the room.
    func handleIncomingMessage(_ message: ChatMessage) {
        appendMessage(message)
        eventContinuation?.yield(.messageReceived(message))
    }

    /// Records a participant joining the room.
    func handleParticipantJoined(_ participant: Participant) {
        participantsLock.lock()
        participants[participant.id] = participant
        participantsLock.unlock()
        eventContinuation?.yield(.participantJoined(participant))
    }

    /// Records a participant leaving the room.
    func handleParticipantLeft(_ identity: String) {
        participantsLock.lock()
        participants.removeValue(forKey: identity)
        participantsLock.unlock()
        eventContinuation?.yield(.participantLeft(identity))
    }

    /// Processes an execution result.
    func handleExecutionResult(_ result: ExecutionResult) {
        let message = result.toChatMessage(senderIdentity: "system", topic: nil)
        appendMessage(message)
        eventContinuation?.yield(.executionResultReceived(result))
    }

    /// Reports an error to the session.
    func handleError(_ error: any Error) {
        eventContinuation?.yield(.error(error))
    }

    /// Closes the event stream.
    func close() {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Private

    private func appendMessage(_ message: ChatMessage) {
        messagesLock.lock()
        messages.append(message)
        if messages.count > maxHistorySize {
            messages.removeFirst(messages.count - maxHistorySize)
        }
        messagesLock.unlock()
    }
}
