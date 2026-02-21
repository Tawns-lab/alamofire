//
//  ExecutionResult.swift
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

/// The result of executing a command through the execution engine.
public struct ExecutionResult: Sendable, Identifiable {
    /// Unique identifier for this result.
    public let id: String

    /// The ID of the command that produced this result.
    public let commandId: String

    /// The outcome status.
    public let status: Status

    /// The textual output of the execution.
    public let output: String

    /// Optional structured data returned by the execution.
    public let data: [String: String]?

    /// Duration of the execution in seconds.
    public let duration: TimeInterval

    /// Timestamp when execution completed.
    public let completedAt: TimeInterval

    /// Creates a new execution result.
    public init(
        id: String = UUID().uuidString,
        commandId: String,
        status: Status,
        output: String,
        data: [String: String]? = nil,
        duration: TimeInterval,
        completedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.commandId = commandId
        self.status = status
        self.output = output
        self.data = data
        self.duration = duration
        self.completedAt = completedAt
    }
}

// MARK: - Status

extension ExecutionResult {
    /// Outcome status of a command execution.
    public enum Status: String, Sendable {
        /// The command completed successfully.
        case success
        /// The command failed with an error.
        case failure
        /// The command was cancelled before completion.
        case cancelled
        /// The command timed out.
        case timedOut
    }
}

// MARK: - Convenience

extension ExecutionResult {
    /// Whether this result represents a successful execution.
    public var isSuccess: Bool { status == .success }

    /// Convert this result into a chat message for broadcasting.
    public func toChatMessage(senderIdentity: String, topic: String? = nil) -> ChatMessage {
        let prefix: String
        switch status {
        case .success: prefix = "[OK]"
        case .failure: prefix = "[ERROR]"
        case .cancelled: prefix = "[CANCELLED]"
        case .timedOut: prefix = "[TIMEOUT]"
        }

        return ChatMessage(
            senderIdentity: senderIdentity,
            content: "\(prefix) \(output)",
            kind: .executionResult,
            metadata: data,
            topic: topic
        )
    }
}
