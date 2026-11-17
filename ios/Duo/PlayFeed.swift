import Foundation

struct PlayImpact: Identifiable {
    let id: String
    let name: String
    let points: Double
    let explanation: String
}

struct GamePlay: Identifiable {
    let id: String
    let description: String
    let clock: String
    let impacts: [PlayImpact]
    let incomplete: Bool
    let raw: FeedJSON
}

enum PlayFeed {
    static func events(snapshot: FeedSnapshot, scoring: [String: Double]) -> [GamePlay] {
        snapshot.plays.map { index, play in
            let description = play["play"]?.text ?? play["playDescription"]?.text ?? play["description"]?.text ?? "Game update"
            let noPlay = description.localizedCaseInsensitiveContains("no play")
            let stats = play["playerStats"]?.records ?? []
            let impacts: [PlayImpact] = noPlay ? [] : stats.map { playerID, categories in
                var points = 0.0
                var terms: [String] = []
                func add(_ category: String, _ stat: String, _ rule: String, _ label: String) {
                    guard let raw = categories[category]?[stat]?.text,
                          let count = Double(raw), count != 0,
                          let weight = scoring[rule], weight != 0 else { return }
                    let change = count * weight
                    points += change
                    terms.append("\(count.formatted()) \(label)")
                }
                add("Passing", "passYds", "pass_yd", "passing yards")
                add("Passing", "passTD", "pass_td", "passing TD")
                add("Passing", "int", "pass_int", "interception")
                add("Passing", "passAttempts", "pass_att", "pass attempts")
                add("Passing", "passCompletions", "pass_cmp", "completions")
                add("Rushing", "rushYds", "rush_yd", "rushing yards")
                add("Rushing", "rushTD", "rush_td", "rushing TD")
                add("Rushing", "carries", "rush_att", "carries")
                add("Receiving", "recYds", "rec_yd", "receiving yards")
                add("Receiving", "recTD", "rec_td", "receiving TD")
                add("Receiving", "receptions", "rec", "receptions")
                add("Passing", "twoPointConversions", "pass_2pt", "two-point passes")
                add("Rushing", "twoPointConversions", "rush_2pt", "two-point rushes")
                add("Receiving", "twoPointConversions", "rec_2pt", "two-point catches")
                add("Kicking", "xpMade", "xpm", "extra points")
                add("Kicking", "xpMissed", "xpmiss", "missed extra points")
                add("Kicking", "fgMissed", "fgmiss", "missed field goals")
                if let made = categories["Kicking"]?["fgMade"]?.text.flatMap(Double.init), made > 0,
                   let yards = categories["Kicking"]?["fgYds"]?.text.flatMap(Double.init) {
                    let band = yards >= 60 ? "60p" : yards >= 50 ? "50_59" : yards >= 40 ? "40_49" : yards >= 30 ? "30_39" : yards >= 20 ? "20_29" : "0_19"
                    var weight = (scoring["fgm"] ?? 0) + (scoring["fgm_" + band] ?? 0)
                    if yards >= 50 { weight += scoring["fgm_50p"] ?? 0 }
                    weight += yards * (scoring["fgm_yds"] ?? 0)
                    weight += max(0, yards - 30) * (scoring["fgm_yds_over_30"] ?? 0)
                    points += made * weight
                    terms.append("\(Int(yards))-yard field goal")
                }
                // Some payloads repeat fumble stats under multiple categories: count each only once.
                for (stat, rule, label) in [("fumblesLost", "fum_lost", "fumbles lost"), ("fumbles", "fum", "fumbles")] {
                    if let count = categories.records.compactMap({ $0.1[stat]?.text.flatMap(Double.init) }).first,
                       count != 0, let weight = scoring[rule], weight != 0 {
                        points += count * weight
                        terms.append("\(count.formatted()) \(label)")
                    }
                }
                let name = snapshot.body["playerStats"]?[playerID]?["longName"]?.text ?? "Player \(playerID)"
                return PlayImpact(id: playerID, name: name, points: points, explanation: terms.joined(separator: " · "))
            }
            return GamePlay(id: play["playID"]?.text ?? index, description: description,
                clock: [play["playPeriod"]?.text, play["playClock"]?.text].compactMap { $0 }.joined(separator: " · "),
                impacts: impacts.filter { abs($0.points) > 0.00001 }.sorted { $0.name < $1.name },
                incomplete: !noPlay && stats.isEmpty, raw: play)
        }
    }

    static func changes(previous: [GamePlay], current: [GamePlay]) -> (new: Set<String>, updated: Set<String>) {
        let old = Dictionary(previous.map { ($0.id, $0.raw) }, uniquingKeysWith: { _, last in last })
        guard !previous.isEmpty else { return ([], []) }
        return (Set(current.filter { old[$0.id] == nil }.map(\.id)),
                Set(current.filter { old[$0.id] != nil && old[$0.id] != $0.raw }.map(\.id)))
    }
}
