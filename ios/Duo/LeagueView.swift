import SwiftUI

private struct SleeperUser: Decodable {
    let user_id: String
    let display_name: String?
    let metadata: [String: String]?
    var teamName: String { metadata?["team_name"] ?? display_name ?? "Unnamed team" }
}

private struct NFLState: Decodable { let season: String }

private struct SleeperLeague: Decodable, Identifiable {
    let league_id: String
    let name: String
    let scoring_settings: [String: Double]
    var id: String { league_id }
}

private struct SleeperRoster: Decodable, Identifiable {
    let roster_id: Int
    let owner_id: String?
    let co_owners: [String]?
    let players: [String]?
    let starters: [String]?
    let reserve: [String]?
    let taxi: [String]?
    var id: Int { roster_id }
    func status(for id: String) -> String {
        if starters?.contains(id) == true { return "Starter" }
        if reserve?.contains(id) == true { return "IR" }
        if taxi?.contains(id) == true { return "Taxi" }
        return "Bench"
    }
}

private struct SleeperPlayer: Decodable {
    let full_name: String?
    let first_name: String?
    let last_name: String?
    let position: String?
    let team: String?
    func name(fallback: String) -> String {
        if let full_name, !full_name.isEmpty { return full_name }
        let joined = [first_name, last_name].compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? fallback : joined
    }
}

private enum SleeperAPI {
    static func playerDirectory() async throws -> [String: SleeperPlayer] {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sleeper-nfl-players.json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 86_400,
           let data = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode([String: SleeperPlayer].self, from: data) {
            return cached
        }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://api.sleeper.app/v1/players/nfl")!)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode([String: SleeperPlayer].self, from: data)
        try? data.write(to: file, options: .atomic)
        return decoded
    }

    static func get<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: "https://api.sleeper.app/v1/" + path)!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct LeagueView: View {
    @State private var leagues: [SleeperLeague] = []
    @State private var selectedLeague = ""
    @State private var members: [SleeperUser] = []
    @State private var rosters: [SleeperRoster] = []
    @State private var players: [String: SleeperPlayer] = [:]
    @State private var userID = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var search = ""
    @State private var updatedAt: Date?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("rontonsoup8", systemImage: "person.crop.circle.fill")
                    if !leagues.isEmpty {
                        Picker("League", selection: $selectedLeague) {
                            ForEach(leagues) { league in
                                Text(league.name).tag(league.id)
                            }
                        }
                    }
                    if let league = leagues.first(where: { $0.id == selectedLeague }) {
                        Text("Reception: " + (league.scoring_settings["rec"] ?? 0).formatted() + " points")
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("Connected to Sleeper") }

                if loading {
                    Section { ProgressView("Loading league…") }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        Button("Try again") { Task { await connect() } }
                    }
                }
                if !loading && errorMessage == nil && leagues.isEmpty {
                    Section { Text("No NFL leagues found for the current Sleeper season.") }
                }
                ForEach(sortedRosters) { roster in
                    Section {
                        ForEach((roster.players ?? []).filter { matches($0) }, id: \.self) { id in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(players[id]?.name(fallback: id) ?? id)
                                    Text([players[id]?.position, players[id]?.team].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(roster.status(for: id))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(roster.status(for: id) == "Starter" ? .green : .secondary)
                            }
                        }
                    } header: {
                        Text(teamName(roster) + (isMine(roster) ? " · Your team" : ""))
                    } footer: {
                        Text(ownerNames(roster))
                    }
                }
                Section("Game feed") {
                    Text("Live play-by-play is not connected yet. Player ownership and lineup labels above come from current Sleeper rosters.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let updatedAt {
                        Text("Roster refresh: " + updatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("League")
            .searchable(text: $search, prompt: "Find a rostered player")
            .refreshable { await connect() }
            .task { await connect() }
            .task(id: selectedLeague) {
                guard !selectedLeague.isEmpty else { return }
                await loadRosters()
            }
        }
    }

    private var sortedRosters: [SleeperRoster] {
        rosters.sorted {
            if isMine($0) != isMine($1) { return isMine($0) }
            return $0.roster_id < $1.roster_id
        }
    }
    private func isMine(_ roster: SleeperRoster) -> Bool {
        roster.owner_id == userID || roster.co_owners?.contains(userID) == true
    }
    private func teamName(_ roster: SleeperRoster) -> String {
        members.first { $0.user_id == roster.owner_id }?.teamName ?? "Team \(roster.roster_id)"
    }
    private func ownerNames(_ roster: SleeperRoster) -> String {
        let ids = [roster.owner_id].compactMap { $0 } + (roster.co_owners ?? [])
        let names = ids.map { id in members.first { $0.user_id == id }?.display_name ?? id }
        return names.isEmpty ? "No owner" : "Owned by " + names.joined(separator: " & ")
    }
    private func matches(_ id: String) -> Bool {
        search.isEmpty || (players[id]?.name(fallback: id) ?? id).localizedCaseInsensitiveContains(search)
    }

    @MainActor private func connect() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let user: SleeperUser = try await SleeperAPI.get("user/rontonsoup8")
            let state: NFLState = try await SleeperAPI.get("state/nfl")
            let found: [SleeperLeague] = try await SleeperAPI.get("user/\(user.user_id)/leagues/nfl/\(state.season)")
            userID = user.user_id
            leagues = found
            if players.isEmpty {
                players = try await SleeperAPI.playerDirectory()
            }
            let next = found.contains { $0.id == selectedLeague } ? selectedLeague : (found.first?.id ?? "")
            if next == selectedLeague && !next.isEmpty {
                await loadRosters()
            } else {
                selectedLeague = next
                if next.isEmpty { rosters = []; members = [] }
            }
        } catch is CancellationError {
        } catch {
            errorMessage = "Couldn’t refresh Sleeper. Check your connection and try again."
        }
    }

    @MainActor private func loadRosters() async {
        let leagueID = selectedLeague
        errorMessage = nil
        rosters = []
        members = []
        do {
            async let fetchedMembers: [SleeperUser] = SleeperAPI.get("league/\(leagueID)/users")
            async let fetchedRosters: [SleeperRoster] = SleeperAPI.get("league/\(leagueID)/rosters")
            let (newMembers, newRosters) = try await (fetchedMembers, fetchedRosters)
            guard selectedLeague == leagueID else { return }
            members = newMembers
            rosters = newRosters
            updatedAt = Date()
        } catch is CancellationError {
        } catch {
            guard selectedLeague == leagueID else { return }
            errorMessage = "Couldn’t load league rosters. Pull down to retry."
        }
    }
}
