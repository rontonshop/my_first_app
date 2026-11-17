# Shared Live Feed

Live Feed now reads the shared backend automatically every five seconds. The one-game chooser, Live test controls, and RapidAPI-key form were removed. Users do not need a Tank01 key. Existing device Keychain values are not used by the Live Feed tab.

The simulator defaults to http://127.0.0.1:8787. Start the backend with:

    python3 backend/server.py

For cloud hosting, see backend/README.md and render.yaml. Set the hosted HTTPS origin using the gear menu (Feed connection) or the app's FeedServerURL Info.plist value. Hosting is prepared but not deployed until an account is connected and the service is created.

## Feed display

- One combined stream of all collected games, with the latest game/score above the event quarter/clock.
- Latest score labels distinguish the current scoreboard from the historical play clock.
- Names and point changes come from Tank01's allPlayByPlay.playerStats fields, using PNW 2026 league scoring loaded by the backend.
- Player totals are recomputed chronologically from each full game snapshot. Repeated reads and corrected plays do not double-count points.
- Current fantasy team + owner/co-owners appear when mapped. Starters show running game total plus the play delta (green gains/red losses). Bench players show only their running total. Unmapped players are labeled explicitly rather than assigned a guessed owner.
- Backend sequence IDs merge games by when plays were first received. The app displays the 300 most recently received events.
- Per-play omissions, D/ST team scoring, and threshold bonuses remain limitations.

## Local validation

    python3 -m unittest discover -s backend -v
    xcrun swiftc ios/Duo/Tank01Client.swift ios/Duo/PlayFeed.swift ios/Tests/PlayFeedChecks.swift -o /tmp/duo-play-checks
    /tmp/duo-play-checks ios/Tests/Fixtures/tank01-plays.json

Keep simulator code signing enabled. The preserved diagnostic flag --keychain-self-check tests only a dummy Keychain item; the new feed no longer requires device provider credentials.
