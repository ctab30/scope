import Foundation
import SwiftUI

struct NetworkRequestEntry: Identifiable {
    let id: String  // requestId from JS
    let method: String
    let url: String
    let type: RequestType
    let startTime: Date
    var status: Int?
    var statusText: String?
    var duration: TimeInterval?
    var responseSize: Int?
    var requestHeaders: [String: String]?
    var responseHeaders: [String: String]?
    var requestBody: String?
    var responseBody: String?
    var isComplete: Bool = false
    var isError: Bool = false

    enum RequestType: String {
        case fetch = "fetch"
        case xhr = "xhr"
        case websocket = "websocket"

        var icon: String {
            switch self {
            case .fetch: return "arrow.up.arrow.down"
            case .xhr: return "network"
            case .websocket: return "bolt.horizontal"
            }
        }
    }

    var webSocketMessages: [WebSocketMessage]?

    var statusColor: Color {
        guard let status else { return isError ? .red : .secondary }
        switch status {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .secondary
        }
    }

    var statusLabel: String {
        guard let status else { return isError ? "ERR" : "..." }
        if let text = statusText, !text.isEmpty {
            return "\(status) \(text)"
        }
        return "\(status)"
    }

    var formattedDuration: String {
        guard let duration else { return "..." }
        if duration < 1 {
            return "\(Int(duration * 1000))ms"
        }
        return String(format: "%.1fs", duration)
    }

    var formattedSize: String {
        guard let size = responseSize else { return "" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return "\(size / 1024) KB" }
        return String(format: "%.1f MB", Double(size) / (1024 * 1024))
    }

    var shortURL: String {
        guard let urlObj = URL(string: url) else { return url }
        let path = urlObj.path
        if path.isEmpty || path == "/" {
            return urlObj.host ?? url
        }
        return path
    }

    var domain: String {
        URL(string: url)?.host ?? ""
    }

    enum StatusClass: String {
        case success, redirect, clientError, serverError, unknown
    }

    var statusClass: StatusClass {
        guard let status else { return .unknown }
        switch status {
        case 200..<300: return .success
        case 300..<400: return .redirect
        case 400..<500: return .clientError
        case 500..<600: return .serverError
        default: return .unknown
        }
    }

    var waterfallColor: Color {
        switch statusClass {
        case .success: return .green
        case .redirect: return .blue
        case .clientError: return .orange
        case .serverError: return .red
        case .unknown: return isError ? .red : .secondary
        }
    }
}

struct WebSocketMessage: Identifiable {
    let id = UUID()
    let timestamp: Date
    let direction: Direction
    let data: String

    enum Direction: String {
        case sent, received
    }
}
