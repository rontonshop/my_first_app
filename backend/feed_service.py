"""One shared Tank01 collector, durable SQLite snapshots, read-only client API."""
import json
import os
import sqlite3
import subprocess
import threading
import time
import uuid
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

HOST = 'tank01-nfl-live-in-game-real-time-statistics-nfl.p.rapidapi.com'
LEAGUE_ID = '1399979975465041920'
POLL_SECONDS = 5
DISCOVERY_SECONDS = 60


def load_key():
    key = os.environ.get('TANK01_API_KEY', '').strip()
    if key:
        return key
    try:
        for line in (Path.home() / '.config/my_first_app/tank01.env').read_text().splitlines():
            name, _, value = line.partition('=')
            if name.strip() == 'TANK01_API_KEY':
                return value.strip()
    except FileNotFoundError:
        pass
    return ''


class ProviderError(Exception):
    def __init__(self, status=502):
        self.status = status
        super().__init__('Provider request failed (HTTP %s).' % status)


class Provider:
    def __init__(self, key_loader=load_key):
        self.key_loader = key_loader
        self.calls = 0
        self.lock = threading.Lock()

    def fetch(self, endpoint, **params):
        key = self.key_loader()
        if not key:
            raise ProviderError(401)
        with self.lock:
            self.calls += 1
        url = 'https://' + HOST + '/' + endpoint + '?' + urlencode(params)
        # Credentials go through stdin, never argv, files, logs, or client responses.
        config = 'url = ' + json.dumps(url) + '\nheader = ' + json.dumps('X-RapidAPI-Key: ' + key) + '\nheader = ' + json.dumps('X-RapidAPI-Host: ' + HOST) + '\n'
        process = subprocess.run(['curl', '--silent', '--max-time', '20', '--write-out', '\n%{http_code}', '--config', '-'],
                                 input=config, text=True, capture_output=True, timeout=25)
        if process.returncode:
            raise ProviderError()
        try:
            payload, status = process.stdout.rsplit('\n', 1)
            code = int(status)
            if code != 200:
                raise ProviderError(code)
            value = json.loads(payload)
            if value.get('error') or str(value.get('statusCode', 200)) != '200':
                raise ProviderError()
            return value['body']
        except (ValueError, KeyError):
            raise ProviderError() from None

    def sleeper(self, path):
        process = subprocess.run(['curl', '--silent', '--fail', '--max-time', '20',
                                  'https://api.sleeper.app/v1/' + path], capture_output=True, text=True, timeout=25)
        if process.returncode:
            raise ProviderError()
        try:
            return json.loads(process.stdout)
        except ValueError:
            raise ProviderError() from None

    def player_index(self):
        directory = self.sleeper('players/nfl')
        index = {str(p['espn_id']): sleeper_id for sleeper_id, p in directory.items() if p.get('espn_id')}
        names = {}
        for sleeper_id, player in directory.items():
            name = player.get('full_name') or ' '.join(filter(None, [player.get('first_name'), player.get('last_name')]))
            key = name_key(name, player.get('team'))
            if key:
                names.setdefault(key, set()).add(sleeper_id)
        index.update({key: next(iter(ids)) for key, ids in names.items() if len(ids) == 1})
        positions = {key: directory[sleeper_id]['position'] for key, sleeper_id in index.items()
                     if directory[sleeper_id].get('position')}
        return {'players': index, 'positions': positions}

    def scoring(self, catalog):
        player_index = catalog['players']
        league = self.sleeper('league/' + LEAGUE_ID)
        users = self.sleeper('league/' + LEAGUE_ID + '/users')
        rosters = self.sleeper('league/' + LEAGUE_ID + '/rosters')
        return {'league_name': league['name'], 'settings': league['scoring_settings'],
                'ownership': ownership_map(users, rosters, player_index),
                'known_player_ids': list(player_index), 'positions': catalog.get('positions', {}), 'updated_at': time.time()}


def name_key(name, team):
    if not name or not team:
        return None
    words = name.lower().replace('.', '').split()
    while words and words[-1] in ('jr', 'sr', 'ii', 'iii', 'iv'):
        words.pop()
    normalized = ''.join(char for char in ' '.join(words) if char.isalnum())
    team = {'WAS': 'WSH', 'JAC': 'JAX'}.get(team.upper(), team.upper())
    return 'name:' + normalized + '|' + team


def ownership_map(users, rosters, player_index):
    members = {user['user_id']: user for user in users}
    by_sleeper = {}
    for roster in rosters:
        owner = members.get(roster.get('owner_id'), {})
        owner_name = owner.get('display_name', 'Unassigned owner')
        team_name = (owner.get('metadata') or {}).get('team_name') or owner_name
        co_names = [members.get(user_id, {}).get('display_name', user_id) for user_id in roster.get('co_owners') or []]
        for player in roster.get('players') or []:
            by_sleeper[player] = {'team_name': team_name, 'owner_name': ' & '.join([owner_name] + co_names),
                                  'starter': player in (roster.get('starters') or [])}
    return {provider_id: by_sleeper[sleeper_id] for provider_id, sleeper_id in player_index.items() if sleeper_id in by_sleeper}


