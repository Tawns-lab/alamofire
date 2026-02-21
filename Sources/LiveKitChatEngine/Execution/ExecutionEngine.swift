//
//  ExecutionEngine.swift
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

/// The execution engine processes commands received through chat messages.
///
/// It maintains a registry of command handlers, manages per-session execution
/// contexts, and coordinates command parsing, permission checking, and execution.
///
/// ## Usage
///
/// ```swift
/// let engine = ExecutionEngine()
/// engine.register(EchoCommandHandler())
/// engine.register(MyCustomHandler())
///
/// let result = try await engine.execute(command, senderPermissions: .default)
/// ```
public final class ExecutionEngine: @unchecked Sendable {
    /// Delegate for execution lifecycle events.
    public weak var delegate: (any ExecutionEngineDelegate)?

    private var handlers: [String: any CommandHandler] = [:]
    private var contexts: [String: ExecutionContext] = [:]
    private var activeTasks: [String: Task<ExecutionResult, any Error>] = [:]
    private let parser: CommandParser
    private let defaultTimeout: TimeInterval
    private let lock = NSLock()

    /// Creates a new execution engine.
    ///
    /// - Parameters:
    ///   - commandPrefix: The command prefix for parsing. Defaults to "/".
    ///   - defaultTimeout: Default timeout for command execution in seconds. Defaults to 30.
    ///   - registerBuiltins: Whether to register built-in command handlers. Defaults to true.
    public init(
        commandPrefix: String = "/",
        defaultTimeout: TimeInterval = 30,
        registerBuiltins: Bool = true
    ) {
        self.parser = CommandParser(prefix: commandPrefix)
        self.defaultTimeout = defaultTimeout

        if registerBuiltins {
            registerBuiltinHandlers()
        }
    }

    // MARK: - Handler Registration

    /// Registers a command handler.
    ///
    /// If a handler with the same name is already registered, it will be replaced.
    ///
    /// - Parameter handler: The command handler to register.
    public func register(_ handler: any CommandHandler) {
        lock.lock()
        handlers[handler.name] = handler
        lock.unlock()
    }

    /// Unregisters a command handler by name.
    ///
    /// - Parameter name: The command name to unregister.
    public func unregister(_ name: String) {
        lock.lock()
        handlers.removeValue(forKey: name)
        lock.unlock()
    }

