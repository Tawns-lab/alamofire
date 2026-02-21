//
//  LiveKitService.swift
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

/// HTTP client for the LiveKit Server REST API.
///
/// Uses Alamofire to communicate with the LiveKit server for room management
/// operations (create, list, delete rooms; manage participants).
public final class LiveKitService: @unchecked Sendable {
    private let session: Session
    private let configuration: LiveKitConfiguration
    private let tokenProvider: LiveKitTokenProvider

    /// Creates a new LiveKit service client.
    ///
    /// - Parameters:
    ///   - configuration: The LiveKit server configuration.
    ///   - session: An Alamofire `Session` to use for HTTP requests. Defaults to `.default`.
    public init(configuration: LiveKitConfiguration, session: Session = .default) {
        self.configuration = configuration
        self.tokenProvider = LiveKitTokenProvider(
            apiKey: configuration.apiKey,
            apiSecret: configuration.apiSecret
        )
        self.session = session
    }

    // MARK: - Room Management

    /// Creates a new room on the LiveKit server.
    ///
    /// - Parameters:
    ///   - name: The room name (must be unique).
    ///   - maxParticipants: Maximum number of participants (0 = unlimited).
    ///   - metadata: Optional room metadata string.
    /// - Returns: The created `ChatRoom`.
    public func createRoom(
        name: String,
        maxParticipants: Int = 0,
        metadata: String = ""
    ) async throws -> ChatRoom {
        let url = configuration.httpBaseURL.appendingPathComponent("/twirp/livekit.RoomService/CreateRoom")
        let body: [String: Any] = [
            "name": name,
            "max_participants": maxParticipants,
            "metadata": metadata
        ]

        let response = try await performRequest(url: url, body: body)
        return ChatRoom(
            id: response["sid"] as? String ?? name,
            name: response["name"] as? String ?? name,
            maxParticipants: response["max_participants"] as? Int ?? maxParticipants
        )
    }

    /// Lists all active rooms on the LiveKit server.
    ///
    /// - Parameter names: Optional list of room names to filter by.
    /// - Returns: An array of `ChatRoom` descriptors.
    public func listRooms(names: [String]? = nil) async throws -> [ChatRoom] {
        let url = configuration.httpBaseURL.appendingPathComponent("/twirp/livekit.RoomService/ListRooms")
        var body: [String: Any] = [:]
        if let names {
            body["names"] = names
        }

        let response = try await performRequest(url: url, body: body)
        guard let rooms = response["rooms"] as? [[String: Any]] else {
            return []
        }

        return rooms.map { room in
            ChatRoom(
                id: room["sid"] as? String ?? "",
                name: room["name"] as? String ?? "",
                maxParticipants: room["max_participants"] as? Int ?? 0,
                createdAt: room["creation_time"] as? TimeInterval ?? Date().timeIntervalSince1970
            )
        }
    }

    /// Deletes a room from the LiveKit server.
    ///
    /// - Parameter room: The name of the room to delete.
    public func deleteRoom(_ room: String) async throws {
        let url = configuration.httpBaseURL.appendingPathComponent("/twirp/livekit.RoomService/DeleteRoom")
        _ = try await performRequest(url: url, body: ["room": room])
    }

    // MARK: - Participant Management

    /// Lists participants in a room.
    ///
    /// - Parameter room: The room name.
    /// - Returns: An array of `Participant` descriptors.
    public func listParticipants(room: String) async throws -> [Participant] {
        let url = configuration.httpBaseURL.appendingPathComponent("/twirp/livekit.RoomService/ListParticipants")
        let response = try await performRequest(url: url, body: ["room": room])

        guard let participants = response["participants"] as? [[String: Any]] else {
            return []
        }

        return participants.map { p in
            Participant(
                id: p["identity"] as? String ?? "",
                name: p["name"] as? String ?? "",
                joinedAt: p["joined_at"] as? TimeInterval ?? 0
            )
        }
    }

