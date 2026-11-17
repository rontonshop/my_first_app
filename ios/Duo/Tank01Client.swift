import Foundation
import Security

enum FeedJSON: Decodable, Equatable {
    case object([String: FeedJSON]), array([FeedJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([FeedJSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: FeedJSON].self)) }
    }
    subscript(_ key: String) -> FeedJSON? {
        if case .object(let map) = self { return map[key] }
        return nil
    }
    var text: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.formatted(.number.grouping(.never))
        case .bool(let value): return String(value)
        default: return nil
        }
    }
    var pretty: String {
        switch self {
        case .object(let map):
            return map.keys.sorted().map { key in key + ": " + (map[key]?.pretty ?? "") }.joined(separator: "\n")
        case .array(let values): return values.map(\.pretty).joined(separator: "\n\n")
        case .null: return "—"
        default: return text ?? ""
        }
    }
    var records: [(String, FeedJSON)] {
        switch self {
        case .array(let values): return values.enumerated().map { (String($0.offset), $0.element) }
        case .object(let map):
            return map.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, map[$0]!) }
        default: return []
        }
    }
}

struct TankGame: Identifiable {
    let id: String
    let label: String
}

struct FeedSnapshot {
    let body: FeedJSON
    let raw: String
    var plays: [(String, FeedJSON)] {
        guard let value = body["playByPlay"] else { return [] }
        return value.records
    }
    var playerStats: [(String, FeedJSON)] { body["playerStats"]?.records ?? [] }
    var status: String { body["gameStatus"]?.text ?? "Status unavailable" }
}

enum TankKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.rontonshop.myfirstapp.tank01",
        kSecAttrAccount as String: "rapidapi"
    ]
    static func read() -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw TankError.keychain }
        } else if status != errSecSuccess { throw TankError.keychain }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TankError.keychain }
    }
}

enum TankError: LocalizedError {
    case http(Int), provider, malformed, keychain
    var errorDescription: String? {
        switch self {
        case .http(401): return "API key rejected. Check the saved RapidAPI key."
        case .http(403): return "Access denied. Check your subscription to the Tank01 NFL API."
        case .http(429): return "RapidAPI rate limit or quota reached. Auto-refresh stopped."
        case .http(let code): return "Tank01 request failed (HTTP \(code))."
        case .provider: return "Tank01 returned an API error. Check the game ID and your subscription in its playground."
        case .malformed: return "Tank01 returned an unexpected response."
        case .keychain: return "Couldn’t update the API key in this device’s Keychain."
        }
    }
}

enum Tank01Client {
    static let host = "tank01-nfl-live-in-game-real-time-statistics-nfl.p.rapidapi.com"
    static func request(path: String, query: [URLQueryItem], key: String) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/" + path
        components.queryItems = query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "X-RapidAPI-Key")
        request.setValue(host, forHTTPHeaderField: "X-RapidAPI-Host")
        return request
    }
    static func decode(_ data: Data) throws -> FeedSnapshot {
        let root = try JSONDecoder().decode(FeedJSON.self, from: data)
        if let error = root["error"], error != .null, error.text != "", error != .bool(false) {
            throw TankError.provider
        }
        if let status = root["statusCode"]?.text, status != "200" { throw TankError.provider }
        guard let body = root["body"], body != .null else { throw TankError.malformed }
        return FeedSnapshot(body: body, raw: String(data: data, encoding: .utf8) ?? "")
    }
    static func fetch(path: String, query: [URLQueryItem], key: String) async throws -> FeedSnapshot {
        let (data, response) = try await URLSession.shared.data(for: request(path: path, query: query, key: key))
        guard let response = response as? HTTPURLResponse else { throw TankError.malformed }
        guard (200..<300).contains(response.statusCode) else { throw TankError.http(response.statusCode) }
        return try decode(data)
    }
    static func games(from snapshot: FeedSnapshot) -> [TankGame] {
        snapshot.body.records.compactMap { entry in
            let id = entry.1["gameID"]?.text ?? entry.0
            guard id.range(of: #"^\d{8}_[A-Z0-9]+@[A-Z0-9]+$"#, options: .regularExpression) != nil else { return nil }
            return TankGame(id: id, label: id)
        }.sorted { $0.id < $1.id }
    }
}
