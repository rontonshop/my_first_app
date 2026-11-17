import Foundation

struct FeedOwner: Decodable {
    let team_name: String
    let owner_name: String
    let starter: Bool
}

struct SharedLeagueContext: Decodable {
    let league_name: String
    let settings: [String: Double]
    let ownership: [String: FeedOwner]
    let known_player_ids: [String]
    let updated_at: Double?
    var positions: [String: String]? = nil
}

struct CachedFeedGame: Decodable, Identifiable {
    let id: String
    let body: FeedJSON
    let updated_at: Double
    let active: Bool
    let play_sequences: [String: Int]
    var snapshot: FeedSnapshot { FeedSnapshot(body: body, raw: "") }
}

struct FeedCollectorStatus: Decodable {
    let last_tick: Double?
    let error: String?
}

struct SharedFeedPayload: Decodable {
    let games: [CachedFeedGame]
    let scoring: SharedLeagueContext?
    let collector: FeedCollectorStatus?
    var refresh_seconds: Double? = nil
}

struct SharedFeedCard: Identifiable {
    let game: CachedFeedGame
    let play: GamePlay
    let sequence: Int
    var id: String { game.id + ":" + play.id }
}

enum SharedFeedClient {
    static var defaultURL: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "FeedServerURL") as? String, !configured.isEmpty {
            return configured
        }
        #if targetEnvironment(simulator)
        return "http://127.0.0.1:8787"
        #else
        return ""
        #endif
    }
    static func validURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        guard url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else { return nil }
        return url
    }
    static func fetch(baseURL: String) async throws -> SharedFeedPayload {
        guard let base = validURL(baseURL) else { throw URLError(.badURL) }
        let request = URLRequest(url: base.appendingPathComponent("api/feed"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(SharedFeedPayload.self, from: data)
    }
    static func ownershipKey(_ impact: PlayImpact, game: CachedFeedGame, context: SharedLeagueContext?) -> String {
        if context?.ownership[impact.id] != nil { return impact.id }
        guard let teamValue = game.body["playerStats"]?[impact.id]?["teamAbv"]?.text ?? game.body["playerStats"]?[impact.id]?["team"]?.text else { return impact.id }
        var words = impact.name.lowercased().replacingOccurrences(of: ".", with: "").split(separator: " ").map(String.init)
        while let last = words.last, ["jr", "sr", "ii", "iii", "iv"].contains(last) { words.removeLast() }
        let normalized = words.joined().filter { $0.isLetter || $0.isNumber }
        let team = ["WAS": "WSH", "JAC": "JAX"][teamValue.uppercased()] ?? teamValue.uppercased()
        let key = "name:" + normalized + "|" + team
        if context?.known_player_ids.contains(key) == true { return key }
        return impact.id
    }
    static func cards(_ payload: SharedFeedPayload) -> [SharedFeedCard] {
        payload.games.flatMap { game in
            PlayFeed.events(snapshot: game.snapshot, scoring: payload.scoring?.settings ?? [:]).map { play in
                SharedFeedCard(game: game, play: play, sequence: game.play_sequences[play.id] ?? 0)
            }
        }.sorted {
            if $0.sequence != $1.sequence { return $0.sequence > $1.sequence }
            return $0.id < $1.id
        }.prefix(300).map { $0 }
    }
}
