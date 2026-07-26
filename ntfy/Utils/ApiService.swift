import Foundation

class ApiService {
    static let shared = ApiService()
    static let userAgent = "ntfy/\(Config.version) (build \(Config.build); iOS \(Config.osVersion))"
    
    private let tag = "ApiService"
    
    func poll(subscription: Subscription, user: BasicUser?) async throws -> [Message] {
        guard let url = URL(string: subscription.urlString()) else {
            throw URLError(.badURL)
        }
        let since = subscription.lastNotificationId ?? "all"
        let urlString = "\(url)/json?poll=1&since=\(since)"

        Log.d(tag, "Polling from \(urlString) with user \(user != nil ? "<redacted>" : "anonymous")")
        return try await fetchJsonData(urlString: urlString, user: user)
    }

    func poll(baseUrl: String, topic: String, messageId: String, user: BasicUser?) async throws -> Message {
        guard let url = URL(string: "\(topicUrl(baseUrl: baseUrl, topic: topic))/json?poll=1&id=\(messageId)") else {
            throw URLError(.badURL)
        }
        Log.d(tag, "Polling single message from \(url) with user \(user != nil ? "<redacted>" : "anonymous")")

        let request = newRequest(url: url, user: user)
        let (data, response) = try await newSession(timeout: 30).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Message.self, from: data)
    }

    func publish(
        subscription: Subscription,
        user: BasicUser?,
        message: String,
        title: String,
        priority: Int = 3,
        tags: [String] = []
    ) async throws {
        guard let url = URL(string: subscription.urlString()) else {
            throw URLError(.badURL)
        }
        var request = newRequest(url: url, user: user)

        Log.d(tag, "Publishing to \(url)")

        request.httpMethod = "POST"
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(String(priority), forHTTPHeaderField: "Priority")
        request.setValue(tags.joined(separator: ","), forHTTPHeaderField: "Tags")
        request.httpBody = message.data(using: String.Encoding.utf8)
        do {
            let (_, response) = try await newSession(timeout: 10).data(for: request)
            Log.d(tag, "Publishing message succeeded", response)
        } catch {
            Log.e(tag, "Error publishing message", error)
            throw error
        }
    }

    func checkAuth(baseUrl: String, topic: String, user: BasicUser?) async -> AuthResult {
        guard let url = URL(string: topicAuthUrl(baseUrl: baseUrl, topic: topic)) else {
            return .Error("Invalid URL")
        }
        let request = newRequest(url: url, user: user)
        Log.d(tag, "Checking auth for \(url) with user \(user != nil ? "<redacted>" : "anonymous")")
        do {
            let (data, response) = try await newSession(timeout: 10).data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .Error("Unexpected response from server")
            }
            if httpResponse.statusCode != 200 {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    return .Unauthorized
                } else {
                    return .Error("Unexpected response from server: \(httpResponse.statusCode)")
                }
            }
            do {
                let result = try JSONDecoder().decode(AuthCheckResponse.self, from: data)
                Log.d(tag, "Auth result: \(result)")
                if result.success == true {
                    return .Success
                } else {
                    return .Error("Unexpected response from server")
                }
            } catch {
                Log.e(tag, "Error handling auth response: \(error)")
                return .Error("Unexpected response from server. Is this a ntfy server?")
            }
        } catch {
            Log.e(tag, "Error checking auth: \(error)")
            return .Error(error.localizedDescription)
        }
    }

    private func fetchJsonData<T: Decodable>(urlString: String, user: BasicUser?) async throws -> [T] {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let request = newRequest(url: url, user: user)
        do {
            let (data, response) = try await newSession(timeout: 30).data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            var notifications: [T] = []
            for jsonLine in lines {
                guard let jsonData = jsonLine.data(using: .utf8) else {
                    throw URLError(.cannotDecodeContentData)
                }
                notifications.append(try JSONDecoder().decode(T.self, from: jsonData))
            }
            return notifications
        } catch {
            Log.e(tag, "Error fetching data", error)
            throw error
        }
    }
    
    private func newRequest(url: URL, user: BasicUser?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        if let user = user {
            request.setValue(user.toHeader(), forHTTPHeaderField: "Authorization")
        }
        return request
    }
    
    private func newSession(timeout: TimeInterval) -> URLSession {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        return URLSession(configuration: sessionConfig)
    }
}

struct BasicUser {
    let username: String
    let password: String
    
    func toHeader() -> String {
        return "Basic " + String(format: "%@:%@", username, password).data(using: String.Encoding.utf8)!.base64EncodedString()
    }
}

enum AuthResult {
    case Success
    case Unauthorized
    case Error(String)
}

struct AuthCheckResponse: Codable {
    let success: Bool?
    let code: Int?
    let http: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, code, http, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success)
        self.code = try container.decodeIfPresent(Int.self, forKey: .code)
        self.http = try container.decodeIfPresent(Int.self, forKey: .http)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}
