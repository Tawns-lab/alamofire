//
//  RemoteNode.swift
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

/// Represents a remote device that can participate in the execution engine
/// as a networked node, receiving and executing commands dispatched from
/// the central engine.
public struct RemoteNode: Sendable, Identifiable, Equatable, Codable {
    /// Unique identifier for this node.
    public let id: String

    /// Human-readable label for the node (e.g., "Pixel-7", "iPad-Pro").
    public let name: String

    /// The node's network endpoint.
    public let endpoint: Endpoint

    /// Capabilities this node advertises.
    public var capabilities: Set<Capability>

    /// Current connection/health status.
    public var status: Status

    /// Arbitrary metadata about the node (OS version, device model, etc.).
    public var metadata: [String: String]

    /// When this node was first registered.
    public let registeredAt: TimeInterval

    /// Last time a heartbeat was received from this node.
    public var lastHeartbeat: TimeInterval

    public init(
        id: String = UUID().uuidString,
        name: String,
        endpoint: Endpoint,
        capabilities: Set<Capability> = [.executeCommands],
        status: Status = .disconnected,
        metadata: [String: String] = [:],
        registeredAt: TimeInterval = Date().timeIntervalSince1970,
        lastHeartbeat: TimeInterval = 0
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.status = status
        self.metadata = metadata
        self.registeredAt = registeredAt
        self.lastHeartbeat = lastHeartbeat
    }
}

// MARK: - Endpoint

extension RemoteNode {
    /// Network endpoint for reaching a remote node.
    public struct Endpoint: Sendable, Equatable, Codable {
        /// The host address (IP or hostname).
        public let host: String

        /// The port number.
        public let port: Int

        /// The protocol scheme.
        public let scheme: Scheme

        /// The path prefix for the node's API.
        public let path: String

        public init(host: String, port: Int = 7880, scheme: Scheme = .ws, path: String = "/node") {
            self.host = host
            self.port = port
            self.scheme = scheme
            self.path = path
        }

        /// Constructs the full WebSocket URL for this endpoint.
        public var webSocketURL: URL {
            var components = URLComponents()
            components.scheme = scheme.rawValue
            components.host = host
            components.port = port
            components.path = path
            return components.url!
        }

        /// Constructs the full HTTP URL for this endpoint.
        public var httpURL: URL {
            var components = URLComponents()
            components.scheme = scheme == .wss ? "https" : "http"
            components.host = host
            components.port = port
            components.path = path
            return components.url!
        }

        public enum Scheme: String, Sendable, Codable {
            case ws
            case wss
        }
    }
}

// MARK: - Capability

extension RemoteNode {
    /// A capability that a remote node can advertise.
    public enum Capability: String, Sendable, Codable {
        /// Can execute commands dispatched from the engine.
        case executeCommands
        /// Can relay messages to other nodes.
        case relay
        /// Can provide persistent storage.
        case storage
        /// Can stream sensor/device data.
        case sensorData
        /// Can run sandboxed code evaluation.
        case codeEval
    }
}

// MARK: - Status

extension RemoteNode {
    /// The connection and health status of a remote node.
    public enum Status: String, Sendable, Codable, Equatable {
        /// Not connected.
        case disconnected
        /// Connection in progress.
        case connecting
        /// Connected and healthy.
        case connected
        /// Connected but not responding to heartbeats.
        case unhealthy
        /// Node has been explicitly suspended from receiving commands.
        case suspended
    }

    /// Whether this node is available to receive commands.
    public var isAvailable: Bool {
        status == .connected
    }
}

// MARK: - Wire Protocol

extension RemoteNode {
    /// Messages exchanged between the engine and remote nodes over WebSocket.
    public enum NodeMessage: Codable, Sendable {
        case handshake(HandshakePayload)
        case heartbeat(HeartbeatPayload)
        case commandDispatch(CommandDispatchPayload)
        case commandResult(CommandResultPayload)
        case nodeStatus(NodeStatusPayload)

