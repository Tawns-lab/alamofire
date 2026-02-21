//
//  LiveKitChatExecutionEngine.swift
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

import Alamofire
import Foundation

/// The main entry point for the LiveKit Chat + Execution Engine.
///
/// `LiveKitChatExecutionEngine` coordinates the chat engine, execution engine,
/// and LiveKit service layer to provide a unified real-time chat system with
/// built-in command execution capabilities.
///
/// ## Quick Start
///
/// ```swift
/// let config = LiveKitConfiguration(
///     serverURL: URL(string: "wss://my-server.livekit.cloud")!,
///     apiKey: "your-api-key",
///     apiSecret: "your-api-secret"
/// )
///
/// let engine = LiveKitChatExecutionEngine(configuration: config)
///
/// // Register custom commands
/// engine.registerCommand(MyCustomHandler())
///
/// // Join a room
/// let session = try await engine.joinRoom("my-room", identity: "user1", name: "Alice")
///
/// // Send messages (commands are detected automatically)
/// try await engine.send("Hello everyone!", to: "my-room")
/// try await engine.send("/echo Hello from the engine", to: "my-room")
///
/// // Listen for events
/// for await event in session.events() {
///     switch event {
///     case .messageReceived(let msg): print("Got: \(msg.content)")
///     case .executionResultReceived(let result): print("Result: \(result.output)")
///     default: break
///     }
/// }
/// ```
public final class LiveKitChatExecutionEngine: @unchecked Sendable {
    /// Engine lifecycle events.
    public enum Event: Sendable {
        /// The engine started successfully.
        case started
        /// The engine stopped.
        case stopped
        /// Connected to a room.
        case roomJoined(String)
        /// Disconnected from a room.
        case roomLeft(String)
        /// A command was executed with a result.
        case commandExecuted(Command, ExecutionResult)
        /// An error occurred.
        case error(any Error)
    }

    /// The LiveKit server configuration.
    public let configuration: LiveKitConfiguration

    /// The underlying chat engine.
    public let chatEngine: ChatEngine

    /// The underlying execution engine.
    public let executionEngine: ExecutionEngine

    /// The LiveKit HTTP service client.
    public let service: LiveKitService

    /// The message router.
    public let router: MessageRouter

    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var isRunning = false
    private let lock = NSLock()

    /// Creates a new LiveKit Chat + Execution Engine.
    ///
    /// - Parameters:
    ///   - configuration: The LiveKit server configuration.
    ///   - session: An Alamofire session for HTTP requests. Defaults to `.default`.
    ///   - commandPrefix: The prefix for command messages. Defaults to "/".
    ///   - commandTimeout: Default timeout for command execution. Defaults to 30 seconds.
    public init(
        configuration: LiveKitConfiguration,
        session: Session = .default,
        commandPrefix: String = "/",
        commandTimeout: TimeInterval = 30
    ) {
        self.configuration = configuration

        self.service = LiveKitService(configuration: configuration, session: session)
        self.router = MessageRouter(configuration: configuration)
        self.executionEngine = ExecutionEngine(
            commandPrefix: commandPrefix,
            defaultTimeout: commandTimeout
        )
        self.chatEngine = ChatEngine(
            configuration: configuration,
            service: service,
            router: router,
            commandPrefix: commandPrefix
        )

        setupRouting()
    }

    // MARK: - Lifecycle

    /// Starts the engine and returns an async stream of lifecycle events.
    ///
    /// - Returns: An `AsyncStream` of engine events.
    public func start() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()

        lock.lock()
        self.eventContinuation = continuation
        self.isRunning = true
        lock.unlock()

        continuation.yield(.started)

