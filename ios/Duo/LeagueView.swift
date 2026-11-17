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
    let matchup_id: Int?
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

private struct WeeklyPair: Identifiable {
    let id: String
    let teams: [SleeperMatchup]
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
    @State private var week = 1
    @State private var matchups: [SleeperMatchup] = []
    @State private var rosterLoading = false
    @State private var expanded: Set<String> = []
    @State private var requestID = UUID()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("rontonsoup8", systemImage: "person.crop.circle.fill")
                    if !leagues.isEmpty {
                        Picker("League", selection: $selectedLeague) {
                            ForEach(leagues) { Text($0.name).tag($0.id) }
                        }.pickerStyle(.menu)
                    }
                    Picker("Week", selection: $week) {
                        ForEach(1...18, id: \.self) { Text("Week \($0)").tag($0) }
                    }.pickerStyle(.menu)
                    Text("Tap a matchup to open both lineups.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if loading || rosterLoading {
                    Section { ProgressView("Loading Week \(week)…") }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        Button("Try again") { Task { await connect() } }
                    }
                }
                if !loading && !rosterLoading && errorMessage == nil && matchups.isEmpty {
                    Section { Text("No matchups available for Week \(week).").foregroundStyle(.secondary) }
                }
                ForEach(weeklyPairs) { pair in
                    Section {
                        DisclosureGroup(isExpanded: expansion(for: pair.id)) {
                            ForEach(pair.teams, id: \.roster_id) { team in
                                teamLineup(team)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                summary(pair.teams[0])
                                Text("vs").font(.caption.bold()).foregroundStyle(.secondary)
                                    .padding(.top, 6)
                                if pair.teams.count > 1 {
                                    summary(pair.teams[1])
                                } else {
                                    Text("Bye / no opponent")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                }
                            }.padding(.vertical, 8)
                        }
                    }
                }
                Section {
                    Text("Week \(week) · Sleeper scores. Totals count starters only, including any commissioner adjustment. Pull down to refresh.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let updatedAt {
                        Text("Updated " + updatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Matchups")
            .searchable(text: $search, prompt: "Find a player in this week’s lineups")
            .refreshable { await connect() }
            .task { await connect() }
            .task(id: "\(selectedLeague):\(week)") {
                guard !selectedLeague.isEmpty else { return }
                await loadMatchups()
            }
        }
    }

    private var weeklyPairs: [WeeklyPair] {
        let grouped = Dictionary(grouping: matchups) {
            $0.matchup_id.map { "matchup-\($0)" } ?? "bye-\($0.roster_id)"
        }
        return grouped.map { key, teams in
            WeeklyPair(id: key, teams: teams.sorted { $0.roster_id < $1.roster_id })
        }.sorted {
            let lhsMine = $0.teams.contains { isMine($0.roster_id) }
            let rhsMine = $1.teams.contains { isMine($0.roster_id) }
            if lhsMine != rhsMine { return lhsMine }
            return ($0.teams.first?.matchup_id ?? Int.max, $0.teams[0].roster_id) <
                   ($1.teams.first?.matchup_id ?? Int.max, $1.teams[0].roster_id)
        }
    }
    private func expansion(for id: String) -> Binding<Bool> {
        Binding(get: { !search.isEmpty || expanded.contains(id) }, set: { value in
            if value { expanded.insert(id) } else { expanded.remove(id) }
        })
    }
    private func summary(_ team: SleeperMatchup) -> some View {
        VStack(spacing: 6) {
            Text(teamName(team.roster_id)).font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center).foregroundStyle(.primary)
            Text(score(team.custom_points ?? team.points))
                .font(.title2.bold()).monospacedDigit().foregroundStyle(.primary)
            if isMine(team.roster_id) {
                Text("Your team").font(.caption).foregroundStyle(.blue)
            }
        }.frame(maxWidth: .infinity)
    }
    private func teamLineup(_ team: SleeperMatchup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Text(teamName(team.roster_id)).font(.headline)
                Spacer()
                Text(score(team.custom_points ?? team.points)).font(.headline).monospacedDigit()
            }
            Text(ownerNames(team.roster_id)).font(.caption).foregroundStyle(.secondary)
            if let opponent = matchups.first(where: {
                team.matchup_id != nil && $0.matchup_id == team.matchup_id && $0.roster_id != team.roster_id
            }) {
                Text("Week \(week) vs \(teamName(opponent.roster_id))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if team.custom_points != nil {
                Text("Total includes commissioner adjustment").font(.caption).foregroundStyle(.secondary)
            }
            Text("STARTERS").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(startingSlots.enumerated()), id: \.offset) { index, slot in
                let id = index < team.starters.count ? team.starters[index] : "0"
                if id == "0" || matches(id) {
                    playerRow(id: id, slot: slot, matchup: team, starterIndex: index)
                    Divider()
                }
            }
            Text("BENCH").font(.caption.bold()).foregroundStyle(.secondary)
            let bench = team.players.filter { !team.starters.contains($0) && matches($0) }
            ForEach(bench, id: \.self) { id in
                playerRow(id: id, slot: "BN", matchup: team)
                Divider()
            }
            if bench.isEmpty { Text("No bench players").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 12)
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
    private func playerRow(id: String, slot: String, matchup: SleeperMatchup, starterIndex: Int? = nil) -> some View {
        let empty = id == "0"
        let points: Double? = {
            if empty { return nil }
            if let index = starterIndex, let values = matchup.starters_points, index < values.count {
                return values[index]
            }
            return matchup.players_points?[id]
        }()
        return HStack(spacing: 12) {
            Text(slot).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(empty ? "Empty slot" : (players[id]?.name(fallback: id) ?? id))
                if !empty {
                    // Player directory team is current; it is not used as historical opponent data.
                    Text(players[id]?.position ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(points.map(score) ?? "—").font(.body.weight(.semibold)).monospacedDigit()
                .accessibilityLabel(points.map { score($0) + " fantasy points" } ?? "Points unavailable")
        }.padding(.vertical, 4)
    }
    private func isMine(_ rosterID: Int) -> Bool {
        guard let roster = rosters.first(where: { $0.id == rosterID }) else { return false }
        return roster.owner_id == userID || roster.co_owners?.contains(userID) == true
    }
    private func teamName(_ rosterID: Int) -> String {
        let ownerID = rosters.first { $0.id == rosterID }?.owner_id
        return members.first { $0.user_id == ownerID }?.teamName ?? "Team \(rosterID)"
    }
    private func ownerNames(_ rosterID: Int) -> String {
        guard let roster = rosters.first(where: { $0.id == rosterID }) else { return "" }
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
            if players.isEmpty { players = try await SleeperAPI.playerDirectory() }
            if selectedLeague.isEmpty {
                week = min(18, max(1, state.display_week))
                selectedLeague = found.first?.id ?? ""
            } else if !found.contains(where: { $0.id == selectedLeague }) {
                selectedLeague = found.first?.id ?? ""
            } else {
                await loadMatchups()
            }
            if selectedLeague.isEmpty { matchups = []; rosters = []; members = [] }
        } catch is CancellationError {
        } catch {
            errorMessage = "Couldn’t refresh Sleeper. Check your connection and try again."
        }
    }
    @MainActor private func loadMatchups() async {
        let leagueID = selectedLeague
        let requestedWeek = week
        let request = UUID()
        requestID = request
        rosterLoading = true
        defer { if requestID == request { rosterLoading = false } }
        errorMessage = nil
        matchups = []
        expanded = []
        do {
            async let fetchedMembers: [SleeperUser] = SleeperAPI.get("league/\(leagueID)/users")
            async let fetchedRosters: [SleeperRoster] = SleeperAPI.get("league/\(leagueID)/rosters")
            async let fetchedMatchups: [SleeperMatchup] = SleeperAPI.get("league/\(leagueID)/matchups/\(requestedWeek)")
            let (newMembers, newRosters, newMatchups) = try await (fetchedMembers, fetchedRosters, fetchedMatchups)
            guard requestID == request, selectedLeague == leagueID, week == requestedWeek else { return }
            members = newMembers
            rosters = newRosters
            matchups = newMatchups
            updatedAt = Date()
        } catch is CancellationError {
        } catch {
            guard requestID == request, selectedLeague == leagueID, week == requestedWeek, !Task.isCancelled else { return }
            errorMessage = "Couldn’t load Week \(requestedWeek). Pull down to retry."
        }
    }
}
