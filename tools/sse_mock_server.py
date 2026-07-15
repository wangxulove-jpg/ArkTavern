#!/usr/bin/env python3
"""
SSE Mock Server for ArkTavern T-0.3B PoC

Development-only test server. Not a HAP runtime dependency.
Only uses Python standard library.

Usage:
  python tools/sse_mock_server.py [--host HOST] [--port PORT]

Defaults: host=0.0.0.0, port=8765
"""

import argparse
import http.server
import time
import threading


class SSEHandler(http.server.BaseHTTPRequestHandler):
    """Handles /sse path with streaming SSE response."""

    def do_GET(self):
        if self.path == '/sse':
            self._handle_sse()
        elif self.path == '/health':
            self._handle_health()
        else:
            self.send_error(404, 'Not Found')

    def do_POST(self):
        # Also support POST for /sse (some AI APIs use POST)
        if self.path == '/sse':
            self._handle_sse()
        else:
            self.send_error(404, 'Not Found')

    def _handle_health(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def _handle_sse(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()

        chunks = [
            # 1. Normal data event
            'data: hello from mock server\n\n',
            # 2. Chinese content
            'data: \xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c\n\n'.decode('utf-8') if False else 'data: 你好世界\n\n',
            # 3. Emoji content
            'data: Hello 🌍🚀\n\n',
            # 4. Multi-line data
            'data: line one\ndata: line two\n\n',
            # 5. JSON string as data
            'data: {"choices":[{"delta":{"content":"hi"}}]}\n\n',
            # 6. Event with data
            'event: ping\ndata: pong\n\n',
            # 7. [DONE]
            'data: [DONE]\n\n',
        ]

        for chunk in chunks:
            # Check if client disconnected
            if self.server._shutdown_requested:
                return
            try:
                self.wfile.write(chunk.encode('utf-8'))
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            time.sleep(0.5)

    def log_message(self, format, *args):
        """Override to reduce noise."""
        print(f'[SSE Mock] {args[0]}')

    def handle(self):
        """Override to catch client disconnect."""
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


class ThreadedHTTPServer(http.server.ThreadingHTTPServer):
    """Threaded server that supports shutdown flag."""
    _shutdown_requested = False

    def shutdown(self):
        self._shutdown_requested = True
        super().shutdown()


def main():
    parser = argparse.ArgumentParser(description='SSE Mock Server for ArkTavern PoC')
    parser.add_argument('--host', default='0.0.0.0', help='Listen address')
    parser.add_argument('--port', type=int, default=8765, help='Listen port')
    args = parser.parse_args()

    server = ThreadedHTTPServer((args.host, args.port), SSEHandler)
    print(f'[SSE Mock] Server running on http://{args.host}:{args.port}')
    print(f'[SSE Mock] SSE endpoint: http://{args.host}:{args.port}/sse')
    print(f'[SSE Mock] Health check: http://{args.host}:{args.port}/health')
    print('[SSE Mock] Press Ctrl+C to stop')

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n[SSE Mock] Shutting down...')
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
