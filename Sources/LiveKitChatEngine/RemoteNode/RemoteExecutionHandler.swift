//
//  RemoteExecutionHandler.swift
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

/// A `CommandHandler` that forwards command execution to a remote node
/// via the `RemoteNodeManager`.
///
/// Register this handler for commands that should be offloaded to remote devices.
/// When a matching command is received through chat, it gets dispatched to an
/// available remote node, executed there, and the result is returned back through
/// the engine.
///
/// ```swift
/// let nodeManager = RemoteNodeManager()
/// nodeManager.addNode(name: "Phone", host: "192.168.1.249")
///
/// let handler = RemoteExecutionHandler(
///     commandName: "run",
///     nodeManager: nodeManager,
///     strategy: .leastLoaded
/// )
/// engine.executionEngine.register(handler)
/// ```
public struct RemoteExecutionHandler: CommandHandler {
    public let name: String
    public let description: String
    public let usage: String
    public let requiredPermission: Participant.Permissions

    private let nodeManager: RemoteNodeManager
    private let strategy: RemoteNodeManager.DispatchStrategy
    private let timeout: TimeInterval

    /// Creates a remote execution handler.
    ///
    /// - Parameters:
    ///   - commandName: The command name to handle (e.g., "run", "remote").
    ///   - description: Description of the command.
    ///   - usage: Usage string.
    ///   - nodeManager: The remote node manager to dispatch through.
    ///   - strategy: Dispatch strategy for node selection.
    ///   - timeout: Execution timeout in seconds.
    ///   - requiredPermission: Permission required to use this command.
    public init(
        commandName: String,
        description: String = "Execute on a remote node",
        usage: String? = nil,
        nodeManager: RemoteNodeManager,
        strategy: RemoteNodeManager.DispatchStrategy = .firstAvailable,
        timeout: TimeInterval = 30,
        requiredPermission: Participant.Permissions = .canExecuteCommands
    ) {
        self.name = commandName
        self.description = description
        self.usage = usage ?? "/\(commandName) <arguments...>"
        self.nodeManager = nodeManager
        self.strategy = strategy
        self.timeout = timeout
        self.requiredPermission = requiredPermission
    }

    public func execute(_ command: Command, context: ExecutionContext) async throws -> ExecutionResult {
        let start = Date()

        let available = nodeManager.availableNodes()
        guard !available.isEmpty else {
            return ExecutionResult(
                commandId: command.id,
                status: .failure,
                output: "No remote nodes available for execution",
                duration: Date().timeIntervalSince(start)
            )
        }

        do {
            let result = try await nodeManager.dispatch(command, strategy: strategy, timeout: timeout)

            // Store the result in context for reference by subsequent commands
            context.setVariable("last_remote_result", value: result.output)
            context.setVariable("last_remote_status", value: result.status.rawValue)

            return result
        } catch {
            return ExecutionResult(
                commandId: command.id,
                status: .failure,
                output: "Remote execution failed: \(error.localizedDescription)",
                duration: Date().timeIntervalSince(start)
            )
        }
    }
}

/// A handler that lists and manages remote nodes through chat commands.
///
/// Provides `/nodes` to list, add, remove, and connect to remote nodes.
public struct NodesCommandHandler: CommandHandler {
    public let name = "nodes"
    public let description = "List and manage remote execution nodes"
    public let usage = "/nodes [list | add <name> <host> [port] | remove <id> | connect <id> | disconnect <id> | status]"

    private let nodeManager: RemoteNodeManager

    public init(nodeManager: RemoteNodeManager) {
        self.nodeManager = nodeManager
    }

    public func execute(_ command: Command, context: ExecutionContext) async throws -> ExecutionResult {
        let start = Date()
        let action = command.arguments.first ?? "list"

        switch action {
        case "list":
            return listNodes(commandId: command.id, start: start)

        case "add":
            return addNode(command: command, start: start)

        case "remove":
            return removeNode(command: command, start: start)

        case "connect":
            return await connectNode(command: command, start: start)

        case "disconnect":
            return disconnectNode(command: command, start: start)

        case "status":
            return nodeStatus(commandId: command.id, start: start)

        default:
            return ExecutionResult(
                commandId: command.id,
                status: .failure,
                output: "Unknown action: \(action). Use list, add, remove, connect, disconnect, or status.",
                duration: Date().timeIntervalSince(start)
            )
        }
    }

    // MARK: - Actions