def game_records(body):
    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        return [dict(value, gameID=value.get('gameID', key)) for key, value in body.items() if isinstance(value, dict)]
    return []


def status_code(game):
    code = str(game.get('gameStatusCode', ''))
    if code in ('0', '1', '2', '3', '4'):
        return code
    text = str(game.get('gameStatus', '')).lower()
    if 'final' in text or 'completed' in text:
        return '2'
    if 'in progress' in text or 'halftime' in text or 'end game cleanup' in text:
        return '1'
    return '0'


def play_records(body):
    plays = body.get('allPlayByPlay', body.get('playByPlay', []))
    if isinstance(plays, list):
        return [(str(play.get('playID', i)), play) for i, play in enumerate(plays) if isinstance(play, dict)]
    if isinstance(plays, dict):
        return [(str(play.get('playID', key)), play) for key, play in plays.items() if isinstance(play, dict)]
    return []


class Store:
    def __init__(self, path):
        self.path = str(path)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript('''
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS games (
                    id TEXT PRIMARY KEY, schedule TEXT NOT NULL, status TEXT NOT NULL,
                    body TEXT, updated REAL, finalized INTEGER NOT NULL DEFAULT 0,
                    next_poll REAL NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS plays (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, game_id TEXT NOT NULL,
                    play_key TEXT NOT NULL, content TEXT NOT NULL,
                    UNIQUE(game_id, play_key));
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS leases (name TEXT PRIMARY KEY, owner TEXT NOT NULL, expires REAL NOT NULL);
            ''')

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def lease(self, owner, now):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute("SELECT * FROM leases WHERE name='collector'").fetchone()
            if row and row['owner'] != owner and row['expires'] > now:
                return False
            db.execute("INSERT INTO leases VALUES ('collector',?,?) ON CONFLICT(name) DO UPDATE SET owner=excluded.owner, expires=excluded.expires", (owner, now + 120))
            return True

    def release(self, owner):
        with self.connect() as db:
            db.execute("DELETE FROM leases WHERE name='collector' AND owner=?", (owner,))

    def meta(self, key, value=None):
        with self.connect() as db:
            if value is not None:
                db.execute('INSERT INTO metadata VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', (key, json.dumps(value)))
                return value
            row = db.execute('SELECT value FROM metadata WHERE key=?', (key,)).fetchone()
            return json.loads(row['value']) if row else None

    def discover(self, games):
        with self.connect() as db:
            for game in games:
                game_id = game.get('gameID', '')
                if not game_id:
                    continue
                db.execute('''INSERT INTO games (id,schedule,status) VALUES (?,?,?)
                    ON CONFLICT(id) DO UPDATE SET schedule=excluded.schedule,
                    status=CASE WHEN games.finalized=1 THEN '2' WHEN games.status='1' AND excluded.status='0' THEN '1' ELSE excluded.status END''',
                    (game_id, json.dumps(game), status_code(game)))

    def candidates(self, now):
        with self.connect() as db:
            rows = db.execute("SELECT * FROM games WHERE finalized=0 AND next_poll<=? ORDER BY id", (now,)).fetchall()
        result = []
        for row in rows:
            if row['status'] == '1' or (row['status'] == '2' and row['body'] is not None):
                result.append(row['id'])
            elif row['status'] == '0':
                # Schedule status can lag behind kickoff. Probe box scores after the
                # scheduled start; a live box score becomes the authority thereafter.
                schedule = json.loads(row['schedule'])
                try:
                    kickoff = float(schedule.get('gameTime_epoch', 0))
                except (TypeError, ValueError):
                    kickoff = 0
                if kickoff and kickoff <= now <= kickoff + 12 * 3600:
                    result.append(row['id'])
        return result

    def save(self, game_id, body, now, next_poll=None):
        records = play_records(body)
        code = status_code(body)
        with self.connect() as db:
            db.execute('''UPDATE games SET body=?,status=?,updated=?,finalized=?,next_poll=?,failures=0 WHERE id=?''',
                       (json.dumps(body), code, now, int(code == '2'), next_poll if next_poll is not None else now + POLL_SECONDS, game_id))
            keep = set()
            for key, play in records:
                keep.add(key)
                content = json.dumps(play, sort_keys=True)
                db.execute('''INSERT INTO plays (game_id,play_key,content) VALUES (?,?,?)
                    ON CONFLICT(game_id,play_key) DO UPDATE SET content=excluded.content''', (game_id, key, content))
            for row in db.execute('SELECT play_key FROM plays WHERE game_id=?', (game_id,)):
                if row['play_key'] not in keep:
                    db.execute('DELETE FROM plays WHERE game_id=? AND play_key=?', (game_id, row['play_key']))

    def failed(self, game_id, now):
        with self.connect() as db:
            row = db.execute('SELECT failures FROM games WHERE id=?', (game_id,)).fetchone()
            failures = (row['failures'] if row else 0) + 1
            db.execute('UPDATE games SET failures=?,next_poll=? WHERE id=?',
                       (failures, now + min(300, 5 * 2 ** min(failures, 6)), game_id))

    def feed(self, now=None):
        now = time.time() if now is None else now
        with self.connect() as db:
            # A single read transaction keeps game snapshots and sequence maps consistent.
            db.execute('BEGIN')
            rows = db.execute('SELECT * FROM games WHERE body IS NOT NULL AND updated>=? ORDER BY id', (now - 86400,)).fetchall()
            games = []
            for row in rows:
                seqs = {p['play_key']: p['sequence'] for p in db.execute('SELECT play_key,sequence FROM plays WHERE game_id=?', (row['id'],))}
                games.append({'id': row['id'], 'body': json.loads(row['body']), 'updated_at': row['updated'],
                              'active': row['status'] == '1', 'play_sequences': seqs})
        return {'games': games, 'scoring': self.meta('scoring'), 'collector': self.meta('collector'),
                'served_at': now, 'refresh_seconds': POLL_SECONDS}


