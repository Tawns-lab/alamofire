//
//  MessageRouter.swift
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

/// Routes incoming messages to the appropriate handler based on message type and topic.
///
/// The `MessageRouter` sits between the LiveKit room connection and the chat/execution
/// engines. It decodes incoming data channel messages, determines whether they are
/// chat messages or execution commands/results, and dispatches them accordingly.
public final class MessageRouter: @unchecked Sendable {
    /// Handler closure for chat messages.
    public typealias ChatHandler = @Sendable (ChatMessage) -> Void

    /// Handler closure for execution-related data (commands or results).
    public typealias ExecutionDataHandler = @Sendable (Data, String) -> Void

    private var chatHandlers: [ChatHandler] = []
    private var executionHandlers: [ExecutionDataHandler] = []
    private var topicHandlers: [String: [ChatHandler]] = [:]
    private let lock = NSLock()
    private let configuration: LiveKitConfiguration

    /// Creates a new message router.
    ///
    /// - Parameter configuration: The LiveKit configuration (for topic names).
    public init(configuration: LiveKitConfiguration) {
        self.configuration = configuration
    }

    /// Registers a handler for all incoming chat messages.
    ///
    /// - Parameter handler: Closure invoked with each received chat message.
    public func onChatMessage(_ handler: @escaping ChatHandler) {
        lock.lock()
        chatHandlers.append(handler)
        lock.unlock()
    }

    /// Registers a handler for chat messages on a specific topic.
    ///
    /// - Parameters:
    ///   - topic: The topic to listen on.
    ///   - handler: Closure invoked with each received message on that topic.
    public func onChatMessage(topic: String, _ handler: @escaping ChatHandler) {
        lock.lock()
        topicHandlers[topic, default: []].append(handler)
        lock.unlock()
    }

    /// Registers a handler for execution-related data.
    ///
    /// - Parameter handler: Closure invoked with raw execution data and sender identity.
    public func onExecutionData(_ handler: @escaping ExecutionDataHandler) {
        lock.lock()
        executionHandlers.append(handler)
        lock.unlock()
    }

    /// Routes incoming data from a LiveKit room connection event.
    ///
    /// - Parameters:
    ///   - data: The raw data received.
    ///   - topic: The data channel topic.
    ///   - senderIdentity: The identity of the sender.
    public func route(data: Data, topic: String, senderIdentity: String) {
        if topic == configuration.executionTopic {
            routeExecutionData(data, senderIdentity: senderIdentity)
            return
        }

        // Attempt to decode as a chat message
        if let message = try? ChatMessage.decode(from: data) {
            routeChatMessage(message, topic: topic)
        } else if let text = String(data: data, encoding: .utf8) {
            // Wrap raw text as a simple chat message
            let message = ChatMessage(
                senderIdentity: senderIdentity,
                content: text,
                kind: .text,
                topic: topic
            )
            routeChatMessage(message, topic: topic)
        }
    }

    // MARK: - Private

    private func routeChatMessage(_ message: ChatMessage, topic: String) {
        lock.lock()
        let handlers = chatHandlers
        let topicSpecific = topicHandlers[topic] ?? []
        lock.unlock()

        for handler in handlers {
            handler(message)
        }
        for handler in topicSpecific {
            handler(message)
        }
    }

    private func routeExecutionData(_ data: Data, senderIdentity: String) {
        lock.lock()
        let handlers = executionHandlers
        lock.unlock()

        for handler in handlers {
            handler(data, senderIdentity)
        }
    }
}
