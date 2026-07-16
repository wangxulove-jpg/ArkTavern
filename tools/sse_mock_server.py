#!/usr/bin/env python3
"""
SSE Mock Server for ArkTavern T-0.3B PoC and T-1.4 device tests

Development-only test server. Not a HAP runtime dependency.
Only uses Python standard library.

Usage:
  python tools/sse_mock_server.py [--host HOST] [--port PORT]

Defaults: host=0.0.0.0, port=8765

Endpoints:
  GET  /sse                          - SSE streaming (existing, T-0.3B)
  GET  /health                       - Health check (existing)
  POST /v1/chat/completions          - Non-streaming Chat Completions (T-1.4)
  POST /v1/chat/completions?scenario=<name>
    scenarios:
      - default: 200 standard response
      - 401: authentication error
      - 403: forbidden
      - 400: bad request
      - 404: not found
      - 408: timeout
      - 429: rate limit
      - 500: server error
      - 503: server error
      - invalid-json: 200 with non-JSON body
      - empty-choices: 200 with empty choices array
      - missing-content: 200 with choices missing content field
      - null-content: 200 with choices content=null
      - error-in-2xx: 200 with error body
      - slow: delayed 200 response
      - usage: 200 with full usage statistics
      - long-reply: 200 with very long content
"""

import argparse
import http.server
import json
import time
import threading
from urllib.parse import urlparse, parse_qs


# ===== Response builders =====

def build_success_response(content='Hello from mock server',
                            finish_reason='stop',
                            model='gpt-4-test',
                            id='chatcmpl-mock-001',
                            usage=None):
    """Build a standard OpenAI Chat Completions success response body."""
    body = {
        'id': id,
        'model': model,
        'choices': [
            {
                'index': 0,
                'message': {
                    'role': 'assistant',
                    'content': content
                },
                'finish_reason': finish_reason
            }
        ]
    }
    if usage is not None:
        body['usage'] = usage
    return json.dumps(body)


def build_error_response(message, type=None, code=None):
    """Build an OpenAI-style error response body."""
    err = {'message': message}
    if type is not None:
        err['type'] = type
    if code is not None:
        err['code'] = code
    return json.dumps({'error': err})


# ===== Scenario map =====

def get_scenario_response(scenario, request_body=None):
    """Return (status_code, headers_dict, body_string) for a scenario."""
    if scenario in ('401',):
        return (401, {'Content-Type': 'application/json'},
                build_error_response('Invalid API key', 'invalid_request_error', 'invalid_api_key'))
    if scenario == '403':
        return (403, {'Content-Type': 'application/json'},
                build_error_response('Forbidden', 'forbidden'))
    if scenario == '400':
        return (400, {'Content-Type': 'application/json'},
                build_error_response('Bad request', 'invalid_request_error'))
    if scenario == '404':
        return (404, {'Content-Type': 'application/json'},
                build_error_response('Not found'))
    if scenario == '408':
        return (408, {'Content-Type': 'application/json'},
                build_error_response('Request timeout'))
    if scenario == '429':
        return (429, {'Content-Type': 'application/json'},
                build_error_response('Rate limit exceeded', 'rate_limit_error'))
    if scenario in ('500',):
        return (500, {'Content-Type': 'application/json'},
                build_error_response('Internal server error'))
    if scenario == '503':
        return (503, {'Content-Type': 'application/json'},
                build_error_response('Service unavailable'))
    if scenario in ('invalid-json', 'invalid'):
        return (200, {'Content-Type': 'text/plain'}, 'This is not JSON')
    if scenario in ('empty-choices', 'empty'):
        return (200, {'Content-Type': 'application/json'},
                json.dumps({'id': 'x', 'model': 'm', 'choices': []}))
    if scenario in ('missing-content', 'missing'):
        return (200, {'Content-Type': 'application/json'},
                json.dumps({'id': 'x', 'model': 'm', 'choices': [
                    {'index': 0, 'message': {'role': 'assistant'}, 'finish_reason': 'stop'}
                ]}))
    if scenario in ('null-content', 'null'):
        return (200, {'Content-Type': 'application/json'},
                json.dumps({'id': 'x', 'model': 'm', 'choices': [
                    {'index': 0, 'message': {'role': 'assistant', 'content': None}, 'finish_reason': 'stop'}
                ]}))
    if scenario in ('error-in-2xx', 'error2xx'):
        return (200, {'Content-Type': 'application/json'},
                build_error_response('Something went wrong in 2xx response'))
    if scenario == 'usage':
        return (200, {'Content-Type': 'application/json'},
                build_success_response(content='ok', usage={
                    'prompt_tokens': 10,
                    'completion_tokens': 5,
                    'total_tokens': 15
                }))
    if scenario in ('long-reply', 'long'):
        return (200, {'Content-Type': 'application/json'},
                build_success_response(content='A' * 5000))
    if scenario == 'slow':
        # Delayed response (but doesn't sleep here; sleeping handled in handler)
        return (200, {'Content-Type': 'application/json'},
                build_success_response(content='slow response'))
    # Default: standard success
    return (200, {'Content-Type': 'application/json'},
            build_success_response())


