import copy
import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import urlopen
from http.server import ThreadingHTTPServer

from feed_service import Collector, ProviderError, Store, ownership_map, name_key, sleeper_point_map
from server import handler_for


class FakeProvider:
    def __init__(self):
        self.calls = 0
        self.box_calls = []
        self.fail = None
        self.games = [
            {'gameID': '20261116_A@B', 'gameStatusCode': '1'},
            {'gameID': '20261116_C@D', 'gameStatusCode': '0'},
            {'gameID': '20261116_E@F', 'gameStatusCode': '2'},
            {'gameID': '20261116_G@H', 'gameStatusCode': '4'},
        ]
        self.body = {'gameID': '20261116_A@B', 'gameStatusCode': '1', 'allPlayByPlay': [
            {'play': 'First play', 'playerStats': {}}, {'play': 'Second play', 'playerStats': {}}]}

    def player_index(self):
        return {'players': {'123': 's1'}, 'positions': {'123': 'RB'}}

    def scoring(self, catalog):
        return {'league_name': 'Test League', 'settings': {'rec': 1}, 'ownership': {}, 'week': 10, 'season': '2026',
                'known_player_ids': list(catalog['players']), 'positions': catalog['positions']}

    def matchup_points(self, week):
        return [{'players_points': {'s1': 12.34}}]

    def fetch(self, endpoint, **params):
        self.calls += 1
        if endpoint == 'getNFLGamesForDate':
            return copy.deepcopy(self.games)
        self.box_calls.append(params['gameID'])
        if self.fail:
            raise ProviderError(self.fail)
        return copy.deepcopy(self.body)


class SharedFeedChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'feed.sqlite'
        self.store = Store(self.path)
        self.now = 1794873600.0
        self.provider = FakeProvider()
        self.collector = Collector(self.store, self.provider, clock=lambda: self.now)

    def tearDown(self):
        self.temp.cleanup()

    def test_only_active_games_poll_and_stop_at_final(self):
        self.collector.tick()
        self.assertEqual(self.provider.box_calls, ['20261116_A@B'])
        self.now += 5
        self.provider.body['gameStatusCode'] = '2'
        self.collector.tick()
        self.now += 60
        self.collector.tick()
        self.assertEqual(len(self.provider.box_calls), 2)
        self.assertFalse(self.store.feed(self.now)['games'][0]['active'])

    def test_one_second_cadence_and_single_poll_for_any_number_of_readers(self):
        self.collector.tick()
        for _ in range(100):
            self.assertEqual(len(self.store.feed(self.now)['games']), 1)
        self.assertEqual(len(self.provider.box_calls), 1)
        self.now += 0.5
        self.collector.tick()
        self.assertEqual(len(self.provider.box_calls), 1)
        self.now += 0.5
        self.collector.tick()
        self.assertEqual(len(self.provider.box_calls), 2)

    def test_snapshots_survive_restart_and_corrected_plays_keep_identity(self):
        self.collector.tick()
        before = self.store.feed(self.now)['games'][0]
        self.now += 5
        self.provider.body['allPlayByPlay'][0]['play'] = 'Corrected first play'
        self.provider.body['allPlayByPlay'].pop()
        self.collector.tick()
        after = Store(self.path).feed(self.now)['games'][0]
        self.assertEqual(after['play_sequences']['0'], before['play_sequences']['0'])
        self.assertNotIn('1', after['play_sequences'])
        self.assertEqual(after['body']['allPlayByPlay'][0]['play'], 'Corrected first play')

    def test_second_collector_cannot_duplicate_requests(self):
        self.collector.tick()
        other = FakeProvider()
        Collector(self.store, other, clock=lambda: self.now).tick()
        self.assertEqual(other.calls, 0)

    def test_rate_limit_backoff_preserves_cached_feed(self):
        self.collector.tick()
        self.provider.fail = 429
        self.now += 5
        self.collector.tick()
        calls = len(self.provider.box_calls)
        self.now += 5
        self.collector.tick()
        self.assertEqual(len(self.provider.box_calls), calls)
        self.assertEqual(len(self.store.feed(self.now)['games']), 1)
        self.assertIn('429', self.store.feed(self.now)['collector']['error'])

    def test_final_discovery_fetches_final_snapshot_once(self):
        self.collector.tick()
        self.provider.games[0]['gameStatusCode'] = '2'
        self.provider.body['gameStatusCode'] = '2'
        self.now += 60
        self.collector.tick()
        self.assertEqual(len(self.provider.box_calls), 2)
        self.now += 60
        self.collector.tick()
        self.assertEqual(len(self.provider.box_calls), 2)

    def test_owned_starters_bench_and_coowners_are_mapped_by_espn_id(self):
        users = [{'user_id': 'u1', 'display_name': 'Ron', 'metadata': {'team_name': 'Team Ron'}},
                 {'user_id': 'u2', 'display_name': 'Co-owner'}]
        rosters = [{'owner_id': 'u1', 'co_owners': ['u2'], 'players': ['s1', 's2'], 'starters': ['s1']}]
        result = ownership_map(users, rosters, {'123': 's1', '456': 's2', '789': 'unowned'})
        self.assertTrue(result['123']['starter'])
        self.assertFalse(result['456']['starter'])
        self.assertEqual(result['123']['team_name'], 'Team Ron')
        self.assertEqual(result['456']['owner_name'], 'Ron & Co-owner')
        self.assertNotIn('789', result)

    def test_request_latency_does_not_delay_next_poll_tick(self):
        self.store.discover(self.provider.games)
        self.store.save('20261116_A@B', self.provider.body, self.now + 0.2, next_poll=self.now + 1)
        self.assertEqual(self.store.candidates(self.now + 0.5), [])
        self.assertEqual(self.store.candidates(self.now + 1), ['20261116_A@B'])

    def test_schedule_can_lag_live_boxscore_after_kickoff(self):
        self.provider.games[0]['gameStatusCode'] = '0'
        self.provider.games[0]['gameTime_epoch'] = str(self.now - 3600)
        self.collector.tick()
        self.assertEqual(self.provider.box_calls, ['20261116_A@B'])
        self.assertTrue(self.store.feed(self.now)['games'][0]['active'])
        self.now += 60
        self.collector.tick()  # Discovery still says scheduled; live box score wins.
        self.assertEqual(len(self.provider.box_calls), 2)
        self.assertTrue(self.store.feed(self.now)['games'][0]['active'])

    def test_scheduled_probe_backs_off_and_does_not_poll_future_games(self):
        self.provider.games[0]['gameStatusCode'] = '0'
        self.provider.games[0]['gameTime_epoch'] = str(self.now + 100)
        self.collector.tick()
        self.assertEqual(self.provider.box_calls, [])
        self.now += 100
        self.provider.body['gameStatusCode'] = '0'
        self.collector.tick()
        self.assertEqual(len(self.provider.box_calls), 1)
        self.now += 5
        self.collector.tick()
        self.assertEqual(len(self.provider.box_calls), 1)
        self.now += 25
        self.collector.tick()
        self.assertEqual(len(self.provider.box_calls), 2)

    def test_name_fallback_normalizes_suffix_and_team_aliases(self):
        self.assertEqual(name_key('Brian Robinson Jr.', 'WAS'), name_key('Brian Robinson', 'WSH'))
        self.assertIsNone(name_key('Unknown Player', None))

    def test_sleeper_totals_preserve_zero_negative_bench_and_missing_values(self):
        scores = sleeper_point_map([{'players_points': {'s1': 0, 's2': -1.5, 'bench': 12.34},
                                    'starters': ['s1', 'other'], 'starters_points': [99, 2.2]}],
                                   {'p1': 's1', 'p2': 's2', 'p3': 'bench', 'p4': 'missing', 'p5': 'other'})
        self.assertEqual(scores, {'p1': 0, 'p2': -1.5, 'p3': 12.34, 'p5': 2.2})

    def test_shared_feed_uses_sleeper_player_score_without_recalculation(self):
        self.collector.tick()
        context = self.store.feed(self.now)['scoring']
        self.assertEqual(context['sleeper_points']['123'], 12.34)
        self.assertEqual(context['week'], 10)
        self.assertEqual(context['season'], '2026')
        self.assertIsNotNone(context['scores_updated_at'])

    def test_sleeper_scores_still_refresh_during_tank01_pause(self):
        self.collector.tick()
        self.provider.fail = 429
        self.now += 5
        self.collector.tick()
        self.now += 5
        calls = len(self.provider.box_calls)
        self.collector.tick()
        self.assertEqual(len(self.provider.box_calls), calls)
        self.assertEqual(self.store.feed(self.now)['scoring']['scores_updated_at'], self.now)

    def test_http_feed_reads_do_not_call_upstream(self):
        self.collector.tick()
        count = self.provider.calls
        http = ThreadingHTTPServer(('127.0.0.1', 0), handler_for(self.store))
        thread = threading.Thread(target=http.serve_forever, daemon=True)
        thread.start()
        try:
            for _ in range(3):
                with urlopen('http://127.0.0.1:%d/api/feed' % http.server_port) as response:
                    body = json.load(response)
                    self.assertIn('scoring', body)
            self.assertEqual(self.provider.calls, count)
            with self.assertRaises(HTTPError) as error:
                urlopen('http://127.0.0.1:%d/api/tank01/boxscore?gameID=x' % http.server_port)
            self.assertEqual(error.exception.code, 404)
        finally:
            http.shutdown()
            http.server_close()
            thread.join()


if __name__ == '__main__':
    unittest.main()
