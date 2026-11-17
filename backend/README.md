# Local Tank01 backend

Run with Python 3 (no dependencies):

    python3 backend/server.py

Endpoints:

- GET /health — connection configuration status only; makes no paid API call.
- GET /api/tank01/games?gameDate=20241020
- GET /api/tank01/boxscore?gameID=20241020_CAR%40WSH

The supplied credential is stored outside this project at ~/.config/my_first_app/tank01.env, with file permissions 600. Replace its TANK01_API_KEY value after rotating the key in RapidAPI. Alternatively, set the TANK01_API_KEY environment variable. Neither credentials nor upstream request headers are logged.

Box score requests preserve the supplied scoring preset: half PPR, 0.2 points per carry, and -2 per passing interception, among the other supplied settings. This is a testing preset; it differs from PNW 2026's Sleeper scoring. The game ID is supplied on each request, rather than fixed to the historical example.

The server binds only to 127.0.0.1:8787. It is not deployed, not accessible from a physical iPhone, and not yet wired into the SwiftUI tab. The app currently continues to use its device Keychain configuration. Future shared hosting needs authenticated app access and server-side secret configuration.

The server does not poll by itself and makes one upstream request per data endpoint call. Starting it and checking /health consume no Tank01 requests.

Run checks:

    python3 -m unittest discover -s backend -v
