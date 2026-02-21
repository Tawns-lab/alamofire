//
//  ExecutionContext.swift
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

/// Provides shared state and environment for command execution.
///
/// The `ExecutionContext` holds variables that persist across command invocations
/// within a session. Command handlers can read and write variables to share
/// state, store intermediate results, or configure behavior.
public final class ExecutionContext: @unchecked Sendable {
    private var variables: [String: String] = [:]
    private let lock = NSLock()

    /// The identity of the participant who owns this context.
    public let ownerIdentity: String

    /// The room this context is associated with.
    public let roomId: String

    /// When this context was created.
    public let createdAt: Date

    /// Creates a new execution context.
    ///
    /// - Parameters:
    ///   - ownerIdentity: The participant who owns this context.
    ///   - roomId: The room associated with this context.
    ///   - initialVariables: Initial variable bindings.
    public init(
        ownerIdentity: String,
        roomId: String,
        initialVariables: [String: String] = [:]
    ) {
        self.ownerIdentity = ownerIdentity
        self.roomId = roomId
        self.createdAt = Date()
        self.variables = initialVariables
    }

    /// Gets the value of a variable.
    ///
    /// - Parameter key: The variable name.
    /// - Returns: The variable value, or `nil` if not set.
    public func getVariable(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return variables[key]
    }

    /// Sets a variable value.
    ///
    /// - Parameters:
    ///   - key: The variable name.
    ///   - value: The value to set.
    public func setVariable(_ key: String, value: String) {
        lock.lock()
        variables[key] = value
        lock.unlock()
    }

    /// Removes a variable.
    ///
    /// - Parameter key: The variable name to remove.
    /// - Returns: The previous value, if any.
    @discardableResult
    public func removeVariable(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return variables.removeValue(forKey: key)
    }

    /// Returns a snapshot of all current variables.
    public func allVariables() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return variables
    }

    /// Clears all variables.
    public func clearVariables() {
        lock.lock()
        variables.removeAll()
        lock.unlock()
    }

    /// Merges additional variables into the context. Existing keys are overwritten.
    public func merge(_ newVariables: [String: String]) {
        lock.lock()
        variables.merge(newVariables) { _, new in new }
        lock.unlock()
    }
}
