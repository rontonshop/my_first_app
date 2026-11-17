import Foundation

@main
struct Tank01ClientChecks {
    static func main() throws {
        let request = Tank01Client.request(path: "getNFLBoxScore", query: [
            URLQueryItem(name: "gameID", value: "20261116_DAL@PHI"),
            URLQueryItem(name: "playByPlay", value: "true")
        ], key: "test-placeholder")
        precondition(request.url?.host == Tank01Client.host)
        precondition(request.value(forHTTPHeaderField: "X-RapidAPI-Key") == "test-placeholder")
        precondition(!(request.url?.absoluteString.contains("test-placeholder") ?? true))
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.contains(URLQueryItem(name: "gameID", value: "20261116_DAL@PHI")))
        precondition(query.contains(URLQueryItem(name: "playByPlay", value: "true")))

        // Synthetic schema fixtures; real account data is verified only after a key is entered.
        let data = Data(#"{"statusCode":200,"body":{"playByPlay":[{"description":"First play"},{"description":"Corrected play"}],"playerStats":{"123":{"longName":"Test Player","fantasyPoints":-2.0}}}}"#.utf8)
        let snapshot = try Tank01Client.decode(data)
        precondition(snapshot.plays.count == 2)
        precondition(snapshot.playerStats.first?.1["fantasyPoints"] == .number(-2))
        let corrected = try Tank01Client.decode(Data(#"{"statusCode":"200","body":{"playByPlay":{"10":{"description":"Correction"},"2":{"description":"Earlier"}}}}"#.utf8))
        precondition(corrected.plays.map { $0.0 } == ["2", "10"])
        for payload in [
            #"{"statusCode":200,"error":"invalid game","body":{}}"#,
            #"{"statusCode":403,"body":{}}"#,
            #"{"statusCode":200}"#
        ] {
            do {
                _ = try Tank01Client.decode(Data(payload.utf8))
                preconditionFailure("API error must not become a successful snapshot")
            } catch { }
        }
        let games = try Tank01Client.decode(Data(#"{"statusCode":200,"body":[{"gameID":"20261116_DAL@PHI"}]}"#.utf8))
        precondition(Tank01Client.games(from: games).first?.id == "20261116_DAL@PHI")
        let gameMap = try Tank01Client.decode(Data(#"{"statusCode":200,"body":{"20261116_DAL@PHI":{"away":"DAL","home":"PHI"}}}"#.utf8))
        precondition(Tank01Client.games(from: gameMap).count == 1)
        print("Passed: request authentication, query encoding, play arrays/maps, negative scores, provider errors, game lists/maps.")
    }
}
