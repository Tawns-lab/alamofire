//
//  LiveKitRoomConnection.swift
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

/// Manages a real-time WebSocket connection to a LiveKit room for data messaging.
///
/// This connection handles the data channel layer used for chat messages and
/// execution commands. It uses `URLSessionWebSocketTask` for the underlying
/// transport and provides an `AsyncStream`-based interface for incoming messages.
public final class LiveKitRoomConnection: @unchecked Sendable {
    /// Connection events emitted by the room connection.
    public enum Event: Sendable {
        /// Connected to the room successfully.
        case connected
        /// Received a data message on a topic.
        case dataReceived(data: Data, topic: String, senderIdentity: String)
        /// A participant joined the room.
        case participantJoined(identity: String, name: String)
        /// A participant left the room.
        case participantLeft(identity: String)
        /// Connection was lost (may auto-reconnect).
        case disconnected(reason: String)
        /// An error occurred on the connection.
        case error(any Error)
    }

    private let configuration: LiveKitConfiguration
    private let roomName: String
    private let accessToken: String
    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession: URLSession
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var isConnected = false
    private var reconnectAttempts = 0

    /// Creates a new room connection.
    ///
    /// - Parameters:
    ///   - configuration: The LiveKit server configuration.
    ///   - roomName: The name of the room to connect to.
    ///   - accessToken: A valid JWT access token for the room.
    public init(configuration: LiveKitConfiguration, roomName: String, accessToken: String) {
        self.configuration = configuration
        self.roomName = roomName
        self.accessToken = accessToken
        self.urlSession = URLSession(configuration: .default)
    }

    /// Opens the connection and returns an async stream of events.
    ///
    /// The stream will emit `.connected` upon successful connection, then
    /// `.dataReceived` events for incoming messages. If the connection drops,
    /// `.disconnected` is emitted and automatic reconnection is attempted
    /// if configured.
    ///
    /// - Returns: An `AsyncStream` of connection events.
    public func connect() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.eventContinuation = continuation

        continuation.onTermination = { [weak self] _ in
            self?.disconnect()
        }

        Task { [weak self] in
            await self?.establishConnection()
        }

        return stream
    }

    /// Sends data to the room on a specified topic.
    ///
    /// - Parameters:
    ///   - data: The data to send.
    ///   - topic: The data channel topic.
    public func send(data: Data, topic: String) async throws {
        guard isConnected, let task = webSocketTask else {
            throw LiveKitError.invalidState(reason: "Not connected to room")
        }

        // Wrap data in a LiveKit data packet envelope
        let envelope: [String: Any] = [
            "topic": topic,
            "data": data.base64EncodedString()
        ]

        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        try await task.send(.data(envelopeData))
    }

    /// Sends a chat message to the room.
    ///
    /// - Parameters:
    ///   - message: The chat message to send.
    ///   - topic: The topic to send on. Defaults to the configured chat topic.
    public func send(message: ChatMessage, topic: String? = nil) async throws {
        let messageData = try message.encodeToData()
        try await send(data: messageData, topic: topic ?? configuration.chatTopic)
    }

    /// Closes the connection gracefully.
    public func disconnect() {
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Private

    private func establishConnection() async {
        var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false)!
        // LiveKit WebSocket connection endpoint
        components.path = "/rtc"
        components.queryItems = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "auto_subscribe", value: "true"),
            URLQueryItem(name: "protocol", value: "9")
        ]

        guard let url = components.url else {
            eventContinuation?.yield(.error(LiveKitError.connectionFailed(reason: "Invalid URL")))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.requestTimeout

        let task = urlSession.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        isConnected = true
        reconnectAttempts = 0
        eventContinuation?.yield(.connected)

        await receiveMessages()
    }

    private func receiveMessages() async {
        guard let task = webSocketTask else { return }

        while isConnected {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    handleIncomingData(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        handleIncomingData(data)
                    }
                @unknown default:
                    break
                }
            } catch {
                if isConnected {
                    eventContinuation?.yield(.disconnected(reason: error.localizedDescription))
                    if configuration.autoReconnect {
                        await attemptReconnect()
                    }
                }
                return
            }
        }
    }

    private func handleIncomingData(_ data: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = envelope["topic"] as? String,
              let payloadB64 = envelope["data"] as? String,
              let payloadData = Data(base64Encoded: payloadB64) else {
            // Try treating the raw data as a direct message
            eventContinuation?.yield(.dataReceived(data: data, topic: "default", senderIdentity: "unknown"))
            return
        }

        let senderIdentity = envelope["sender_identity"] as? String ?? "unknown"
        eventContinuation?.yield(.dataReceived(data: payloadData, topic: topic, senderIdentity: senderIdentity))
    }

    private func attemptReconnect() async {
        guard reconnectAttempts < configuration.maxReconnectAttempts else {
            eventContinuation?.yield(.error(LiveKitError.connectionFailed(reason: "Max reconnect attempts exceeded")))
            eventContinuation?.finish()
            return
        }

        reconnectAttempts += 1
        let delay = configuration.reconnectInterval * Double(reconnectAttempts)

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        if isConnected {
            return // Already reconnected
        }

        await establishConnection()
    }
}
