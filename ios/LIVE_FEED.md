# Tank01 live feed testing

1. Run Duo in Xcode and open the Live Feed tab.
2. Subscribe to Tank01 NFL on RapidAPI if necessary. In its playground, copy the X-RapidAPI-Key header value.
3. Paste the key into the app's secure field and tap Save key on this device. Do not put the key in source code, GitHub, or chat. The app stores it in Keychain on that device.
4. Choose a date and Find games for date, or paste a gameID from the playground (YYYYMMDD_AWAY@HOME).
5. Tap Refresh once to verify access, then enable Refresh every 10 seconds.

The client sends X-RapidAPI-Key and X-RapidAPI-Host headers to Tank01's RapidAPI host. Box score requests use playByPlay=true and fantasyPoints=true. Game discovery uses getNFLGamesForDate.

Only the selected game is polled, without overlapping requests. Leaving the tab or backgrounding the app pauses polling. Errors stop auto-refresh. Each poll replaces the previous snapshot, so corrected plays do not accumulate duplicates. The response inspector preserves provider fields when their detailed schema differs from the initial adapter.

10-second polling is approximately 360 box-score requests per hour, plus manual refreshes and game discovery. Check your RapidAPI quota before enabling it. Polling does not guarantee Tank01 publishes new data every 10 seconds.

The Game activity section reads Tank01 allPlayByPlay entries, resolves player names from the response, and calculates per-play fantasy changes using PNW 2026 scoring loaded from Sleeper. Provider-calculated fantasyPoints totals are not used for attribution. Each refresh replaces the snapshot and marks new or updated rows; it never adds a refreshed play to a running total. Historical plays appear on the first refresh.

Supported scoring includes common passing, rushing, receiving, kicking, two-point, and supplied fumble stats. Provider omissions remain incomplete; D/ST team scoring and threshold bonuses are not included. Player names are resolved within Tank01; Sleeper ownership mapping is not yet connected to this tab.

Verification without credentials:

    xcrun swiftc ios/Duo/Tank01Client.swift ios/Tests/Tank01ClientChecks.swift -o /tmp/duo-tank01-checks
    /tmp/duo-tank01-checks

The client checks above use synthetic schema fixtures. Per-play scoring is additionally checked against a small recorded public-game Tank01 response (CAR at WSH, 2024-10-20), stored without headers or credentials:

    xcrun swiftc ios/Duo/Tank01Client.swift ios/Duo/PlayFeed.swift ios/Tests/PlayFeedChecks.swift -o /tmp/duo-play-checks
    /tmp/duo-play-checks ios/Tests/Fixtures/tank01-plays.json

Live polling still requires an API key entered in the app.

## Simulator Keychain builds

Keep code signing enabled. Simulator.entitlements supplies a simulator-only app identity and Keychain access group; physical-device builds use Xcode's normal development signing.

    xcodebuild -project ios/Duo.xcodeproj -scheme Duo -configuration Debug -sdk iphonesimulator -derivedDataPath .build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build

Do not use CODE_SIGNING_ALLOWED=NO: that bypasses the simulator entitlement setup and causes Keychain error -34018.

For a Debug simulator build, launch with --keychain-self-check to verify dummy-item creation, update, readback, and deletion. This uses a separate temporary account and never touches the real API key or calls Tank01.