class SSEHandler(http.server.BaseHTTPRequestHandler):
    """Handles /sse path with streaming SSE response and /v1/chat/completions for non-streaming."""

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
        elif self.path.startswith('/v1/chat/completions'):
            self._handle_chat_completions()
        else:
            self.send_error(404, 'Not Found')

    def _handle_mock_scenario_path(self):
        """Handle scenario via path: POST /v1/mock/<scenario> returns the scenario response."""
        # Parse path
        parsed = urlparse(self.path)
        parts = parsed.path.split('/')
        # Expected: ['', 'v1', 'mock', '<scenario>']
        scenario = 'default'
        if len(parts) >= 4:
            scenario = parts[3]
        # Read request body (discard)
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            try:
                self.rfile.read(content_length)
            except Exception:
                pass
        if scenario == 'slow':
            time.sleep(2.0)
        status_code, headers, body = get_scenario_response(scenario)
        self.send_response(status_code)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body.encode('utf-8'))
        except (BrokenPipeError, ConnectionResetError):
            pass

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

    def _handle_chat_completions(self):
        """Handle non-streaming Chat Completions requests."""
        # Read request body
        content_length: int = int(self.headers.get('Content-Length', 0))
        # Do not print request body (security)
        request_body_str = ''
        if content_length > 0:
            try:
                request_body_str = self.rfile.read(content_length).decode('utf-8')
            except Exception:
                pass

        # Parse scenario from query string OR X-Mock-Scenario header OR model name
        parsed = urlparse(self.path)
        query_params = parse_qs(parsed.query)
        scenario: str = 'default'
        if 'scenario' in query_params:
            scenario = query_params['scenario'][0]
        elif 'X-Mock-Scenario' in self.headers:
            scenario = self.headers['X-Mock-Scenario']
        else:
            # Parse model from request body; if model starts with 'mock-<scenario>-', use that scenario
            try:
                req_json = json.loads(request_body_str)
                model = req_json.get('model', '')
                if isinstance(model, str) and model.startswith('mock-'):
                    # Format: mock-<scenario>-model
                    parts = model.split('-')
                    if len(parts) >= 2:
                        candidate = parts[1]
                        # Only accept known scenarios
                        known = ['401', '403', '400', '404', '408', '429', '500', '503',
                                 'invalid', 'empty', 'missing', 'null', 'error2xx', 'usage', 'long', 'slow']
                        if candidate in known:
                            scenario = candidate
            except Exception:
                pass

        # Handle slow scenario (sleep before responding)
        if scenario == 'slow':
            time.sleep(2.0)

        status_code, headers, body = get_scenario_response(scenario)

        self.send_response(status_code)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body.encode('utf-8'))
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        """Override to reduce noise. Do not log Authorization."""
        # Only log method and path, never log headers
        print(f'[SSE Mock] {args[0] if args else ""}')

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
    parser = argparse.ArgumentParser(description='SSE Mock Server for ArkTavern PoC and T-1.4 tests')
    parser.add_argument('--host', default='0.0.0.0', help='Listen address')
    parser.add_argument('--port', type=int, default=8765, help='Listen port')
    args = parser.parse_args()

    server = ThreadedHTTPServer((args.host, args.port), SSEHandler)
    print(f'[SSE Mock] Server running on http://{args.host}:{args.port}')
    print(f'[SSE Mock] SSE endpoint: http://{args.host}:{args.port}/sse')
    print(f'[SSE Mock] Chat Completions: http://{args.host}:{args.port}/v1/chat/completions')
    print(f'[SSE Mock] Health check: http://{args.host}:{args.port}/health')
    print(f'[SSE Mock] Scenarios: ?scenario=<401|403|400|404|408|429|500|503|invalid-json|empty-choices|missing-content|null-content|error-in-2xx|usage|long-reply|slow>')
    print('[SSE Mock] Press Ctrl+C to stop')

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n[SSE Mock] Shutting down...')
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
