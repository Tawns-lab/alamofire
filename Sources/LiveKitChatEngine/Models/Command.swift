//
//  Command.swift
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

/// A parsed command extracted from a chat message, ready for execution.
public struct Command: Sendable, Identifiable, Equatable {
    /// Unique identifier for this command invocation.
    public let id: String

    /// The name of the command (e.g., "run", "eval", "status").
    public let name: String

    /// Positional arguments following the command name.
    public let arguments: [String]

    /// Named options/flags parsed from the command (e.g., --timeout 30).
    public let options: [String: String]

    /// The raw text of the original message.
    public let rawText: String

    /// Identity of the participant who issued the command.
    public let senderIdentity: String

    /// The room where the command was issued.
    public let roomId: String

    /// Timestamp when the command was created.
    public let timestamp: TimeInterval

    /// Creates a new command.
    public init(
        id: String = UUID().uuidString,
        name: String,
        arguments: [String] = [],
        options: [String: String] = [:],
        rawText: String,
        senderIdentity: String,
        roomId: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.options = options
        self.rawText = rawText
        self.senderIdentity = senderIdentity
        self.roomId = roomId
        self.timestamp = timestamp
    }
}
