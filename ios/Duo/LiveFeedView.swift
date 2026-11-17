import SwiftUI

struct LiveFeedView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var key = ""
    @State private var enteredKey = ""
    @State private var keyLoaded = false
    @State private var date = Date()
    @State private var games: [TankGame] = []
    @State private var gameID = ""
    @State private var polling = false
    @State private var visible = false
    @State private var busy = false
    @State private var snapshot: FeedSnapshot?
    @State private var updatedAt: Date?
    @State private var errorMessage: String?
    @State private var requests = 0
    @State private var scoring: [String: Double] = [:]
    @State private var events: [GamePlay] = []
    @State private var newPlays: Set<String> = []
    @State private var updatedPlays: Set<String> = []

    private var canFetch: Bool {
        !key.isEmpty && gameID.range(of: #"^\d{8}_[A-Z0-9]+@[A-Z0-9]+$"#, options: .regularExpression) != nil
    }
    private var shouldPoll: Bool { polling && visible && scenePhase == .active && canFetch }

    var body: some View {
        NavigationStack {
            List {
                Section("RapidAPI connection") {
                    if key.isEmpty {
                        SecureField("Paste your X-RapidAPI-Key", text: $enteredKey)
                            .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Save key on this device") { saveKey() }
                            .disabled(enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Label("API key saved in Keychain", systemImage: "lock.fill")
                        Button("Remove API key", role: .destructive) { removeKey() }
                            .disabled(busy)
                    }
                    Text("Copy X-RapidAPI-Key from the Tank01 NFL playground. It stays on this device and is sent only to RapidAPI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Choose one NFL game") {
                    DatePicker("Game date", selection: $date, displayedComponents: .date)
                        .disabled(busy || polling)
                    Button("Find games for date") { Task { await findGames() } }
                        .disabled(key.isEmpty || busy || polling)
                    if !games.isEmpty {
                        Picker("Game", selection: $gameID) {
                            Text("Choose game").tag("")
                            ForEach(games) { Text($0.label).tag($0.id) }
                        }.pickerStyle(.menu).disabled(busy || polling)
                    }
                    TextField("Game ID: YYYYMMDD_AWAY@HOME", text: $gameID)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .disabled(busy || polling)
                    Text("You can also copy a gameID from the Tank01 playground.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Live test") {
                    Toggle("Refresh every 10 seconds", isOn: $polling)
                        .disabled(!canFetch || (busy && !polling))
                    Button("Refresh once") { Task { await refresh() } }
                        .disabled(!canFetch || busy || polling)
                    if busy { ProgressView("Requesting Tank01…") }
                    Text("One selected game · about 360 requests/hour. Refresh runs only while this tab is visible and the app is active. Any request error stops auto-refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(requests) requests this session").font(.caption).foregroundStyle(.secondary)
                    if let updatedAt {
                        Text("Last successful refresh: " + updatedAt.formatted(date: .omitted, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
                if let snapshot {
                    Section("Game") {
                        Text(gameID).font(.headline)
                        Text(snapshot.status).foregroundStyle(.secondary)
                        if let away = snapshot.body["awayPts"]?.text, let home = snapshot.body["homePts"]?.text {
                            Text("\(snapshot.body["away"]?.text ?? "Away") \(away)  –  \(snapshot.body["home"]?.text ?? "Home") \(home)")
                                .font(.title2.bold()).monospacedDigit()
                        }
                    }
                    Section("Game activity") {
                        Text("PNW 2026 scoring · Newest plays first")
                            .font(.caption).foregroundStyle(.secondary)
                        if events.isEmpty {
                            Text("No plays available yet. Refresh again after the game starts.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(events.reversed()) { play in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(play.clock).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if newPlays.contains(play.id) { Text("NEW").font(.caption.bold()).foregroundStyle(.blue) }
                                    if updatedPlays.contains(play.id) { Text("UPDATED").font(.caption.bold()).foregroundStyle(.orange) }
                                }
                                Text(play.description).font(.subheadline)
                                ForEach(play.impacts) { impact in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(impact.name).font(.subheadline.weight(.semibold))
                                            Spacer()
                                            Text(signedPoints(impact.points)).font(.headline).monospacedDigit()
                                                .foregroundStyle(impact.points < 0 ? .red : .green)
                                        }
                                        Text(impact.explanation).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if play.impacts.isEmpty {
                                    Text(play.incomplete ? "No player stats supplied for this event." : "No scored player change in the supplied stats.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 8)
                        }
                    }
                    Section {
                        Text("Points are calculated from Tank01’s per-play player stats using your league’s scoring. Provider omissions may leave plays incomplete. D/ST team scoring and threshold bonuses are not included. Refresh replaces revised plays rather than adding their points twice.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Live Feed")
            .onAppear {
                visible = true
                if !keyLoaded { key = TankKeychain.read(); keyLoaded = true }
            }
            .onDisappear { visible = false }
            .onChange(of: gameID) { _, _ in snapshot = nil; events = []; newPlays = []; updatedPlays = []; updatedAt = nil; errorMessage = nil }
            .task(id: shouldPoll) {
                guard shouldPoll else { return }
                while !Task.isCancelled && shouldPoll {
                    let started = Date()
                    await refresh()
                    guard !Task.isCancelled && shouldPoll else { break }
                    let remaining = max(0, 10 - Date().timeIntervalSince(started))
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { break }
                }
            }
        }
    }
    private func signedPoints(_ points: Double) -> String {
        (points >= 0 ? "+" : "") + points.formatted(.number.precision(.fractionLength(2))) + " pts"
    }
    private func loadScoring() async throws -> [String: Double] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://api.sleeper.app/v1/league/1399979975465041920")!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw TankError.malformed }
        let league = try JSONDecoder().decode(FeedJSON.self, from: data)
        guard let settings = league["scoring_settings"] else { throw TankError.malformed }
        let rules = Dictionary(uniqueKeysWithValues: settings.records.compactMap { key, value -> (String, Double)? in
            guard let number = value.text.flatMap(Double.init) else { return nil }
            return (key, number)
        })
        guard !rules.isEmpty else { throw TankError.malformed }
        return rules
    }
    private func saveKey() {
        let cleaned = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try TankKeychain.save(cleaned)
            key = cleaned; enteredKey = ""; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    private func removeKey() {
        polling = false
        do { try TankKeychain.delete(); key = ""; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    @MainActor private func findGames() async {
        guard !busy && !key.isEmpty else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd"
        do {
            requests += 1
            let result = try await Tank01Client.fetch(path: "getNFLGamesForDate",
                query: [URLQueryItem(name: "gameDate", value: format.string(from: date))], key: key)
            games = Tank01Client.games(from: result)
            gameID = games.first?.id ?? ""
            if games.isEmpty { errorMessage = "No games returned for this date. You can enter a game ID manually." }
        } catch { errorMessage = error.localizedDescription }
    }
    @MainActor private func refresh() async {
        guard !busy && canFetch else { return }
        let requestedGame = gameID
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            if scoring.isEmpty { scoring = try await loadScoring() }
            requests += 1
            let result = try await Tank01Client.fetch(path: "getNFLBoxScore", query: [
                URLQueryItem(name: "gameID", value: requestedGame),
                URLQueryItem(name: "playByPlay", value: "true"),
                URLQueryItem(name: "fantasyPoints", value: "true")
            ], key: key)
            guard !Task.isCancelled && gameID == requestedGame else { return }
            let nextEvents = PlayFeed.events(snapshot: result, scoring: scoring)
            let changes = PlayFeed.changes(previous: events, current: nextEvents)
            newPlays = changes.new
            updatedPlays = changes.updated
            events = nextEvents
            snapshot = result
            updatedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            polling = false
        }
    }
}
