import SwiftUI

struct LiveFeedView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sharedFeedURL") private var serverURL = SharedFeedClient.defaultURL
    @State private var payload: SharedFeedPayload?
    @State private var cards: [SharedFeedCard] = []
    @State private var newIDs: Set<String> = []
    @State private var updatedIDs: Set<String> = []
    @State private var knownPlayerIDs: Set<String> = []
    @State private var visible = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var lastRead: Date?
    @State private var settingsOpen = false
    @State private var draftURL = ""

    private var reading: Bool { visible && scenePhase == .active && !settingsOpen }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("LEAGUE LIVE", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.weight(.heavy)).tracking(2).foregroundStyle(.cyan)
                        Text("Every game. One feed.").font(.title2.bold())
                        let count = payload?.games.filter(\.active).count ?? 0
                        Text("\(count) active \(count == 1 ? "game" : "games") · Updates every 5 seconds")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let lastRead {
                            Text("Feed checked " + lastRead.formatted(date: .omitted, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }.listRowBackground(Color.blue.opacity(0.12))

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
                    }
                }
                if let status = payload?.collector {
                    if let error = status.error {
                        Section { Text(error).font(.footnote).foregroundStyle(.orange) }
                    }
                    if let tick = status.last_tick, Date().timeIntervalSince1970 - tick > 90 {
                        Section { Text("The shared feed is delayed. Showing the last saved updates.").font(.footnote).foregroundStyle(.orange) }
                    }
                }
                if let payload, !payload.games.isEmpty {
                    Section("Game Center · latest scores") {
                        ForEach(payload.games) { game in
                            HStack {
                                Text(gameTitle(game)).font(.headline).monospacedDigit()
                                Spacer()
                                Text(game.active ? "LIVE" : game.snapshot.status)
                                    .font(.caption.bold()).foregroundStyle(game.active ? .green : .secondary)
                            }.padding(.vertical, 6)
                        }
                    }
                }
                Section("Game activity") {
                    if cards.isEmpty {
                        if busy && payload == nil {
                            ProgressView("Loading shared feed…")
                        } else {
                            ContentUnavailableView("Waiting for live games", systemImage: "sportscourt",
                                description: Text("Plays appear automatically while games are in progress. Completed games remain available for 24 hours."))
                        }
                    }
                    ForEach(cards) { card in
                        playCard(card)
                    }
                }
                if let league = payload?.scoring {
                    Section {
                        Text("\(league.league_name) scoring · Current roster ownership · Newest received plays first")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Totals are running game points from available play stats. Provider omissions, D/ST scoring, and unsupported bonuses may cause differences from Sleeper.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Live Feed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { draftURL = serverURL; settingsOpen = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Feed connection")
                }
            }
            .sheet(isPresented: $settingsOpen) {
                NavigationStack {
                    Form {
                        Section("Shared feed server") {
                            TextField("https://your-feed-server", text: $draftURL)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Text("The shared server collects games once for everyone. No RapidAPI key is needed in the app.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Feed connection")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { settingsOpen = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                serverURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                                payload = nil; cards = []; knownPlayerIDs = []; lastRead = nil
                                settingsOpen = false
                            }.disabled(SharedFeedClient.validURL(draftURL) == nil)
                        }
                    }
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .refreshable { await refresh() }
            .task(id: "\(reading):\(serverURL)") {
                guard reading else { return }
                while !Task.isCancelled && reading {
                    let started = Date()
                    await refresh()
                    guard !Task.isCancelled else { break }
                    do { try await Task.sleep(for: .seconds(max(0.1, 5 - Date().timeIntervalSince(started)))) }
                    catch { break }
                }
            }
        }
    }

    private func gameTitle(_ game: CachedFeedGame) -> String {
        let body = game.body
        return "\(body["away"]?.text ?? "Away") \(body["awayPts"]?.text ?? "—")  –  \(body["home"]?.text ?? "Home") \(body["homePts"]?.text ?? "—")"
    }

    private func playCard(_ card: SharedFeedCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(gameTitle(card.game)).font(.headline.bold())
            HStack {
                Text(card.play.clock.isEmpty ? "Game update" : card.play.clock + " remaining")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.blue.opacity(0.16), in: Capsule())
                Spacer(minLength: 0)
                if newIDs.contains(card.id) { Text("NEW").font(.caption.bold()).foregroundStyle(.blue) }
                if updatedIDs.contains(card.id) { Text("UPDATED").font(.caption.bold()).foregroundStyle(.orange) }
            }
            Text("Latest game score").font(.caption2).foregroundStyle(.secondary)
            if let situation = card.play.fieldSituation {
                Label("Before play · " + situation, systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .accessibilityLabel("Down, distance, and field position before this play: " + situation)
            }
            Divider()
            Text(card.play.description).font(.subheadline)
            ForEach(card.play.impacts.filter { payload?.scoring?.ownership[SharedFeedClient.ownershipKey($0, game: card.game, context: payload?.scoring)] != nil || abs($0.points) > 0.00001 }) { impact in
                impactRow(impact, game: card.game)
            }
            if card.play.impacts.isEmpty {
                Text(card.play.incomplete ? "No player stats supplied for this event." : "No scored player change in the supplied stats.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 10)
    }

    private func impactRow(_ impact: PlayImpact, game: CachedFeedGame) -> some View {
        let ownershipKey = SharedFeedClient.ownershipKey(impact, game: game, context: payload?.scoring)
        let owner = payload?.scoring?.ownership[ownershipKey]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(impact.name).font(.subheadline.weight(.semibold))
                    if let owner {
                        Text(owner.team_name + " · " + owner.owner_name)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(owner.starter ? "STARTER" : "BENCH")
                            .font(.caption2.bold()).foregroundStyle(owner.starter ? .green : .secondary)
                    } else {
                        Text(knownPlayerIDs.contains(ownershipKey) ? "Free agent" : "Ownership unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Total " + impact.totalAfterPlay.formatted(.number.precision(.fractionLength(2))))
                        .font(.headline).monospacedDigit()
                    if owner?.starter != false {
                        Text(signedPoints(impact.points)).font(.subheadline.bold()).monospacedDigit()
                            .foregroundStyle(impact.points < 0 ? .red : impact.points > 0 ? .green : .secondary)
                    }
                }
            }
            if owner?.starter != false && !impact.explanation.isEmpty {
                Text(impact.explanation).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    private func signedPoints(_ points: Double) -> String {
        (points >= 0 ? "+" : "") + points.formatted(.number.precision(.fractionLength(2))) + " pts"
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        let requestedURL = serverURL
        guard SharedFeedClient.validURL(requestedURL) != nil else {
            errorMessage = "Set the shared feed address in Feed connection."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let result = try await SharedFeedClient.fetch(baseURL: requestedURL)
            guard !Task.isCancelled && requestedURL == serverURL else { return }
            let next = SharedFeedClient.cards(result)
            let previous = Dictionary(cards.map { ($0.id, $0.play.raw) }, uniquingKeysWith: { _, last in last })
            newIDs = previous.isEmpty ? [] : Set(next.filter { previous[$0.id] == nil }.map(\.id))
            updatedIDs = Set(next.filter { previous[$0.id] != nil && previous[$0.id] != $0.play.raw }.map(\.id))
            payload = result
            cards = next
            knownPlayerIDs = Set(result.scoring?.known_player_ids ?? [])
            lastRead = Date()
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Couldn’t reach the shared feed. Showing saved updates; retrying automatically."
        }
    }
}
