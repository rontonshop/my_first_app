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
                    Section("Play-by-play") {
                        if snapshot.plays.isEmpty {
                            Text("No playByPlay entries found yet. Inspect the full response below to check this game’s data.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.plays, id: \.0) { entry in
                            DisclosureGroup {
                                Text(entry.1.pretty).font(.caption.monospaced()).textSelection(.enabled)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Play \(entry.0)").font(.caption).foregroundStyle(.secondary)
                                    Text(playTitle(entry.1)).font(.subheadline)
                                }
                            }
                        }
                    }
                    Section("Player box scores") {
                        ForEach(snapshot.playerStats, id: \.0) { entry in
                            DisclosureGroup(entry.1["longName"]?.text ?? entry.1["name"]?.text ?? "Player \(entry.0)") {
                                Text(entry.1.pretty).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        Text("Tank01 box-score data and scoring defaults, not league-adjusted scores. Per-play fantasy-point attribution and Sleeper ownership are not connected to this tab yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        DisclosureGroup("Full API response") {
                            Text(snapshot.raw).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Live Feed")
            .onAppear {
                visible = true
                if !keyLoaded { key = TankKeychain.read(); keyLoaded = true }
            }
            .onDisappear { visible = false }
            .onChange(of: gameID) { _, _ in snapshot = nil; updatedAt = nil; errorMessage = nil }
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
    private func playTitle(_ play: FeedJSON) -> String {
        for key in ["playDescription", "description", "playText", "longDescription"] {
            if let value = play[key]?.text { return value }
        }
        return play.text ?? String(play.pretty.prefix(180))
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
            requests += 1
            let result = try await Tank01Client.fetch(path: "getNFLBoxScore", query: [
                URLQueryItem(name: "gameID", value: requestedGame),
                URLQueryItem(name: "playByPlay", value: "true"),
                URLQueryItem(name: "fantasyPoints", value: "true")
            ], key: key)
            guard !Task.isCancelled && gameID == requestedGame else { return }
            snapshot = result
            updatedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            polling = false
        }
    }
}
