import Foundation
import UIKit

struct ActionExecutor {
    private static let tag = "ActionExecutor"

    /// Executes the action, then calls `clear` if the action has `clear: true` set, so the caller
    /// can dismiss the notification it came from (see https://docs.ntfy.sh/publish/#action-buttons).
    static func execute(_ action: Action, clear: (() -> Void)? = nil) {
        Log.d(tag, "Executing user action", action)
        switch action.action {
        case "view":
            if let url = URL(string: action.url ?? "") {
                open(url: url)
            } else {
                Log.w(tag, "Unable to parse action URL", action)
            }
        case "http":
            http(action)
        case "copy":
            copy(action)
        default:
            Log.w(tag, "Action \(action.action) not supported", action)
        }
        if action.clear == true {
            clear?()
        }
    }
    
    private static func http(_ action: Action) {
        guard let actionUrl = action.url, let url = URL(string: actionUrl) else {
            Log.w(tag, "Unable to execute HTTP action, no or invalid URL", action)
            return
        }
        let method = action.method ?? "POST" // POST is the default!!
        let body = action.body ?? ""

        Log.d(tag, "Performing HTTP \(method) \(url)")
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        action.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !["GET", "HEAD"].contains(method) {
            request.httpBody = body.data(using: .utf8)
        }
        URLSession.shared.dataTask(with: request) { (data, response, error) in
            guard error == nil else {
                Log.e(self.tag, "Error performing HTTP \(method)", error!)
                return
            }
            Log.d(self.tag, "HTTP \(method) succeeded", response)
        }.resume()
    }
    
    private static func copy(_ action: Action) {
        guard let value = action.value else {
            Log.w(tag, "Unable to execute copy action, no value", action)
            return
        }
        UIPasteboard.general.string = value
    }

    private static func open(url: URL) {
        Log.d(tag, "Opening URL \(url)")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
