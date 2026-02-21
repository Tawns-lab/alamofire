//
//  CommandParser.swift
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

/// Parses raw chat message text into structured `Command` objects.
///
/// Commands follow the format: `/<name> [arguments...] [--option value...]`
///
/// Examples:
/// - `/run echo hello world`
/// - `/eval --lang swift print("hello")`
/// - `/status`
/// - `/help run`
public struct CommandParser: Sendable {
    /// The prefix that identifies a command message (e.g., "/").
    public let prefix: String

    /// Creates a new command parser.
    ///
    /// - Parameter prefix: The command prefix. Defaults to "/".
    public init(prefix: String = "/") {
        self.prefix = prefix
    }

    /// Attempts to parse a chat message into a command.
    ///
    /// - Parameters:
    ///   - message: The chat message to parse.
    ///   - roomId: The room where the message was sent.
    /// - Returns: A parsed `Command` if the message is a valid command, otherwise `nil`.
    public func parse(message: ChatMessage, roomId: String) -> Command? {
        parse(text: message.content, senderIdentity: message.senderIdentity, roomId: roomId)
    }

    /// Attempts to parse raw text into a command.
    ///
    /// - Parameters:
    ///   - text: The raw message text.
    ///   - senderIdentity: The identity of the sender.
    ///   - roomId: The room where the command was issued.
    /// - Returns: A parsed `Command` if the text is a valid command, otherwise `nil`.
    public func parse(text: String, senderIdentity: String, roomId: String) -> Command? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }

        let withoutPrefix = String(trimmed.dropFirst(prefix.count))
        let tokens = tokenize(withoutPrefix)
        guard let commandName = tokens.first else { return nil }

        var arguments: [String] = []
        var options: [String: String] = [:]
        var i = 1

        while i < tokens.count {
            let token = tokens[i]
            if token.hasPrefix("--") {
                let optionName = String(token.dropFirst(2))
                if i + 1 < tokens.count, !tokens[i + 1].hasPrefix("--") {
                    options[optionName] = tokens[i + 1]
                    i += 2
                } else {
                    options[optionName] = "true"
                    i += 1
                }
            } else if token.hasPrefix("-"), token.count == 2 {
                let flag = String(token.dropFirst(1))
                if i + 1 < tokens.count, !tokens[i + 1].hasPrefix("-") {
                    options[flag] = tokens[i + 1]
                    i += 2
                } else {
                    options[flag] = "true"
                    i += 1
                }
            } else {
                arguments.append(token)
                i += 1
            }
        }

        return Command(
            name: commandName.lowercased(),
            arguments: arguments,
            options: options,
            rawText: text,
            senderIdentity: senderIdentity,
            roomId: roomId
        )
    }

    /// Checks if the given text looks like a command.
    public func isCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
    }

    // MARK: - Private

    /// Tokenizes input respecting quoted strings.
    private func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""

        for char in input {
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    tokens.append(current)
                    current = ""
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                inQuote = true
                quoteChar = char
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
