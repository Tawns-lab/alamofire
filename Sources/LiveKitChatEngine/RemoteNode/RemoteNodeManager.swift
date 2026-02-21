//
//  RemoteNodeManager.swift
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

/// Manages the fleet of remote execution nodes.
///
/// The `RemoteNodeManager` handles registration, connection lifecycle,
/// health monitoring, and command routing to remote nodes. It provides
/// both manual registration and network-based node discovery.
///
/// ```swift
/// let manager = RemoteNodeManager()
///
/// // Register a node by IP
/// let node = manager.addNode(name: "Pixel-7", host: "192.168.1.249", port: 7880)
///
/// // Connect to all registered nodes
/// await manager.connectAll()
///
/// // Dispatch a command to the best available node
/// let result = try await manager.dispatch(command)
/// ```
public final class RemoteNodeManager: @unchecked Sendable {
    /// Events emitted by the node manager.
    public enum Event: Sendable {
        case nodeRegistered(RemoteNode)
        case nodeConnected(String)
        case nodeDisconnected(String, reason: String)
        case nodeRemoved(String)
        case commandDispatched(String, toNode: String)
        case commandCompleted(String, fromNode: String, ExecutionResult)
        case healthCheckFailed(String)
    }

    /// Strategy for selecting which node receives a command.
    public enum DispatchStrategy: Sendable {
        /// Send to the first available connected node.
        case firstAvailable
        /// Round-robin across connected nodes.
        case roundRobin
        /// Send to the node with the lowest reported load.
        case leastLoaded
        /// Send to a specific node by ID.
        case targeted(nodeId: String)
        /// Broadcast to all connected nodes (first result wins).
        case broadcast
    }

    private var nodes: [String: RemoteNode] = [:]
    private var connections: [String: RemoteNodeConnection] = [:]
    private var nodeLoads: [String: Double] = [:]
    private var pendingResults: [String: CheckedContinuation<ExecutionResult, any Error>] = [:]
    private var roundRobinIndex = 0
    private let lock = NSLock()
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private let healthCheckInterval: TimeInterval
    private var healthCheckTask: Task<Void, Never>?

    /// Creates a new remote node manager.
    ///
    /// - Parameter healthCheckInterval: Seconds between health checks. Defaults to 30.
    public init(healthCheckInterval: TimeInterval = 30) {
        self.healthCheckInterval = healthCheckInterval
    }

