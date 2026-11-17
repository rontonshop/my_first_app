"""Read-only shared feed API. Client requests never call Tank01."""
import json
import os
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from feed_service import Collector, Provider, Store, load_key


def handler_for(store):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            path = urlsplit(self.path).path
            if path == '/health':
                payload = {'ok': True, 'tank01_configured': bool(load_key()), 'collector': store.meta('collector')}
                status = 200
            elif path == '/api/feed':
                payload, status = store.feed(), 200
            else:
                payload, status = {'error': 'Unknown endpoint.'}, 404
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
    return Handler


def main():
    default_path = Path.home() / '.local/share/my_first_app/feed.sqlite'
    store = Store(os.environ.get('FEED_DB_PATH', str(default_path)))
    collector = Collector(store, Provider())
    server = ThreadingHTTPServer((os.environ.get('BIND_HOST', '127.0.0.1'), int(os.environ.get('PORT', '8787'))), handler_for(store))
    thread = threading.Thread(target=collector.run, name='tank01-collector', daemon=True)
    thread.start()

    def stop(*_args):
        collector.stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print('Shared feed service running on port %s; upstream polling is centralized.' % server.server_port, flush=True)
    try:
        server.serve_forever()
    finally:
        collector.stop.set()
        thread.join(timeout=30)
        server.server_close()


if __name__ == '__main__':
    main()
