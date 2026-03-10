//
//  StarScreamClient.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

import Foundation
import Starscream

let URL1 = URL(string: "wss://janus.conf.meetecho.com/ws")
let URL2 = URL(string: "wss://binda.live/janus")

enum SignalingConnectionState {
    case connected
    case disconnected
    case connecting
    case text(String)
    case data(Data)
    case error(Error?)
    case cancelled
}

protocol SignalingConnectionStateDelegate: AnyObject {
    func didReceive(didStateChange state: SignalingConnectionState)
}

protocol StarScreamConnection {
    func connect()
    func send(text: String)
    func disconnect()
}
final class StarScreamClient:StarScreamConnection {
    weak var delegate: SignalingConnectionStateDelegate?
    private var webSocket: WebSocket? = nil
    
    init(url: URL = URL1!) {
        var request = URLRequest(url: url)
        let protocols = ["janus-protocol"]
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(protocols.joined(separator: ","), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        webSocket = WebSocket(request: request)
        webSocket?.delegate = self
    }
    
    func connect() {
        delegate?.didReceive(didStateChange: .connecting)
        webSocket?.connect()
    }
    
    func send(text: String) {
        print("out", text)
        webSocket?.write(string: text)
    }
    
    func disconnect() {
        webSocket?.disconnect()
    }
}

extension StarScreamClient: WebSocketDelegate {
    func didReceive(event: WebSocketEvent, client: any WebSocketClient) {
        switch event {
        case .connected(let response):
            print("Connected: \(response)")
            delegate?.didReceive(didStateChange: .connected)
        case .disconnected(let reason, let code):
            print("Disconnected: \(reason), \(code)")
            delegate?.didReceive(didStateChange: .disconnected)
        case .text(let text):
            print("Received text: \(text)")
            delegate?.didReceive(didStateChange: .text(text))
        case .binary(let data):
            print("Received data: \(data)")
            delegate?.didReceive(didStateChange: .data(data))
        case .pong(_):
            print("Received pong")
        case .ping(_):
            print("Received ping")
        case .error(let error):
            print("Error: \(error?.localizedDescription ?? "Unknown error")")
            delegate?.didReceive(didStateChange: .error(error))
        case .cancelled:
            print("Cancelled")
            delegate?.didReceive(didStateChange: .cancelled)
        default :
            break
        }
    }
}