        public struct HandshakePayload: Codable, Sendable {
            public let nodeId: String
            public let nodeName: String
            public let capabilities: Set<Capability>
            public let metadata: [String: String]
            public let protocolVersion: Int

            public init(nodeId: String, nodeName: String, capabilities: Set<Capability>, metadata: [String: String] = [:], protocolVersion: Int = 1) {
                self.nodeId = nodeId
                self.nodeName = nodeName
                self.capabilities = capabilities
                self.metadata = metadata
                self.protocolVersion = protocolVersion
            }
        }

        public struct HeartbeatPayload: Codable, Sendable {
            public let nodeId: String
            public let timestamp: TimeInterval
            public let load: Double?

            public init(nodeId: String, timestamp: TimeInterval = Date().timeIntervalSince1970, load: Double? = nil) {
                self.nodeId = nodeId
                self.timestamp = timestamp
                self.load = load
            }
        }

        public struct CommandDispatchPayload: Codable, Sendable {
            public let commandId: String
            public let commandName: String
            public let arguments: [String]
            public let options: [String: String]
            public let rawText: String
            public let senderIdentity: String
            public let roomId: String
            public let timeout: TimeInterval

            public init(command: Command, timeout: TimeInterval = 30) {
                self.commandId = command.id
                self.commandName = command.name
                self.arguments = command.arguments
                self.options = command.options
                self.rawText = command.rawText
                self.senderIdentity = command.senderIdentity
                self.roomId = command.roomId
                self.timeout = timeout
            }
        }

        public struct CommandResultPayload: Codable, Sendable {
            public let commandId: String
            public let status: String
            public let output: String
            public let data: [String: String]?
            public let duration: TimeInterval

            public init(result: ExecutionResult) {
                self.commandId = result.commandId
                self.status = result.status.rawValue
                self.output = result.output
                self.data = result.data
                self.duration = result.duration
            }

            public func toExecutionResult() -> ExecutionResult {
                ExecutionResult(
                    commandId: commandId,
                    status: ExecutionResult.Status(rawValue: status) ?? .failure,
                    output: output,
                    data: data,
                    duration: duration
                )
            }
        }

        public struct NodeStatusPayload: Codable, Sendable {
            public let nodeId: String
            public let status: Status
            public let message: String?

            public init(nodeId: String, status: Status, message: String? = nil) {
                self.nodeId = nodeId
                self.status = status
                self.message = message
            }
        }

        // MARK: - Coding

        private enum CodingKeys: String, CodingKey {
            case type, payload
        }

        private enum MessageType: String, Codable {
            case handshake, heartbeat, commandDispatch, commandResult, nodeStatus
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(MessageType.self, forKey: .type)
            switch type {
            case .handshake:
                self = .handshake(try container.decode(HandshakePayload.self, forKey: .payload))
            case .heartbeat:
                self = .heartbeat(try container.decode(HeartbeatPayload.self, forKey: .payload))
            case .commandDispatch:
                self = .commandDispatch(try container.decode(CommandDispatchPayload.self, forKey: .payload))
            case .commandResult:
                self = .commandResult(try container.decode(CommandResultPayload.self, forKey: .payload))
            case .nodeStatus:
                self = .nodeStatus(try container.decode(NodeStatusPayload.self, forKey: .payload))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .handshake(let payload):
                try container.encode(MessageType.handshake, forKey: .type)
                try container.encode(payload, forKey: .payload)
            case .heartbeat(let payload):
                try container.encode(MessageType.heartbeat, forKey: .type)
                try container.encode(payload, forKey: .payload)
            case .commandDispatch(let payload):
                try container.encode(MessageType.commandDispatch, forKey: .type)
                try container.encode(payload, forKey: .payload)
            case .commandResult(let payload):
                try container.encode(MessageType.commandResult, forKey: .type)
                try container.encode(payload, forKey: .payload)
            case .nodeStatus(let payload):
                try container.encode(MessageType.nodeStatus, forKey: .type)
                try container.encode(payload, forKey: .payload)
            }
        }
    }
}