class Collector:
    def __init__(self, store, provider, clock=time.time):
        self.store, self.provider, self.clock = store, provider, clock
        self.owner = str(uuid.uuid4())
        self.next_discovery = 0
        self.next_scoring = 0
        self.pause_until = 0
        self.stop = threading.Event()
        self.error = None

    def tick(self):
        now = self.clock()
        if not self.store.lease(self.owner, now):
            return
        if now < self.pause_until:
            return
        self.error = None
        if now >= self.next_scoring:
            try:
                index = self.store.meta('player_index')
                if not index or index.get('version') != 3 or now - index['updated_at'] >= 86400:
                    index = {'version': 3, 'updated_at': now, **self.provider.player_index()}
                    self.store.meta('player_index', index)
                self.store.meta('scoring', self.provider.scoring(index))
                self.next_scoring = now + 60
            except (ProviderError, subprocess.TimeoutExpired):
                self.next_scoring = now + 60
                self.error = 'League scoring could not be refreshed.'
        if now >= self.next_discovery:
            try:
                today = datetime.fromtimestamp(now, ZoneInfo('America/New_York')).date()
                for date in (today - timedelta(days=1), today):
                    body = self.provider.fetch('getNFLGamesForDate', gameDate=date.strftime('%Y%m%d'))
                    self.store.discover(game_records(body))
                self.next_discovery = now + DISCOVERY_SECONDS
            except (ProviderError, subprocess.TimeoutExpired) as error:
                self.handle_error(error, now)
                self.next_discovery = now + 60
        if now >= self.pause_until:
            # Bounded parallel requests keep one slow game from delaying every other game.
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(self.poll_game, self.store.candidates(now)))
        self.store.meta('collector', {'last_tick': self.clock(), 'error': self.error,
                                     'paused_until': self.pause_until, 'provider_requests': self.provider.calls})

    def handle_error(self, error, now):
        status = getattr(error, 'status', 502)
        self.error = 'Tank01 request failed (HTTP %s). Retrying with backoff.' % status
        if status in (401, 403):
            self.pause_until = max(self.pause_until, now + 300)
        elif status == 429:
            self.pause_until = max(self.pause_until, now + 60)

    def poll_game(self, game_id):
        started = self.clock()
        if started < self.pause_until:
            return
        try:
            body = self.provider.fetch('getNFLBoxScore', gameID=game_id, playByPlay='true')
            if not isinstance(body, dict) or body.get('gameID', game_id) != game_id:
                raise ProviderError()
            interval = POLL_SECONDS if status_code(body) == '1' else 30
            self.store.save(game_id, body, self.clock(), next_poll=started + interval)
        except (ProviderError, subprocess.TimeoutExpired) as error:
            self.store.failed(game_id, self.clock())
            self.handle_error(error, self.clock())

    def run(self):
        try:
            while not self.stop.is_set():
                start = self.clock()
                try:
                    self.tick()
                except Exception:
                    self.store.meta('collector', {'last_tick': self.clock(), 'error': 'Collector error; retrying.', 'paused_until': 0})
                self.stop.wait(max(0.1, POLL_SECONDS - (self.clock() - start)))
        finally:
            self.store.release(self.owner)
