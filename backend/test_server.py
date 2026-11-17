import os
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import server


class BackendChecks(unittest.TestCase):
    def test_boxscore_preserves_requested_scoring_and_encodes_game(self):
        url = server.upstream_url("/api/tank01/boxscore?gameID=20241020_CAR%40WSH")
        parts = urlsplit(url)
        self.assertEqual(parts.hostname, server.HOST)
        query = parse_qs(parts.query)
        self.assertEqual(query["gameID"], ["20241020_CAR@WSH"])
        self.assertEqual(query["pointsPerReception"], [".5"])
        self.assertEqual(query["carries"], [".2"])
        self.assertEqual(query["passInterceptions"], ["-2"])
        self.assertEqual(query["playByPlay"], ["true"])
        self.assertNotIn("key", url.lower())

    def test_cannot_redirect_proxy_to_another_host(self):
        with self.assertRaises(ValueError):
            server.upstream_url("/api/tank01/boxscore?gameID=https://example.com")
        with self.assertRaises(LookupError):
            server.upstream_url("/arbitrary-route")

    def test_games_requires_date(self):
        with self.assertRaises(ValueError):
            server.upstream_url("/api/tank01/games")
        self.assertIn("gameDate=20241020", server.upstream_url("/api/tank01/games?gameDate=20241020"))

    def test_environment_key_overrides_local_secret_file(self):
        with patch.dict(os.environ, {"TANK01_API_KEY": "test-placeholder"}):
            self.assertEqual(server.load_key(), "test-placeholder")


if __name__ == "__main__":
    unittest.main()
