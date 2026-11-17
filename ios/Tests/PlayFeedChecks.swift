import Foundation

@main
struct PlayFeedChecks {
    static func main() throws {
        let file = CommandLine.arguments[1]
        let snapshot = try Tank01Client.decode(Data(contentsOf: URL(fileURLWithPath: file)))
        let rules: [String: Double] = ["pass_yd": 0.04, "pass_td": 4, "pass_int": -1,
            "rush_yd": 0.1, "rush_td": 6, "rec_yd": 0.1, "rec": 1, "rec_td": 6,
            "xpm": 1, "fgm_40_49": 4]
        let plays = PlayFeed.events(snapshot: snapshot, scoring: rules)
        func check(_ index: Int, _ id: String, _ expected: Double) {
            let actual = plays[index].impacts.first { $0.id == id }?.points
            precondition(actual != nil && abs(actual! - expected) < 0.00001)
        }
        precondition(plays.count == 7)
        check(0, "14012", 0.28) // Actual 7-yard pass.
        check(0, "4431588", 1.7) // Same play: receiver credited separately.
        check(1, "4241416", 0.4)
        check(2, "14012", -1) // Actual interception.
        precondition(plays[3].impacts.isEmpty) // No-play penalty.
        check(4, "3821683", 4) // 49-yard field goal.
        check(5, "2576980", 4.48) // Passing TD + 12 yards.
        check(5, "15835", 8.2) // Reception + 12 yards + TD.
        check(5, "3821683", 1) // Extra point in same provider entry.
        check(6, "4426348", -0.3) // Negative rushing yardage.
        let unchanged = PlayFeed.changes(previous: plays, current: plays)
        precondition(unchanged.new.isEmpty && unchanged.updated.isEmpty)
        let appended = PlayFeed.changes(previous: Array(plays.dropLast()), current: plays)
        precondition(appended.new == [plays.last!.id])
        let altered = GamePlay(id: plays[0].id, description: "Correction", clock: plays[0].clock,
            impacts: [], incomplete: false, raw: .object(["play": .string("Correction")]))
        let corrected = PlayFeed.changes(previous: plays, current: [altered] + Array(plays.dropFirst()))
        precondition(corrected.new.isEmpty && corrected.updated == [plays[0].id])
        print("Passed real Tank01 fixtures: passing/receiving, TD, interception, kicking, negative yards, no-play, refresh deduplication, corrections.")
    }
}
