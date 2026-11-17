import Foundation

@main
struct SharedFeedChecks {
    static func main() throws {
        let snapshot = try Tank01Client.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let starter = FeedOwner(team_name: "Example Team", owner_name: "Example Owner", starter: true)
        let bench = FeedOwner(team_name: "Other Team", owner_name: "Other Owner", starter: false)
        let context = SharedLeagueContext(league_name: "Test", settings: ["pass_yd": 0.04, "rec": 1, "rec_yd": 0.1],
            ownership: ["14012": starter, "4431588": bench, "name:brianrobinson|WSH": starter],
            known_player_ids: ["14012", "4431588", "name:brianrobinson|WSH"], updated_at: nil)
        let first = CachedFeedGame(id: "first", body: snapshot.body, updated_at: 100, active: true,
            play_sequences: ["0": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7])
        let second = CachedFeedGame(id: "second", body: snapshot.body, updated_at: 100, active: true,
            play_sequences: ["0": 8, "1": 9, "2": 10, "3": 11, "4": 12, "5": 13, "6": 14])
        let payload = SharedFeedPayload(games: [first, second], scoring: context, collector: nil)
        let cards = SharedFeedClient.cards(payload)
        precondition(cards.count == 14)
        precondition(Set(cards.map(\.id)).count == 14) // Same play index across games remains distinct.
        precondition(cards.first?.game.id == "second" && cards.first?.sequence == 14)
        precondition(context.ownership["14012"]!.starter)
        precondition(!context.ownership["4431588"]!.starter)
        let fallbackBody = try JSONDecoder().decode(FeedJSON.self, from: Data(#"{"playerStats":{"missing-id":{"teamAbv":"WAS"}}}"#.utf8))
        let fallbackGame = CachedFeedGame(id: "fallback", body: fallbackBody, updated_at: 100, active: true, play_sequences: [:])
        let impact = PlayImpact(id: "missing-id", name: "Brian Robinson Jr.", points: 1, totalAfterPlay: 1, explanation: "")
        precondition(SharedFeedClient.ownershipKey(impact, game: fallbackGame, context: context) == "name:brianrobinson|WSH")
        precondition(SharedFeedClient.validURL("https://example.com") != nil)
        precondition(SharedFeedClient.validURL("http://127.0.0.1:8787") != nil)
        precondition(SharedFeedClient.validURL("http://example.com") == nil)
        print("Passed: multi-game merge, unique event identity, ownership role/fallback, server URL validation.")
    }
}
