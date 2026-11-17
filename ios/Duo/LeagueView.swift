import SwiftUI

private struct SleeperUser: Decodable {
    let user_id: String
    let display_name: String?
    let metadata: [String: String]?
    var teamName: String { metadata?["team_name"] ?? display_name ?? "Unnamed team" }
}

private struct NFLState: Decodable { let season: String; let display_week: Int }

private struct SleeperMatchup: Decodable {
    let roster_id: Int
    let starters: [String]
    let players: [String]
    let players_points: [String: Double]?
    let starters_points: [Double]?
    let points: Double
    let custom_points: Double?
}

private struct SleeperLeague: Decodable, Identifiable {
    let league_id: String
    let name: String
    let scoring_settings: [String: Double]
    let roster_positions: [String]
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
    @State private var selectedTeam = 0
    @State private var week = 1
    @State private var matchups: [SleeperMatchup] = []
    @State private var rosterLoading = false

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
                        .pickerStyle(.menu)
                    }
                    if let league = leagues.first(where: { $0.id == selectedLeague }) {
                        Text("Reception: " + (league.scoring_settings["rec"] ?? 0).formatted() + " points")
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("Connected to Sleeper") }

                if loading || rosterLoading {
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
                if !rosters.isEmpty {
                    Section {
                        Picker("Team", selection: $selectedTeam) {
                            ForEach(sortedRosters) { roster in
                                Text(teamName(roster) + (isMine(roster) ? " · You" : "")).tag(roster.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                if let roster = rosters.first(where: { $0.id == selectedTeam }) {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(teamName(roster)).font(.headline)
                            Text(selectedMatchup.map { score($0.custom_points ?? $0.points) } ?? "—")
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("Week \(week) · Starting lineup total")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if selectedMatchup?.custom_points != nil {
                                Text("Includes commissioner score adjustment")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8)
                    } footer: { Text(ownerNames(roster)) }

                    Section("Starters") {
                        ForEach(Array(startingSlots.enumerated()), id: \.offset) { index, slot in
                            let starters = selectedMatchup?.starters ?? roster.starters ?? []
                            let id = index < starters.count ? starters[index] : "0"
                            if id == "0" || matches(id) {
                                playerRow(id: id, slot: slot, starterIndex: index)
                            }
                        }
                    }
                    Section("Bench") {
                        let starters = Set(selectedMatchup?.starters ?? roster.starters ?? [])
                        let reserves = Set((roster.reserve ?? []) + (roster.taxi ?? []))
                        let bench = (selectedMatchup?.players ?? roster.players ?? []).filter {
                            !starters.contains($0) && !reserves.contains($0) && matches($0)
                        }
                        ForEach(bench, id: \.self) { id in
                            playerRow(id: id, slot: "BN")
                        }
                        if bench.isEmpty { Text("No bench players").foregroundStyle(.secondary) }
                    }
                    if !(roster.reserve ?? []).isEmpty {
                        Section("Injured reserve") {
                            ForEach((roster.reserve ?? []).filter { matches($0) }, id: \.self) { id in
                                playerRow(id: id, slot: "IR")
                            }
                        }
                    }
                    if !(roster.taxi ?? []).isEmpty {
                        Section("Taxi") {
                            ForEach((roster.taxi ?? []).filter { matches($0) }, id: \.self) { id in
                                playerRow(id: id, slot: "TAXI")
                            }
                        }
                    }
                }
                Section("Game feed") {
                    Text("Weekly points and starting slots come from Sleeper matchups. Bench and IR points do not count toward the team total. Pull down to refresh. Live play-by-play is not connected.")
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
    private var selectedMatchup: SleeperMatchup? {
        matchups.first { $0.roster_id == selectedTeam }
    }
    private var startingSlots: [String] {
        let slots = leagues.first { $0.id == selectedLeague }?.roster_positions.filter { $0 != "BN" } ?? []
        var flex = 0
        return slots.map {
            if $0 == "FLEX" { flex += 1; return "FLEX\(flex)" }
            return $0 == "K" ? "KICKER" : $0
        }
    }
    private func score(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
    private func playerRow(id: String, slot: String, starterIndex: Int? = nil) -> some View {
        let empty = id == "0"
        let matchup = selectedMatchup
        let points: Double? = {
            if empty { return nil }
            if let index = starterIndex, let values = matchup?.starters_points, index < values.count {
                return values[index]
            }
            return matchup?.players_points?[id]
        }()
        return HStack(spacing: 12) {
            Text(slot).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(empty ? "Empty slot" : (players[id]?.name(fallback: id) ?? id))
                if !empty {
                    Text([players[id]?.position, players[id]?.team].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(points.map(score) ?? "—").font(.body.weight(.semibold)).monospacedDigit()
                .accessibilityLabel(points.map { score($0) + " fantasy points" } ?? "Points unavailable")
        }.padding(.vertical, 4)
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
            week = max(1, state.display_week)
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
                if next.isEmpty { rosters = []; members = []; matchups = []; selectedTeam = 0 }
            }
        } catch is CancellationError {
        } catch {
            errorMessage = "Couldn’t refresh Sleeper. Check your connection and try again."
        }
    }

    @MainActor private func loadRosters() async {
        let leagueID = selectedLeague
        rosterLoading = true
        defer { rosterLoading = false }
        errorMessage = nil
        rosters = []
        members = []
        matchups = []
        do {
            async let fetchedMembers: [SleeperUser] = SleeperAPI.get("league/\(leagueID)/users")
            async let fetchedRosters: [SleeperRoster] = SleeperAPI.get("league/\(leagueID)/rosters")
            async let fetchedMatchups: [SleeperMatchup] = SleeperAPI.get("league/\(leagueID)/matchups/\(week)")
            let (newMembers, newRosters, newMatchups) = try await (fetchedMembers, fetchedRosters, fetchedMatchups)
            guard selectedLeague == leagueID else { return }
            members = newMembers
            rosters = newRosters
            matchups = newMatchups
            if !newRosters.contains(where: { $0.id == selectedTeam }) {
                selectedTeam = newRosters.first(where: { isMine($0) })?.id ?? newRosters.first?.id ?? 0
            }
            updatedAt = Date()
        } catch is CancellationError {
        } catch {
            guard selectedLeague == leagueID else { return }
            errorMessage = "Couldn’t load league rosters. Pull down to retry."
        }
    }
}