    /// Returns the registered handler for a command name.
    public func handler(for name: String) -> (any CommandHandler)? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[name]
    }

    /// Returns all registered handlers.
    public func registeredHandlers() -> [String: any CommandHandler] {
        lock.lock()
        defer { lock.unlock() }
        return handlers
    }

    // MARK: - Context Management

    /// Gets or creates an execution context for a room/participant combination.
    ///
    /// - Parameters:
    ///   - roomId: The room identifier.
    ///   - identity: The participant identity.
    /// - Returns: The execution context.
    public func context(for roomId: String, identity: String) -> ExecutionContext {
        let key = "\(roomId):\(identity)"
        lock.lock()
        if let existing = contexts[key] {
            lock.unlock()
            return existing
        }
        let ctx = ExecutionContext(ownerIdentity: identity, roomId: roomId)
        contexts[key] = ctx
        lock.unlock()
        return ctx
    }

    // MARK: - Command Execution

    /// Parses a chat message and executes it as a command if applicable.
    ///
    /// - Parameters:
    ///   - message: The chat message to process.
    ///   - roomId: The room where the message was sent.
    ///   - senderPermissions: The sender's permission set.
    /// - Returns: An `ExecutionResult` if the message was a command, otherwise `nil`.
    public func processMessage(
        _ message: ChatMessage,
        roomId: String,
        senderPermissions: Participant.Permissions
    ) async throws -> ExecutionResult? {
        guard let command = parser.parse(message: message, roomId: roomId) else {
            return nil
        }
        return try await execute(command, senderPermissions: senderPermissions)
    }

    /// Executes a parsed command.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - senderPermissions: The sender's permission set.
    /// - Returns: The execution result.
    public func execute(
        _ command: Command,
        senderPermissions: Participant.Permissions
    ) async throws -> ExecutionResult {
        let start = Date()

        // Look up handler
        lock.lock()
        let handler = handlers[command.name]
        lock.unlock()

        guard let handler else {
            return ExecutionResult(
                commandId: command.id,
                status: .failure,
                output: "Unknown command: /\(command.name). Use /help for available commands.",
                duration: Date().timeIntervalSince(start)
            )
        }

        // Check permissions
        guard senderPermissions.contains(handler.requiredPermission) else {
            delegate?.executionEngine(self, permissionDeniedFor: command)
            return ExecutionResult(
                commandId: command.id,
                status: .failure,
                output: "Permission denied: insufficient permissions for /\(command.name)",
                duration: Date().timeIntervalSince(start)
            )
        }

        let ctx = context(for: command.roomId, identity: command.senderIdentity)

        delegate?.executionEngine(self, willExecute: command)

        // Execute with timeout
        let timeout = TimeInterval(command.options["timeout"] ?? "") ?? defaultTimeout

        let task = Task<ExecutionResult, any Error> {
            try await handler.execute(command, context: ctx)
        }

        lock.lock()
        activeTasks[command.id] = task
        lock.unlock()

        defer {
            lock.lock()
            activeTasks.removeValue(forKey: command.id)
            lock.unlock()
        }

        let result: ExecutionResult
        do {
            result = try await withTimeout(seconds: timeout) {
                try await task.value
            }
        } catch is TimeoutError {
            task.cancel()
            result = ExecutionResult(
                commandId: command.id,
                status: .timedOut,
                output: "Command /\(command.name) timed out after \(Int(timeout))s",
                duration: Date().timeIntervalSince(start)
            )
        } catch is CancellationError {
            result = ExecutionResult(
                commandId: command.id,
                status: .cancelled,
                output: "Command /\(command.name) was cancelled",
                duration: Date().timeIntervalSince(start)
            )
        } catch {
            result = ExecutionResult(
                commandId: command.id,
                status: .failure,
                output: "Error executing /\(command.name): \(error.localizedDescription)",
                duration: Date().timeIntervalSince(start)
            )
        }

        delegate?.executionEngine(self, didExecute: command, result: result)
        return result
    }

    /// Cancels a running command by its ID.
    ///
    /// - Parameter commandId: The command ID to cancel.
    /// - Returns: Whether a matching running command was found and cancelled.
    @discardableResult
    public func cancelCommand(_ commandId: String) -> Bool {
        lock.lock()
        let task = activeTasks[commandId]
        lock.unlock()

        guard let task else { return false }
        task.cancel()
        return true
    }

    /// Cancels all running commands.
    public func cancelAll() {
        lock.lock()
        let tasks = activeTasks.values
        lock.unlock()

        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - Private

    private func registerBuiltinHandlers() {
        register(EchoCommandHandler())
        register(ContextCommandHandler())
        register(HelpCommandHandler { [weak self] in
            self?.registeredHandlers() ?? [:]
        })
        register(StatusCommandHandler { [weak self] in
            guard let self else { return "Engine unavailable" }
            self.lock.lock()
            let handlerCount = self.handlers.count
            let activeCount = self.activeTasks.count
            let contextCount = self.contexts.count
            self.lock.unlock()
            return """
            Execution Engine Status:
              Registered commands: \(handlerCount)
              Active executions: \(activeCount)
              Active contexts: \(contextCount)
            """
        })
    }
}

// MARK: - ExecutionEngineDelegate

/// Delegate for monitoring execution engine lifecycle events.
public protocol ExecutionEngineDelegate: AnyObject, Sendable {
    /// Called before a command begins executing.
    func executionEngine(_ engine: ExecutionEngine, willExecute command: Command)

    /// Called after a command finishes executing.
    func executionEngine(_ engine: ExecutionEngine, didExecute command: Command, result: ExecutionResult)

    /// Called when a command execution is denied due to insufficient permissions.
    func executionEngine(_ engine: ExecutionEngine, permissionDeniedFor command: Command)
}

/// Default no-op implementations.
extension ExecutionEngineDelegate {
    public func executionEngine(_ engine: ExecutionEngine, willExecute command: Command) {}
    public func executionEngine(_ engine: ExecutionEngine, didExecute command: Command, result: ExecutionResult) {}
    public func executionEngine(_ engine: ExecutionEngine, permissionDeniedFor command: Command) {}
}

// MARK: - Timeout Utilities

private struct TimeoutError: Error {}

private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }

        guard let result = try await group.next() else {
            throw TimeoutError()
        }

        group.cancelAll()
        return result
    }
}