    /// Removes a participant from a room.
    ///
    /// - Parameters:
    ///   - identity: The participant identity to remove.
    ///   - room: The room name.
    public func removeParticipant(identity: String, room: String) async throws {
        let url = configuration.httpBaseURL.appendingPathComponent("/twirp/livekit.RoomService/RemoveParticipant")
        _ = try await performRequest(url: url, body: ["room": room, "identity": identity])
    }

    /// Sends data to participants in a room via the LiveKit server API.
    ///
    /// - Parameters:
    ///   - data: The data to send (will be base64 encoded).
    ///   - room: The room name.
    ///   - topic: The data channel topic.
    ///   - destinationIdentities: Specific participant identities to target (empty = broadcast).
    public func sendData(
        _ data: Data,
        room: String,
        topic: String,
        destinationIdentities: [String] = []
    ) async throws {
        let url = configuration.httpBaseURL.appendingPathComponent("/twirp/livekit.RoomService/SendData")
        var body: [String: Any] = [
            "room": room,
            "data": data.base64EncodedString(),
            "topic": topic,
            "kind": 0 // RELIABLE
        ]
        if !destinationIdentities.isEmpty {
            body["destination_identities"] = destinationIdentities
        }
        _ = try await performRequest(url: url, body: body)
    }

    // MARK: - Token Generation

    /// Generates an access token for a participant to join a room.
    ///
    /// - Parameters:
    ///   - identity: The participant identity.
    ///   - name: The display name.
    ///   - room: The room to grant access to.
    ///   - canPublish: Whether the participant can publish tracks.
    ///   - canSubscribe: Whether the participant can subscribe to tracks.
    ///   - canPublishData: Whether the participant can publish data messages.
    /// - Returns: A signed JWT access token string.
    public func generateAccessToken(
        identity: String,
        name: String,
        room: String,
        canPublish: Bool = true,
        canSubscribe: Bool = true,
        canPublishData: Bool = true
    ) -> String {
        tokenProvider.generateToken(
            identity: identity,
            name: name,
            grant: LiveKitTokenProvider.RoomGrant(
                room: room,
                canPublish: canPublish,
                canSubscribe: canSubscribe,
                canPublishData: canPublishData
            )
        )
    }

    // MARK: - Private

    private func performRequest(url: URL, body: [String: Any]) async throws -> [String: Any] {
        let token = tokenProvider.generateToken(
            identity: "server",
            name: "Server",
            grant: LiveKitTokenProvider.RoomGrant(room: "", canPublish: true, canSubscribe: true, canPublishData: true)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = configuration.requestTimeout

        let dataResponse = await session.request(request)
            .validate()
            .serializingData()
            .response

        if let error = dataResponse.error {
            throw LiveKitError.requestFailed(underlying: error)
        }

        guard let data = dataResponse.data else {
            return [:]
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        return json
    }
}

// MARK: - Errors

/// Errors that can occur during LiveKit operations.
public enum LiveKitError: Error, Sendable {
    /// An HTTP request to the LiveKit server failed.
    case requestFailed(underlying: any Error)
    /// Failed to connect to a LiveKit room.
    case connectionFailed(reason: String)
    /// The operation requires permissions the participant does not have.
    case permissionDenied(action: String)
    /// The specified room was not found.
    case roomNotFound(name: String)
    /// The specified participant was not found.
    case participantNotFound(identity: String)
    /// Token generation or validation failed.
    case tokenError(reason: String)
    /// A data channel message could not be encoded or decoded.
    case messageEncodingFailed(reason: String)
    /// The engine is not in a valid state for this operation.
    case invalidState(reason: String)
}

extension LiveKitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .requestFailed(let underlying):
            return "LiveKit request failed: \(underlying.localizedDescription)"
        case .connectionFailed(let reason):
            return "LiveKit connection failed: \(reason)"
        case .permissionDenied(let action):
            return "Permission denied for action: \(action)"
        case .roomNotFound(let name):
            return "Room not found: \(name)"
        case .participantNotFound(let identity):
            return "Participant not found: \(identity)"
        case .tokenError(let reason):
            return "Token error: \(reason)"
        case .messageEncodingFailed(let reason):
            return "Message encoding failed: \(reason)"
        case .invalidState(let reason):
            return "Invalid engine state: \(reason)"
        }
    }
}
