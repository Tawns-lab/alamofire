//
//  RemoteNodeConnection.swift
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

/// Manages the WebSocket connection to a single remote node.
///
/// Handles the connection lifecycle, message framing, heartbeats,
/// and reconnection logic for communicating with a remote execution node.
public final class RemoteNodeConnection: @unchecked Sendable {
    /// Events emitted by the node connection.
    public enum Event: Sendable {
        case connected(RemoteNode.NodeMessage.HandshakePayload)
        case messageReceived(RemoteNode.NodeMessage)
        case heartbeat(RemoteNode.NodeMessage.HeartbeatPayload)
        case disconnected(reason: String)
        case error(any Error)
    }

    /// The node this connection targets.
    public let node: RemoteNode

    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession: URLSession
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var heartbeatTask: Task<Void, Never>?
    private var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts: Int
    private let reconnectInterval: TimeInterval
    private let heartbeatInterval: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    /// Creates a connection to a remote node.
    ///
    /// - Parameters:
    ///   - node: The target remote node.
    ///   - heartbeatInterval: Seconds between heartbeat pings. Defaults to 10.
    ///   - maxReconnectAttempts: Max reconnection tries. Defaults to 5.
    ///   - reconnectInterval: Base delay between reconnections. Defaults to 2.
    public init(
        node: RemoteNode,
        heartbeatInterval: TimeInterval = 10,
        maxReconnectAttempts: Int = 5,
        reconnectInterval: TimeInterval = 2
    ) {
        self.node = node
        self.heartbeatInterval = heartbeatInterval
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectInterval = reconnectInterval
        self.urlSession = URLSession(configuration: .default)
    }

    /// Opens the connection and returns an async stream of events.
    ///
    /// The stream emits `.connected` after a successful handshake, then
    /// `.messageReceived` for incoming node messages. Heartbeats are
    /// sent automatically at the configured interval.
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

    /// Sends a message to the remote node.
    ///
    /// - Parameter message: The node protocol message to send.
    public func send(_ message: RemoteNode.NodeMessage) async throws {
        guard isConnected, let task = webSocketTask else {
            throw LiveKitError.invalidState(reason: "Not connected to node \(node.name)")
        }

        let data = try encoder.encode(message)
        try await task.send(.data(data))
    }

    /// Dispatches a command to the remote node for execution.
    ///
    /// - Parameters:
    ///   - command: The command to execute remotely.
    ///   - timeout: Execution timeout in seconds.
    public func dispatch(_ command: Command, timeout: TimeInterval = 30) async throws {
        let payload = RemoteNode.NodeMessage.CommandDispatchPayload(command: command, timeout: timeout)
        try await send(.commandDispatch(payload))
    }

    /// Closes the connection gracefully.
    public func disconnect() {
        lock.lock()
        isConnected = false
        lock.unlock()

        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
    }

    /// Whether the connection is currently active.
    public var connected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isConnected
    }

    // MARK: - Private

    private func establishConnection() async {
        let url = node.endpoint.webSocketURL

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let task = urlSession.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        lock.lock()
        isConnected = true
        reconnectAttempts = 0
        lock.unlock()

        // Send handshake
        let handshake = RemoteNode.NodeMessage.handshake(
            RemoteNode.NodeMessage.HandshakePayload(
                nodeId: node.id,
                nodeName: node.name,
                capabilities: node.capabilities,
                metadata: node.metadata
            )
        )

        do {
            try await send(handshake)
        } catch {
            eventContinuation?.yield(.error(error))
            return
        }

        // Start heartbeat loop
        startHeartbeat()

        // Receive loop
        await receiveMessages()
    }

    private func receiveMessages() async {
        guard let task = webSocketTask else { return }

        while isConnected {
            do {
                let wsMessage = try await task.receive()
                let data: Data
                switch wsMessage {
                case .data(let d):
                    data = d
                case .string(let text):
                    guard let d = text.data(using: .utf8) else { continue }
                    data = d
                @unknown default:
                    continue
                }

                let nodeMessage = try decoder.decode(RemoteNode.NodeMessage.self, from: data)
                handleMessage(nodeMessage)

            } catch {
                if isConnected {
                    eventContinuation?.yield(.disconnected(reason: error.localizedDescription))
                    await attemptReconnect()
                }
                return
            }
        }
    }

    private func handleMessage(_ message: RemoteNode.NodeMessage) {
        switch message {
        case .handshake(let payload):
            eventContinuation?.yield(.connected(payload))

        case .heartbeat(let payload):
            eventContinuation?.yield(.heartbeat(payload))

        case .commandResult, .commandDispatch, .nodeStatus:
            eventContinuation?.yield(.messageReceived(message))
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isConnected {
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled && self.isConnected else { break }

                let ping = RemoteNode.NodeMessage.heartbeat(
                    RemoteNode.NodeMessage.HeartbeatPayload(nodeId: self.node.id)
                )
                try? await self.send(ping)
            }
        }
    }

    private func attemptReconnect() async {
        lock.lock()
        let attempts = reconnectAttempts
        lock.unlock()

        guard attempts < maxReconnectAttempts else {
            eventContinuation?.yield(.error(
                LiveKitError.connectionFailed(reason: "Max reconnect attempts (\(maxReconnectAttempts)) exceeded for node \(node.name)")
            ))
            eventContinuation?.finish()
            return
        }

        lock.lock()
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        lock.unlock()

        // Exponential backoff
        let delay = reconnectInterval * pow(2.0, Double(attempt - 1))
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        if isConnected { return }

        await establishConnection()
    }
}
