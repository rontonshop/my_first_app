"""Local Tank01 proxy. Credentials stay on the Mac, outside the repository."""
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import Request, urlopen

HOST = "tank01-nfl-live-in-game-real-time-statistics-nfl.p.rapidapi.com"
SECRET_FILE = Path.home() / ".config/my_first_app/tank01.env"

# User-provided testing preset. This differs from the PNW Sleeper league rules.
SCORING = {
    "playByPlay": "true", "fantasyPoints": "true",
    "twoPointConversions": "2", "passYards": ".04", "passAttempts": "0",
    "passTD": "4", "passCompletions": "0", "passInterceptions": "-2",
    "pointsPerReception": ".5", "carries": ".2", "rushYards": ".1",
    "rushTD": "6", "fumbles": "-2", "receivingYards": ".1",
    "receivingTD": "6", "targets": "0", "defTD": "6", "fgMade": "3",
    "fgMissed": "-3", "xpMade": "1", "xpMissed": "-1",
    "idpTotalTackles": "0", "idpSoloTackles": "0", "idpTFL": "0",
    "idpQbHits": "0", "idpInt": "0", "idpSacks": "0",
    "idpPassDeflections": "0", "idpFumblesRecovered": "0",
}


def load_key():
    key = os.environ.get("TANK01_API_KEY", "").strip()
    if key:
        return key
    try:
        for line in SECRET_FILE.read_text().splitlines():
            name, _, value = line.partition("=")
            if name.strip() == "TANK01_API_KEY":
                return value.strip()
    except FileNotFoundError:
        pass
    return ""


def upstream_url(target):
    parsed = urlsplit(target)
    query = parse_qs(parsed.query)
    if parsed.path == "/api/tank01/boxscore":
        game = query.get("gameID", [""])[0]
        if not re.fullmatch(r"\d{8}_[A-Z0-9]+@[A-Z0-9]+", game):
            raise ValueError("Provide gameID in YYYYMMDD_AWAY@HOME format.")
        params = {"gameID": game, **SCORING}
        endpoint = "getNFLBoxScore"
    elif parsed.path == "/api/tank01/games":
        date = query.get("gameDate", [""])[0]
        if not re.fullmatch(r"\d{8}", date):
            raise ValueError("Provide gameDate in YYYYMMDD format.")
        params = {"gameDate": date}
        endpoint = "getNFLGamesForDate"
    else:
        raise LookupError("Unknown endpoint.")
    return "https://" + HOST + "/" + endpoint + "?" + urlencode(params)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        # Do not log request URLs, headers, or provider payloads.
        pass

    def reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"ok": True, "tank01_configured": bool(load_key())})
            return
        try:
            url = upstream_url(self.path)
        except ValueError as error:
            self.reply(400, {"error": str(error)})
            return
        except LookupError:
            self.reply(404, {"error": "Unknown endpoint."})
            return
        key = load_key()
        if not key:
            self.reply(503, {"error": "Tank01 API key is not configured on the backend."})
            return
        request = Request(url, headers={
            "X-RapidAPI-Host": HOST, "X-RapidAPI-Key": key,
            "Accept": "application/json",
        })
        try:
            with urlopen(request, timeout=20) as response:
                result = json.load(response)
            self.reply(200, result)
        except HTTPError as error:
            # Never forward provider error bodies, which may contain credentials.
            status = error.code if error.code in (401, 403, 429) else 502
            self.reply(status, {"error": "Tank01 request failed.", "upstream_status": error.code})
        except (URLError, TimeoutError, OSError, ValueError):
            self.reply(502, {"error": "Could not retrieve Tank01 data."})


if __name__ == "__main__":
    # Local testing only. Do not expose this server publicly without authentication.
    server = ThreadingHTTPServer(("127.0.0.1", 8787), Handler)
    print("Tank01 backend: http://127.0.0.1:8787 (local only)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