    private func listNodes(commandId: String, start: Date) -> ExecutionResult {
        let nodes = nodeManager.allNodes()
        if nodes.isEmpty {
            return ExecutionResult(commandId: commandId, status: .success, output: "No remote nodes registered.", duration: Date().timeIntervalSince(start))
        }

        var lines = ["Remote Nodes (\(nodes.count)):"]
        for node in nodes.sorted(by: { $0.name < $1.name }) {
            let status = node.status.rawValue.uppercased()
            lines.append("  [\(status)] \(node.name) (\(node.id.prefix(8))...) @ \(node.endpoint.host):\(node.endpoint.port)")
            if !node.capabilities.isEmpty {
                let caps = node.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
                lines.append("    capabilities: \(caps)")
            }
        }
        return ExecutionResult(commandId: commandId, status: .success, output: lines.joined(separator: "\n"), duration: Date().timeIntervalSince(start))
    }

    private func addNode(command: Command, start: Date) -> ExecutionResult {
        guard command.arguments.count >= 3 else {
            return ExecutionResult(commandId: command.id, status: .failure, output: "Usage: /nodes add <name> <host> [port]", duration: Date().timeIntervalSince(start))
        }

        let name = command.arguments[1]
        let host = command.arguments[2]
        let port = command.arguments.count > 3 ? Int(command.arguments[3]) ?? 7880 : 7880

        let node = nodeManager.addNode(name: name, host: host, port: port)
        return ExecutionResult(
            commandId: command.id,
            status: .success,
            output: "Registered node '\(name)' at \(host):\(port) (id: \(node.id.prefix(8))...)",
            duration: Date().timeIntervalSince(start)
        )
    }

    private func removeNode(command: Command, start: Date) -> ExecutionResult {
        guard command.arguments.count >= 2 else {
            return ExecutionResult(commandId: command.id, status: .failure, output: "Usage: /nodes remove <id>", duration: Date().timeIntervalSince(start))
        }

        let idPrefix = command.arguments[1]
        let allNodes = nodeManager.allNodes()
        guard let match = allNodes.first(where: { $0.id.hasPrefix(idPrefix) }) else {
            return ExecutionResult(commandId: command.id, status: .failure, output: "No node found matching '\(idPrefix)'", duration: Date().timeIntervalSince(start))
        }

        nodeManager.removeNode(match.id)
        return ExecutionResult(commandId: command.id, status: .success, output: "Removed node '\(match.name)'", duration: Date().timeIntervalSince(start))
    }

    private func connectNode(command: Command, start: Date) async -> ExecutionResult {
        guard command.arguments.count >= 2 else {
            return ExecutionResult(commandId: command.id, status: .failure, output: "Usage: /nodes connect <id>", duration: Date().timeIntervalSince(start))
        }

        let idPrefix = command.arguments[1]
        let allNodes = nodeManager.allNodes()
        guard let match = allNodes.first(where: { $0.id.hasPrefix(idPrefix) || $0.name == idPrefix }) else {
            return ExecutionResult(commandId: command.id, status: .failure, output: "No node found matching '\(idPrefix)'", duration: Date().timeIntervalSince(start))
        }

        await nodeManager.connect(nodeId: match.id)
        return ExecutionResult(commandId: command.id, status: .success, output: "Connecting to node '\(match.name)'...", duration: Date().timeIntervalSince(start))
    }

    private func disconnectNode(command: Command, start: Date) -> ExecutionResult {
        guard command.arguments.count >= 2 else {
            return ExecutionResult(commandId: command.id, status: .failure, output: "Usage: /nodes disconnect <id>", duration: Date().timeIntervalSince(start))
        }

        let idPrefix = command.arguments[1]
        let allNodes = nodeManager.allNodes()
        guard let match = allNodes.first(where: { $0.id.hasPrefix(idPrefix) || $0.name == idPrefix }) else {
            return ExecutionResult(commandId: command.id, status: .failure, output: "No node found matching '\(idPrefix)'", duration: Date().timeIntervalSince(start))
        }

        nodeManager.disconnect(nodeId: match.id)
        return ExecutionResult(commandId: command.id, status: .success, output: "Disconnected from node '\(match.name)'", duration: Date().timeIntervalSince(start))
    }

    private func nodeStatus(commandId: String, start: Date) -> ExecutionResult {
        let all = nodeManager.allNodes()
        let available = nodeManager.availableNodes()
        let lines = [
            "Node Fleet Status:",
            "  Total registered: \(all.count)",
            "  Connected: \(available.count)",
            "  Disconnected: \(all.count - available.count)"
        ]
        return ExecutionResult(commandId: commandId, status: .success, output: lines.joined(separator: "\n"), duration: Date().timeIntervalSince(start))
    }
}
