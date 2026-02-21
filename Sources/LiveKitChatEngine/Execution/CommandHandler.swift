//
//  CommandHandler.swift
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

/// A handler that can execute a specific type of command.
///
/// Implement this protocol to register custom command handlers with the
/// `ExecutionEngine`. Each handler is responsible for a single command name
/// and defines its own execution logic.
///
/// ```swift
/// struct EchoHandler: CommandHandler {
///     let name = "echo"
///     let description = "Echoes back the input arguments"
///     let usage = "/echo <message>"
///
///     func execute(_ command: Command, context: ExecutionContext) async throws -> ExecutionResult {
///         let output = command.arguments.joined(separator: " ")
///         return ExecutionResult(
///             commandId: command.id,
///             status: .success,
///             output: output,
///             duration: 0
///         )
///     }
/// }
/// ```
public protocol CommandHandler: Sendable {
    /// The command name this handler responds to (e.g., "echo", "run", "status").
    var name: String { get }

    /// A brief description of what this command does.
    var description: String { get }

    /// Usage string showing the command syntax (e.g., "/run <script> [--timeout N]").
    var usage: String { get }

    /// The minimum permission required to execute this command.
    var requiredPermission: Participant.Permissions { get }

    /// Executes the command and returns a result.
    ///
    /// - Parameters:
    ///   - command: The parsed command to execute.
    ///   - context: The execution context with environment variables and state.
    /// - Returns: The result of the execution.
    func execute(_ command: Command, context: ExecutionContext) async throws -> ExecutionResult
}

/// Default implementations for optional handler properties.
extension CommandHandler {
    public var requiredPermission: Participant.Permissions { .canExecuteCommands }
}

// MARK: - Built-in Handlers

/// Echoes back the provided arguments.
public struct EchoCommandHandler: CommandHandler {
    public let name = "echo"
    public let description = "Echoes back the input text"
    public let usage = "/echo <message>"

    public init() {}

    public func execute(_ command: Command, context: ExecutionContext) async throws -> ExecutionResult {
        let start = Date()
        let output = command.arguments.joined(separator: " ")
        return ExecutionResult(
            commandId: command.id,
            status: .success,
            output: output,
            duration: Date().timeIntervalSince(start)
        )
    }
}

/// Displays help information for available commands.
public struct HelpCommandHandler: CommandHandler {
    public let name = "help"
    public let description = "Shows available commands and their usage"
    public let usage = "/help [command]"

    private let registry: () -> [String: any CommandHandler]

    public init(registry: @escaping @Sendable () -> [String: any CommandHandler]) {
        self.registry = registry
    }

    public func execute(_ command: Command, context: ExecutionContext) async throws -> ExecutionResult {
        let start = Date()
        let handlers = registry()

        if let specificCommand = command.arguments.first {
            if let handler = handlers[specificCommand] {
                let output = """
                Command: /\(handler.name)
                Description: \(handler.description)
                Usage: \(handler.usage)
                """
                return ExecutionResult(commandId: command.id, status: .success, output: output, duration: Date().timeIntervalSince(start))
            } else {
                return ExecutionResult(commandId: command.id, status: .failure, output: "Unknown command: \(specificCommand)", duration: Date().timeIntervalSince(start))
            }
        }

        var lines = ["Available commands:"]
        for (_, handler) in handlers.sorted(by: { $0.key < $1.key }) {
            lines.append("  /\(handler.name) - \(handler.description)")
        }
        lines.append("\nUse /help <command> for detailed usage.")

        return ExecutionResult(
            commandId: command.id,
            status: .success,
            output: lines.joined(separator: "\n"),
            duration: Date().timeIntervalSince(start)
        )
    }
}

/// Displays or modifies the execution context variables.
public struct ContextCommandHandler: CommandHandler {
    public let name = "context"
    public let description = "View or modify execution context variables"
    public let usage = "/context [set <key> <value> | get <key> | list | clear]"

    public init() {}

    public func execute(_ command: Command, context: ExecutionContext) async throws -> ExecutionResult {
        let start = Date()

        guard let action = command.arguments.first else {
            // Default to listing
            return listContext(command: command, context: context, start: start)
        }

        switch action {
        case "set":
            guard command.arguments.count >= 3 else {
                return ExecutionResult(commandId: command.id, status: .failure, output: "Usage: /context set <key> <value>", duration: Date().timeIntervalSince(start))
            }
            let key = command.arguments[1]
            let value = command.arguments[2...].joined(separator: " ")
            context.setVariable(key, value: value)
            return ExecutionResult(commandId: command.id, status: .success, output: "Set \(key) = \(value)", duration: Date().timeIntervalSince(start))

        case "get":
            guard command.arguments.count >= 2 else {
                return ExecutionResult(commandId: command.id, status: .failure, output: "Usage: /context get <key>", duration: Date().timeIntervalSince(start))
            }
            let key = command.arguments[1]
            if let value = context.getVariable(key) {
                return ExecutionResult(commandId: command.id, status: .success, output: "\(key) = \(value)", duration: Date().timeIntervalSince(start))
            } else {
                return ExecutionResult(commandId: command.id, status: .failure, output: "Variable '\(key)' not found", duration: Date().timeIntervalSince(start))
            }

        case "list":
            return listContext(command: command, context: context, start: start)

        case "clear":
            context.clearVariables()
            return ExecutionResult(commandId: command.id, status: .success, output: "Context cleared", duration: Date().timeIntervalSince(start))

        default:
            return ExecutionResult(commandId: command.id, status: .failure, output: "Unknown action: \(action). Use set, get, list, or clear.", duration: Date().timeIntervalSince(start))
        }
    }

    private func listContext(command: Command, context: ExecutionContext, start: Date) -> ExecutionResult {
        let vars = context.allVariables()
        if vars.isEmpty {
            return ExecutionResult(commandId: command.id, status: .success, output: "Context is empty", duration: Date().timeIntervalSince(start))
        }
        let lines = vars.sorted(by: { $0.key < $1.key }).map { "  \($0.key) = \($0.value)" }
        return ExecutionResult(commandId: command.id, status: .success, output: "Context variables:\n" + lines.joined(separator: "\n"), duration: Date().timeIntervalSince(start))
    }
}

/// Reports the status of the execution engine and active sessions.
public struct StatusCommandHandler: CommandHandler {
    public let name = "status"
    public let description = "Shows engine and session status"
    public let usage = "/status"

    private let statusProvider: @Sendable () -> String

    public init(statusProvider: @escaping @Sendable () -> String) {
        self.statusProvider = statusProvider
    }

    public func execute(_ command: Command, context: ExecutionContext) async throws -> ExecutionResult {
        let start = Date()
        return ExecutionResult(
            commandId: command.id,
            status: .success,
            output: statusProvider(),
            duration: Date().timeIntervalSince(start)
        )
    }
}
