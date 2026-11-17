# Tank01 live feed testing

1. Run Duo in Xcode and open the Live Feed tab.
2. Subscribe to Tank01 NFL on RapidAPI if necessary. In its playground, copy the X-RapidAPI-Key header value.
3. Paste the key into the app's secure field and tap Save key on this device. Do not put the key in source code, GitHub, or chat. The app stores it in Keychain on that device.
4. Choose a date and Find games for date, or paste a gameID from the playground (YYYYMMDD_AWAY@HOME).
5. Tap Refresh once to verify access, then enable Refresh every 10 seconds.

The client sends X-RapidAPI-Key and X-RapidAPI-Host headers to Tank01's RapidAPI host. Box score requests use playByPlay=true and fantasyPoints=true. Game discovery uses getNFLGamesForDate.

Only the selected game is polled, without overlapping requests. Leaving the tab or backgrounding the app pauses polling. Errors stop auto-refresh. Each poll replaces the previous snapshot, so corrected plays do not accumulate duplicates. The response inspector preserves provider fields when their detailed schema differs from the initial adapter.

10-second polling is approximately 360 box-score requests per hour, plus manual refreshes and game discovery. Check your RapidAPI quota before enabling it. Polling does not guarantee Tank01 publishes new data every 10 seconds.

This first integration displays provider play-by-play and player box scores. It does not yet attribute fantasy points to individual plays or map Tank01 player IDs to Sleeper owners. Tank01 fantasy scoring defaults may differ from the league settings.

Verification without credentials:

    xcrun swiftc ios/Duo/Tank01Client.swift ios/Tests/Tank01ClientChecks.swift -o /tmp/duo-tank01-checks
    /tmp/duo-tank01-checks

The checks use synthetic fixtures, not a recorded Tank01 response. Authenticated live behavior must be checked after entering a key in the app.

## Simulator Keychain builds

Keep code signing enabled. Simulator.entitlements supplies a simulator-only app identity and Keychain access group; physical-device builds use Xcode's normal development signing.

    xcodebuild -project ios/Duo.xcodeproj -scheme Duo -configuration Debug -sdk iphonesimulator -derivedDataPath .build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build

Do not use CODE_SIGNING_ALLOWED=NO: that bypasses the simulator entitlement setup and causes Keychain error -34018.

For a Debug simulator build, launch with --keychain-self-check to verify dummy-item creation, update, readback, and deletion. This uses a separate temporary account and never touches the real API key or calls Tank01.
