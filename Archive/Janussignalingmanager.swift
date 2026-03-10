//
//  Janussignalingmanager.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// JanusSignalingManager.swift
// Handles WebSocket connection and Janus protocol signaling

import Foundation
import Combine

// MARK: - Janus Message Types
enum JanusMessageType: String {
    case create, attach, message, trickle, keepalive
    case ack, success, error, event, hangup, detached
    case webrtcup, media, slowlink, timeout
}

// MARK: - Janus Transaction
struct JanusTransaction {
    let id: String
    let continuation: CheckedContinuation<[String: Any], Error>
}

// MARK: - Janus Error
enum JanusError: LocalizedError {
    case connectionFailed(String)
    case sessionCreationFailed
    case pluginAttachFailed
    case signalingError(String)
    case timeout
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .sessionCreationFailed: return "Failed to create Janus session"
        case .pluginAttachFailed: return "Failed to attach plugin"
        case .signalingError(let msg): return "Signaling error: \(msg)"
        case .timeout: return "Request timed out"
        case .invalidResponse: return "Invalid server response"
        }
    }
}

// MARK: - Janus Signaling Delegate
protocol JanusSignalingDelegate: AnyObject {
    func signalingManager(_ manager: JanusSignalingManager, didReceiveEvent event: [String: Any], handleId: Int64)
    func signalingManager(_ manager: JanusSignalingManager, didReceiveJsep jsep: [String: Any], handleId: Int64)
    func signalingManager(_ manager: JanusSignalingManager, handleDidHangup handleId: Int64)
    func signalingManager(_ manager: JanusSignalingManager, didDisconnectWithError error: Error?)
}

// MARK: - JanusSignalingManager
final class JanusSignalingManager: NSObject {

    // MARK: - Properties
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var serverURL: URL
    private(set) var sessionId: Int64 = 0
    private var pendingTransactions: [String: JanusTransaction] = [:]
    private var keepAliveTimer: Timer?
    private let transactionQueue = DispatchQueue(label: "com.janus.transaction", attributes: .concurrent)
    private let timeoutInterval: TimeInterval = 10.0

    weak var delegate: JanusSignalingDelegate?
    var isConnected: Bool = false

    // MARK: - Init
    init(serverURL: URL) {
        self.serverURL = serverURL
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - Connection
    func connect() async throws {
        print("-- connect --")
        var request = URLRequest(url: serverURL)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("janus-protocol", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            
        
        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.resume()
        isConnected = true
        startReceiving()
        sessionId = try await createSession()
        startKeepAlive()
    }

    func disconnect() {
        keepAliveTimer?.invalidate()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
    }

    // MARK: - Session Management
    private func createSession() async throws -> Int64 {
        let response = try await send(type: .create, handleId: nil, body: nil)
        guard
            let data = response["data"] as? [String: Any],
            let id = data["id"] as? Int64
        else { throw JanusError.sessionCreationFailed }
        return id
    }

    // MARK: - Plugin Attachment
    func attachPlugin(_ plugin: String) async throws -> Int64 {
        let body: [String: Any] = ["plugin": plugin, "opaque_id": UUID().uuidString]
        let response = try await send(type: .attach, handleId: nil, body: body)
        guard
            let data = response["data"] as? [String: Any],
            let handleId = data["id"] as? Int64
        else { throw JanusError.pluginAttachFailed }
        return handleId
    }

    // MARK: - Send Message with JSEP
    func sendMessage(handleId: Int64, body: [String: Any], jsep: [String: Any]? = nil) async throws -> [String: Any] {
        var payload: [String: Any] = ["body": body]
        if let jsep = jsep { payload["jsep"] = jsep }
        return try await send(type: .message, handleId: handleId, body: payload)
    }

    // MARK: - Trickle ICE
    func sendTrickle(handleId: Int64, candidate: [String: Any]?) async throws {
        let body: [String: Any] = candidate != nil ? ["candidate": candidate!] : ["completed": true]
        _ = try? await send(type: .trickle, handleId: handleId, body: body)
    }

    // MARK: - Core Send
    private func send(type: JanusMessageType, handleId: Int64?, body: [String: Any]?) async throws -> [String: Any] {
        let transactionId = UUID().uuidString
        var message: [String: Any] = [
            "janus": type.rawValue,
            "transaction": transactionId
        ]
        if sessionId != 0 { message["session_id"] = sessionId }
        if let hid = handleId { message["handle_id"] = hid }
        if let b = body { message.merge(b) { _, new in new } }

        return try await withCheckedThrowingContinuation { continuation in
            let transaction = JanusTransaction(id: transactionId, continuation: continuation)
            transactionQueue.async(flags: .barrier) {
                self.pendingTransactions[transactionId] = transaction
            }

            guard let data = try? JSONSerialization.data(withJSONObject: message) else {
                continuation.resume(throwing: JanusError.invalidResponse)
                return
            }

            self.webSocketTask?.send(.data(data)) { error in
                if let error = error {
                    self.transactionQueue.async(flags: .barrier) {
                        self.pendingTransactions.removeValue(forKey: transactionId)
                    }
                    continuation.resume(throwing: error)
                }
            }

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + self.timeoutInterval) {
                self.transactionQueue.async(flags: .barrier) {
                    if let tx = self.pendingTransactions.removeValue(forKey: transactionId) {
                        tx.continuation.resume(throwing: JanusError.timeout)
                    }
                }
            }
        }
    }

    // MARK: - Receive Loop
    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.startReceiving()
            case .failure(let error):
                self.isConnected = false
                self.delegate?.signalingManager(self, didDisconnectWithError: error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        var data: Data?
        switch message {
        case .data(let d): data = d
        case .string(let s): data = s.data(using: .utf8)
        @unknown default: return
        }

        guard
            let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let janusType = json["janus"] as? String
        else { return }

        let transaction = json["transaction"] as? String
        let handleId = json["sender"] as? Int64 ?? 0

        // Resolve pending transaction
        if let txId = transaction {
            transactionQueue.async(flags: .barrier) {
                if let tx = self.pendingTransactions.removeValue(forKey: txId) {
                    if janusType == "error" {
                        let msg = (json["error"] as? [String: Any])?["reason"] as? String ?? "Unknown error"
                        tx.continuation.resume(throwing: JanusError.signalingError(msg))
                    } else {
                        tx.continuation.resume(returning: json)
                    }
                    return
                }
            }
        }

        // Handle async events
        let type = JanusMessageType(rawValue: janusType)
        switch type {
        case .event:
            if let jsep = json["jsep"] as? [String: Any] {
                delegate?.signalingManager(self, didReceiveJsep: jsep, handleId: handleId)
            }
            if let pluginData = json["plugindata"] as? [String: Any],
               let eventData = pluginData["data"] as? [String: Any] {
                delegate?.signalingManager(self, didReceiveEvent: eventData, handleId: handleId)
            }
        case .hangup:
            delegate?.signalingManager(self, handleDidHangup: handleId)
        case .detached:
            delegate?.signalingManager(self, handleDidHangup: handleId)
        default:
            break
        }
    }

    // MARK: - Keep Alive
    private func startKeepAlive() {
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let self = self, self.sessionId != 0 else { return }
            Task { _ = try? await self.send(type: .keepalive, handleId: nil, body: nil) }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate
extension JanusSignalingManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        print("-- JanusSignalingManager: WebSocket connected --")
        isConnected = true
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("-- JanusSignalingManager: WebSocket disconnected --")
        isConnected = false
        delegate?.signalingManager(self, didDisconnectWithError: nil)
    }
}
