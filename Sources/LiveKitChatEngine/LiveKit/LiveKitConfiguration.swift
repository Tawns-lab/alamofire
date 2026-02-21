//
//  LiveKitConfiguration.swift
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

/// Configuration for connecting to a LiveKit server instance.
public struct LiveKitConfiguration: Sendable {
    /// The base URL of the LiveKit server (e.g., "wss://myserver.livekit.cloud").
    public let serverURL: URL

    /// The LiveKit API key for authentication.
    public let apiKey: String

    /// The LiveKit API secret for signing tokens.
    public let apiSecret: String

    /// Timeout for API requests in seconds.
    public let requestTimeout: TimeInterval

    /// Whether to automatically reconnect on connection loss.
    public let autoReconnect: Bool

    /// Maximum number of reconnection attempts.
    public let maxReconnectAttempts: Int

    /// Interval between reconnection attempts in seconds.
    public let reconnectInterval: TimeInterval

    /// The data channel topic used for chat messages.
    public let chatTopic: String

    /// The data channel topic used for execution commands/results.
    public let executionTopic: String

    /// Creates a new LiveKit configuration.
    ///
    /// - Parameters:
    ///   - serverURL: The LiveKit server WebSocket URL.
    ///   - apiKey: API key for authentication.
    ///   - apiSecret: API secret for signing tokens.
    ///   - requestTimeout: HTTP request timeout in seconds. Defaults to 30.
    ///   - autoReconnect: Whether to reconnect automatically. Defaults to true.
    ///   - maxReconnectAttempts: Max reconnect attempts. Defaults to 5.
    ///   - reconnectInterval: Seconds between reconnect attempts. Defaults to 2.
    ///   - chatTopic: Data channel topic for chat. Defaults to "lk-chat-topic".
    ///   - executionTopic: Data channel topic for execution. Defaults to "lk-exec-topic".
    public init(
        serverURL: URL,
        apiKey: String,
        apiSecret: String,
        requestTimeout: TimeInterval = 30,
        autoReconnect: Bool = true,
        maxReconnectAttempts: Int = 5,
        reconnectInterval: TimeInterval = 2,
        chatTopic: String = "lk-chat-topic",
        executionTopic: String = "lk-exec-topic"
    ) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.requestTimeout = requestTimeout
        self.autoReconnect = autoReconnect
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectInterval = reconnectInterval
        self.chatTopic = chatTopic
        self.executionTopic = executionTopic
    }

    /// The HTTP base URL derived from the WebSocket server URL.
    public var httpBaseURL: URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.scheme = serverURL.scheme == "wss" ? "https" : "http"
        return components.url!
    }
}
