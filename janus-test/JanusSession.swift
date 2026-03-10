//
//  JanusSession.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// JanusSession.swift
// Manages a single Janus session: creates session, attaches plugin handles,
// routes all incoming WebSocket messages, and dispatches transactions.

import Foundation
import WebRTC

protocol JanusSessionDelegate: AnyObject {
    func janusSession(_ session: JanusSession, didReceiveEvent event: [String: Any], forHandle handleId: UInt64)
    func janusSession(_ session: JanusSession, didReceiveJSEP jsep: [String: Any], forHandle handleId: UInt64)
    func janusSession(_ session: JanusSession, didError error: JanusError)
    func janusSessionDidConnect(_ session: JanusSession)
    func janusSessionDidDisconnect(_ session: JanusSession)
}

final class JanusSession: NSObject {

    // MARK: - Public
    weak var delegate: JanusSessionDelegate?
    private(set) var sessionId: UInt64 = 0
    private(set) var isConnected: Bool = false

    // MARK: - Private
    private let client: StarScreamClient
    private var transactions: [String: ([String: Any]) -> Void] = [:]
    private let transactionLock = NSLock()
    private var keepAliveTimer: Timer?

    // MARK: - Init
    init(url: URL) {
        client = StarScreamClient()
        super.init()
        client.delegate = self
    }

    // MARK: - Connect / Disconnect
    func connect() {
        client.connect()
    }

    func disconnect() {
        stopKeepAlive()
        client.disconnect()
        sessionId = 0
        isConnected = false
    }

    // MARK: - Session Lifecycle
    func createSession(completion: @escaping (Result<UInt64, JanusError>) -> Void) {
        let txId = makeTransactionId()
        let msg: [String: Any] = ["janus": "create", "transaction": txId]
        registerTransaction(id: txId) { [weak self] response in
            guard let self else { return }
            if let data = response["data"] as? [String: Any],
               let id = data["id"] as? UInt64 {
                self.sessionId = id
                self.startKeepAlive()
                completion(.success(id))
            } else {
                completion(.failure(.sessionCreationFailed))
            }
        }
        send(message: msg)
    }

    func attachPlugin(_ plugin: JanusPlugin, completion: @escaping (Result<UInt64, JanusError>) -> Void) {
        guard sessionId != 0 else { completion(.failure(.sessionCreationFailed)); return }
        let txId = makeTransactionId()
        let msg: [String: Any] = [
            "janus": "attach",
            "session_id": sessionId,
            "plugin": plugin.rawValue,
            "transaction": txId
        ]
        registerTransaction(id: txId) { response in
            if let data = response["data"] as? [String: Any],
               let handleId = data["id"] as? UInt64 {
                completion(.success(handleId))
            } else {
                completion(.failure(.pluginAttachFailed))
            }
        }
        send(message: msg)
    }

    func sendMessage(_ body: [String: Any],
                     handleId: UInt64,
                     jsep: [String: Any]? = nil,
                     completion: (([String: Any]) -> Void)? = nil) {
        let txId = makeTransactionId()
        var msg: [String: Any] = [
            "janus": "message",
            "session_id": sessionId,
            "handle_id": handleId,
            "transaction": txId,
            "body": body
        ]
        if let jsep { msg["jsep"] = jsep }
        if let completion { registerTransaction(id: txId, handler: completion) }
        send(message: msg)
    }

    func sendTrickle(candidate: RTCIceCandidate?, handleId: UInt64) {
        let txId = makeTransactionId()
        var candidateDict: [String: Any]
        if let candidate {
            candidateDict = [
                "sdpMid": candidate.sdpMid ?? "",
                "sdpMLineIndex": candidate.sdpMLineIndex,
                "candidate": candidate.sdp
            ]
        } else {
            // Null candidate = end of candidates
            candidateDict = ["completed": true]
        }
        let msg: [String: Any] = [
            "janus": "trickle",
            "session_id": sessionId,
            "handle_id": handleId,
            "transaction": txId,
            "candidate": candidateDict
        ]
        send(message: msg)
    }

    func detachHandle(_ handleId: UInt64) {
        let txId = makeTransactionId()
        let msg: [String: Any] = [
            "janus": "detach",
            "session_id": sessionId,
            "handle_id": handleId,
            "transaction": txId
        ]
        send(message: msg)
    }

    // MARK: - Private Helpers
    private func send(message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        client.send(text: text)
    }

    private func makeTransactionId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased().description
    }

    private func registerTransaction(id: String, handler: @escaping ([String: Any]) -> Void) {
        transactionLock.lock()
        transactions[id] = handler
        transactionLock.unlock()
    }

    private func resolveTransaction(id: String, response: [String: Any]) {
        transactionLock.lock()
        let handler = transactions.removeValue(forKey: id)
        transactionLock.unlock()
        handler?(response)
    }

    // MARK: - Keep-Alive
    private func startKeepAlive() {
        stopKeepAlive()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.sendKeepAlive()
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func sendKeepAlive() {
        guard sessionId != 0 else { return }
        let msg: [String: Any] = [
            "janus": "keepalive",
            "session_id": sessionId,
            "transaction": makeTransactionId()
        ]
        send(message: msg)
    }

    // MARK: - Message Routing
    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            delegate?.janusSession(self, didError: .messageParsingFailed)
            return
        }

        let janusType = json["janus"] as? String ?? ""
        let txId = json["transaction"] as? String ?? ""
        let handleId = json["sender"] as? UInt64 ?? 0

        switch janusType {
        case "success":
            resolveTransaction(id: txId, response: json)
        case "ack":
            // Message acknowledged; async event will follow
            break
        case "event":
            if !txId.isEmpty { resolveTransaction(id: txId, response: json) }
            delegate?.janusSession(self, didReceiveEvent: json, forHandle: handleId)
            if let jsep = json["jsep"] as? [String: Any] {
                delegate?.janusSession(self, didReceiveJSEP: jsep, forHandle: handleId)
            }
        case "webrtcup":
            print("[Janus] WebRTC up for handle \(handleId)")
        case "media":
            let type = json["type"] as? String ?? "unknown"
            let receiving = json["receiving"] as? Bool ?? false
            print("[Janus] Media (\(type)) receiving=\(receiving) handle=\(handleId)")
        case "slowlink":
            print("[Janus] Slowlink for handle \(handleId)")
        case "hangup":
            delegate?.janusSession(self, didError: .iceFailure)
        case "error":
            let errorMsg = (json["error"] as? [String: Any])?["reason"] as? String ?? "Unknown"
            resolveTransaction(id: txId, response: json)
            delegate?.janusSession(self, didError: .unknownError(errorMsg))
        case "timeout":
            delegate?.janusSession(self, didError: .unknownError("Session timed out"))
            disconnect()
        default:
            break
        }
    }
}

// MARK: - SignalingConnectionStateDelegate
extension JanusSession: SignalingConnectionStateDelegate {
    func didReceive(didStateChange state: SignalingConnectionState) {
        switch state {
        case .connected:
            isConnected = true
            delegate?.janusSessionDidConnect(self)
        case .disconnected:
            isConnected = false
            stopKeepAlive()
            delegate?.janusSessionDidDisconnect(self)
        case .text(let text):
            handleIncomingText(text)
        case .error(let error):
            delegate?.janusSession(self, didError: .unknownError(error?.localizedDescription ?? "Socket error"))
        case .cancelled:
            isConnected = false
            stopKeepAlive()
            delegate?.janusSessionDidDisconnect(self)
        default:
            break
        }
    }
}
