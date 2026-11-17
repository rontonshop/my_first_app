import SwiftUI
import Darwin

@main
struct DuoApp: App {
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--keychain-self-check") {
            do {
                try TankKeychain.selfCheck()
                print("KEYCHAIN_SELF_CHECK_PASS: add, update, read, delete")
            } catch {
                print("KEYCHAIN_SELF_CHECK_FAIL: " + error.localizedDescription)
            }
            fflush(stdout)
        }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            TabView {
                LeagueView()
                    .tabItem { Label("Sleeper", systemImage: "sportscourt") }
                LiveFeedView()
                    .tabItem { Label("Live Feed", systemImage: "dot.radiowaves.left.and.right") }
                ContentView()
                    .tabItem { Label("Buttons", systemImage: "circle.grid.2x1") }
            }
            .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @State private var redCount = 0
    @State private var blueCount = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("A LITTLE EXPERIMENT")
                        .font(.caption.weight(.semibold))
                        .tracking(3)
                        .foregroundStyle(.secondary)
                    Text("Two buttons.\nMake your move.")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                    Text("Pick a color. Give it a tap.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        colorButton("Red", color: .red, count: redCount) { redCount += 1 }
                        colorButton("Blue", color: .blue, count: blueCount) { blueCount += 1 }
                    }
                    Text("\(redCount + blueCount) taps total")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
            .background(Color(red: 0.06, green: 0.07, blue: 0.10))
        }
        .preferredColorScheme(.dark)
    }

    private func colorButton(_ title: String, color: Color, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 30) {
                Text(title).font(.title2.bold())
                Text("\(count)")
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                Text("Tap +1").font(.subheadline)
            }
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .leading)
            .padding(20)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 24))
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) button")
        .accessibilityValue("\(count) taps")
        .accessibilityHint("Adds one to the \(title.lowercased()) counter")
    }
}