        return stream
    }

    /// Stops the engine, leaving all rooms and cancelling active commands.
    public func stop() async {
        lock.lock()
        isRunning = false
        lock.unlock()

        // Leave all rooms
        for room in chatEngine.activeRooms() {
            await chatEngine.leaveRoom(room)
        }

        // Cancel all active commands
        executionEngine.cancelAll()

        eventContinuation?.yield(.stopped)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Room Operations

    /// Joins a LiveKit room for chat and command execution.
    ///
    /// - Parameters:
    ///   - roomName: The room name to join.
    ///   - identity: The local participant's identity.
    ///   - name: The local participant's display name.
    /// - Returns: A `ChatSession` for the joined room.
    public func joinRoom(
        _ roomName: String,
        identity: String,
        name: String
    ) async throws -> ChatSession {
        let session = try await chatEngine.joinRoom(roomName, identity: identity, displayName: name)
        eventContinuation?.yield(.roomJoined(roomName))
        return session
    }

    /// Leaves a room.
    ///
    /// - Parameter roomName: The room name to leave.
    public func leaveRoom(_ roomName: String) async {
        await chatEngine.leaveRoom(roomName)
        eventContinuation?.yield(.roomLeft(roomName))
    }

    // MARK: - Messaging

    /// Sends a message to a room. Commands (prefixed messages) are automatically
    /// parsed and executed, with results broadcast back to the room.
    ///
    /// - Parameters:
    ///   - text: The message text.
    ///   - roomName: The target room.
    /// - Returns: The sent chat message.
    @discardableResult
    public func send(_ text: String, to roomName: String) async throws -> ChatMessage {
        let message = try await chatEngine.sendMessage(text, to: roomName)

        // If this was a command, execute it
        if message.kind == .command {
            let session = chatEngine.session(for: roomName)
            let permissions = Participant.Permissions.default

            if let result = try? await executionEngine.processMessage(
                message,
                roomId: roomName,
                senderPermissions: permissions
            ) {
                // Broadcast result back to the room
                let resultMessage = result.toChatMessage(
                    senderIdentity: session?.localIdentity ?? "system"
                )
                try? await chatEngine.sendData(
                    resultMessage.encodeToData(),
                    to: roomName,
                    topic: configuration.chatTopic
                )

                session?.handleExecutionResult(result)
                eventContinuation?.yield(.commandExecuted(
                    Command(
                        name: "",
                        rawText: text,
                        senderIdentity: session?.localIdentity ?? "",
                        roomId: roomName
                    ),
                    result
                ))
            }
        }

        return message
    }

    /// Sends binary data to a room on a specific topic.
    ///
    /// - Parameters:
    ///   - data: The data to send.
    ///   - roomName: The target room.
    ///   - topic: The data channel topic.
    public func sendData(_ data: Data, to roomName: String, topic: String) async throws {
        try await chatEngine.sendData(data, to: roomName, topic: topic)
    }

    // MARK: - Command Registration

    /// Registers a custom command handler with the execution engine.
    ///
    /// - Parameter handler: The command handler to register.
    public func registerCommand(_ handler: any CommandHandler) {
        executionEngine.register(handler)
    }

    /// Unregisters a command handler by name.
    ///
    /// - Parameter name: The command name to unregister.
    public func unregisterCommand(_ name: String) {
        executionEngine.unregister(name)
    }

    // MARK: - Server Operations

    /// Creates a room on the LiveKit server.
    ///
    /// - Parameters:
    ///   - name: The room name.
    ///   - maxParticipants: Maximum number of participants (0 = unlimited).
    /// - Returns: The created `ChatRoom`.
    public func createRoom(name: String, maxParticipants: Int = 0) async throws -> ChatRoom {
        try await service.createRoom(name: name, maxParticipants: maxParticipants)
    }

    /// Lists rooms on the LiveKit server.
    ///
    /// - Parameter names: Optional filter by room names.
    /// - Returns: An array of `ChatRoom` descriptors.
    public func listRooms(names: [String]? = nil) async throws -> [ChatRoom] {
        try await service.listRooms(names: names)
    }

    /// Deletes a room from the LiveKit server.
    ///
    /// - Parameter name: The room name to delete.
    public func deleteRoom(_ name: String) async throws {
        try await service.deleteRoom(name)
    }

    /// Lists participants in a room.
    ///
    /// - Parameter roomName: The room name.
    /// - Returns: An array of `Participant` descriptors.
    public func listParticipants(in roomName: String) async throws -> [Participant] {
        try await service.listParticipants(room: roomName)
    }

    // MARK: - State

    /// Whether the engine is currently running.
    public var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    /// Returns the names of all rooms the engine is currently connected to.
    public var activeRooms: [String] {
        chatEngine.activeRooms()
    }

    /// Returns the chat session for a specific room, if connected.
    public func session(for roomName: String) -> ChatSession? {
        chatEngine.session(for: roomName)
    }

    // MARK: - Private

    private func setupRouting() {
        // Route incoming chat messages that are commands to the execution engine
        router.onChatMessage { [weak self] message in
            guard let self, message.kind == .command else { return }

            Task { [weak self] in
                guard let self else { return }
                let result = try? await self.executionEngine.processMessage(
                    message,
                    roomId: message.topic ?? "default",
                    senderPermissions: .default
                )
                if let result {
                    let session = self.chatEngine.session(for: message.topic ?? "default")
                    session?.handleExecutionResult(result)
                }
            }
        }

        // Route execution data to the execution engine
        router.onExecutionData { [weak self] data, senderIdentity in
            guard let self else { return }
            if let message = try? ChatMessage.decode(from: data) {
                Task { [weak self] in
                    _ = try? await self?.executionEngine.processMessage(
                        message,
                        roomId: message.topic ?? "default",
                        senderPermissions: .default
                    )
                }
            }
        }
    }
}