    /// Returns an async stream of manager events.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.eventContinuation = continuation
        return stream
    }

    // MARK: - Node Registration

    /// Registers a remote node by endpoint details.
    ///
    /// - Parameters:
    ///   - name: Human-readable name for the node.
    ///   - host: The node's IP address or hostname.
    ///   - port: The node's port. Defaults to 7880.
    ///   - scheme: WebSocket scheme. Defaults to `.ws`.
    ///   - capabilities: The node's capabilities. Defaults to `[.executeCommands]`.
    ///   - metadata: Optional metadata about the node.
    /// - Returns: The registered `RemoteNode`.
    @discardableResult
    public func addNode(
        name: String,
        host: String,
        port: Int = 7880,
        scheme: RemoteNode.Endpoint.Scheme = .ws,
        capabilities: Set<RemoteNode.Capability> = [.executeCommands],
        metadata: [String: String] = [:]
    ) -> RemoteNode {
        let endpoint = RemoteNode.Endpoint(host: host, port: port, scheme: scheme)
        let node = RemoteNode(
            name: name,
            endpoint: endpoint,
            capabilities: capabilities,
            metadata: metadata
        )
        return addNode(node)
    }

    /// Registers a pre-configured remote node.
    ///
    /// - Parameter node: The node to register.
    /// - Returns: The registered node.
    @discardableResult
    public func addNode(_ node: RemoteNode) -> RemoteNode {
        lock.lock()
        nodes[node.id] = node
        lock.unlock()

        eventContinuation?.yield(.nodeRegistered(node))
        return node
    }

    /// Removes a node and disconnects if connected.
    ///
    /// - Parameter nodeId: The ID of the node to remove.
    public func removeNode(_ nodeId: String) {
        lock.lock()
        nodes.removeValue(forKey: nodeId)
        let connection = connections.removeValue(forKey: nodeId)
        lock.unlock()

        connection?.disconnect()
        eventContinuation?.yield(.nodeRemoved(nodeId))
    }

    /// Returns all registered nodes.
    public func allNodes() -> [RemoteNode] {
        lock.lock()
        defer { lock.unlock() }
        return Array(nodes.values)
    }

    /// Returns only connected, available nodes.
    public func availableNodes() -> [RemoteNode] {
        lock.lock()
        defer { lock.unlock() }
        return nodes.values.filter { $0.isAvailable }
    }

    /// Returns a specific node by ID.
    public func node(withId id: String) -> RemoteNode? {
        lock.lock()
        defer { lock.unlock() }
        return nodes[id]
    }

    // MARK: - Connection Management

    /// Connects to a specific registered node.
    ///
    /// - Parameter nodeId: The ID of the node to connect to.
    public func connect(nodeId: String) async {
        lock.lock()
        guard var node = nodes[nodeId] else {
            lock.unlock()
            return
        }
        node.status = .connecting
        nodes[nodeId] = node
        lock.unlock()

        let connection = RemoteNodeConnection(node: node)

        lock.lock()
        connections[nodeId] = connection
        lock.unlock()

        let eventStream = connection.connect()

        Task { [weak self] in
            for await event in eventStream {
                self?.handleConnectionEvent(event, nodeId: nodeId)
            }
        }
    }

    /// Connects to all registered nodes.
    public func connectAll() async {
        let nodeIds: [String]
        lock.lock()
        nodeIds = Array(nodes.keys)
        lock.unlock()

        await withTaskGroup(of: Void.self) { group in
            for nodeId in nodeIds {
                group.addTask { [weak self] in
                    await self?.connect(nodeId: nodeId)
                }
            }
        }
    }

    /// Disconnects from a specific node.
    public func disconnect(nodeId: String) {
        lock.lock()
        let connection = connections.removeValue(forKey: nodeId)
        if var node = nodes[nodeId] {
            node.status = .disconnected
            nodes[nodeId] = node
        }
        lock.unlock()

        connection?.disconnect()
    }

    /// Disconnects from all nodes and stops health checking.
    public func disconnectAll() {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        lock.lock()
        let allConnections = connections
        connections.removeAll()
        for (id, _) in nodes {
            nodes[id]?.status = .disconnected
        }
        lock.unlock()

        for (_, connection) in allConnections {
            connection.disconnect()
        }
    }

    // MARK: - Command Dispatch

    /// Dispatches a command to a remote node for execution.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - strategy: The dispatch strategy. Defaults to `.firstAvailable`.
    ///   - timeout: Execution timeout in seconds. Defaults to 30.
    /// - Returns: The execution result from the remote node.
    public func dispatch(
        _ command: Command,
        strategy: DispatchStrategy = .firstAvailable,
        timeout: TimeInterval = 30
    ) async throws -> ExecutionResult {
        let targetNodeId = try selectNode(for: strategy)

        lock.lock()
        guard let connection = connections[targetNodeId] else {
            lock.unlock()
            throw LiveKitError.connectionFailed(reason: "No connection for node \(targetNodeId)")
        }
        lock.unlock()

        eventContinuation?.yield(.commandDispatched(command.id, toNode: targetNodeId))

        try await connection.dispatch(command, timeout: timeout)

        // Wait for the result with timeout
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingResults[command.id] = continuation
            lock.unlock()

            // Timeout task
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                self.lock.lock()
                let pending = self.pendingResults.removeValue(forKey: command.id)
                self.lock.unlock()

                if let pending {
                    let timeoutResult = ExecutionResult(
                        commandId: command.id,
                        status: .timedOut,
                        output: "Remote execution timed out on node \(targetNodeId)",
                        duration: timeout
                    )
                    pending.resume(returning: timeoutResult)
                }
            }
        }
    }

    // MARK: - Health Monitoring

    /// Starts periodic health checking of all connected nodes.
    public func startHealthMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.healthCheckInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self.performHealthCheck()
            }
        }
    }

    /// Stops periodic health checking.
    public func stopHealthMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

    // MARK: - Private

    private func selectNode(for strategy: DispatchStrategy) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let available = nodes.filter { $0.value.isAvailable }
        guard !available.isEmpty else {
            throw LiveKitError.connectionFailed(reason: "No available remote nodes")
        }

        switch strategy {
        case .firstAvailable:
            return available.first!.key

        case .roundRobin:
            let keys = available.keys.sorted()
            let index = roundRobinIndex % keys.count
            roundRobinIndex += 1
            return keys[index]

        case .leastLoaded:
            let sorted = available.sorted { a, b in
                (nodeLoads[a.key] ?? 0) < (nodeLoads[b.key] ?? 0)
            }
            return sorted.first!.key

        case .targeted(let nodeId):
            guard available[nodeId] != nil else {
                throw LiveKitError.participantNotFound(identity: "Node \(nodeId) not available")
            }
            return nodeId

        case .broadcast:
            // For broadcast, just pick the first; actual broadcast is handled by the caller
            return available.first!.key
        }
    }

    private func handleConnectionEvent(_ event: RemoteNodeConnection.Event, nodeId: String) {
        switch event {
        case .connected(let handshake):
            lock.lock()
            nodes[nodeId]?.status = .connected
            nodes[nodeId]?.capabilities = handshake.capabilities
            nodes[nodeId]?.metadata.merge(handshake.metadata) { _, new in new }
            nodes[nodeId]?.lastHeartbeat = Date().timeIntervalSince1970
            lock.unlock()
            eventContinuation?.yield(.nodeConnected(nodeId))

        case .heartbeat(let payload):
            lock.lock()
            nodes[nodeId]?.lastHeartbeat = payload.timestamp
            if let load = payload.load {
                nodeLoads[nodeId] = load
            }
            lock.unlock()

        case .messageReceived(let message):
            if case .commandResult(let resultPayload) = message {
                let result = resultPayload.toExecutionResult()
                lock.lock()
                let continuation = pendingResults.removeValue(forKey: resultPayload.commandId)
                lock.unlock()

                continuation?.resume(returning: result)
                eventContinuation?.yield(.commandCompleted(resultPayload.commandId, fromNode: nodeId, result))
            }

        case .disconnected(let reason):
            lock.lock()
            nodes[nodeId]?.status = .disconnected
            lock.unlock()
            eventContinuation?.yield(.nodeDisconnected(nodeId, reason: reason))

        case .error:
            lock.lock()
            nodes[nodeId]?.status = .unhealthy
            lock.unlock()
            eventContinuation?.yield(.healthCheckFailed(nodeId))
        }
    }

    private func performHealthCheck() {
        lock.lock()
        let connectedNodes = nodes.filter { $0.value.status == .connected }
        let now = Date().timeIntervalSince1970
        lock.unlock()

        for (nodeId, node) in connectedNodes {
            let elapsed = now - node.lastHeartbeat
            if elapsed > heartCheckInterval * 3 {
                lock.lock()
                nodes[nodeId]?.status = .unhealthy
                lock.unlock()
                eventContinuation?.yield(.healthCheckFailed(nodeId))
            }
        }
    }

    private var heartCheckInterval: TimeInterval { healthCheckInterval }
}
