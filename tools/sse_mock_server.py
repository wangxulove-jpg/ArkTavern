#!/usr/bin/env python3
"""
SSE Mock Server for ArkTavern T-0.3B PoC, T-1.4 and T-1.5 device tests

Development-only test server. Not a HAP runtime dependency.
Only uses Python standard library.

Usage:
  python tools/sse_mock_server.py [--host HOST] [--port PORT]

Defaults: host=0.0.0.0, port=8765

Endpoints:
  GET  /sse                          - SSE streaming (existing, T-0.3B)
  GET  /health                       - Health check (existing)
  POST /v1/chat/completions          - Non-streaming Chat Completions (T-1.4)
  POST /v1/chat/completions          - Streaming Chat Completions when stream=true (T-1.5)
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

Streaming scenarios (triggered by model prefix 'mock-stream-<scenario>-*'):
  - mock-stream-normal-*      : normal streaming with [DONE]
  - mock-stream-chinese-*     : Chinese content
  - mock-stream-emoji-*       : Emoji content
  - mock-stream-multiline-*   : multi-line content (\\n)
  - mock-stream-no-done-*     : no [DONE] marker
  - mock-stream-empty-delta-* : empty content delta events
  - mock-stream-role-only-*   : role-only events (no content)
  - mock-stream-usage-*       : usage-only final event
  - mock-stream-finish-length-*: finish_reason=length
  - mock-stream-invalid-json-*: non-JSON data event
  - mock-stream-empty-choices-*: empty choices array
  - mock-stream-401-*         : 401 auth error
  - mock-stream-429-*         : 429 rate limit
  - mock-stream-500-*         : 500 server error
  - mock-stream-slow-*        : slow streaming (long delay between chunks)
  - mock-stream-abort-*       : streaming that can be aborted (long delay)
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


# ===== Non-streaming scenario map =====

def get_scenario_response(scenario, request_body=None):
    """Return (status_code, headers_dict, body_string) for a non-streaming scenario."""
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


# ===== Streaming scenario builders =====

def build_stream_delta_event(content, role=None, finish_reason=None, model='gpt-4-test',
                              id='chatcmpl-stream-001', index=0):
    """Build a single OpenAI streaming Chat Completions chunk as SSE 'data: ...' string."""
    delta = {}
    if role is not None:
        delta['role'] = role
    if content is not None:
        delta['content'] = content
    choice = {
        'index': index,
        'delta': delta,
    }
    if finish_reason is not None:
        choice['finish_reason'] = finish_reason
    body = {
        'id': id,
        'object': 'chat.completion.chunk',
        'created': 1700000000,
        'model': model,
        'choices': [choice],
    }
    return 'data: ' + json.dumps(body) + '\n\n'


def build_stream_usage_event(prompt_tokens=10, completion_tokens=5, total_tokens=15,
                              model='gpt-4-test', id='chatcmpl-stream-001'):
    """Build a usage-only final event (no choices, only usage)."""
    body = {
        'id': id,
        'object': 'chat.completion.chunk',
        'created': 1700000000,
        'model': model,
        'choices': [],
        'usage': {
            'prompt_tokens': prompt_tokens,
            'completion_tokens': completion_tokens,
            'total_tokens': total_tokens,
        },
    }
    return 'data: ' + json.dumps(body) + '\n\n'


def build_stream_done():
    """Build the [DONE] marker as SSE event."""
    return 'data: [DONE]\n\n'


def get_stream_scenario_chunks(scenario):
    """Return list of SSE chunk strings for a streaming scenario.

    Each chunk is a complete SSE event string (with trailing \\n\\n).
    The handler will write each chunk with a small delay and flush.
    Returns None if scenario is a non-streaming error (401/429/500).
    For error scenarios, returns ('error', status_code, body) tuple instead.
    """
    # Error scenarios: return special marker
    if scenario == '401':
        return ('error', 401, build_error_response('Invalid API key', 'invalid_request_error', 'invalid_api_key'))
    if scenario == '429':
        return ('error', 429, build_error_response('Rate limit exceeded', 'rate_limit_error'))
    if scenario == '500':
        return ('error', 500, build_error_response('Internal server error'))

    chunks = []

    if scenario == 'normal':
        # Normal streaming: role + 3 content deltas + finish + DONE
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content='Hello'))
        chunks.append(build_stream_delta_event(content=' from'))
        chunks.append(build_stream_delta_event(content=' stream'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_done())

    elif scenario == 'chinese':
        # Chinese content
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content='你好'))
        chunks.append(build_stream_delta_event(content='世界'))
        chunks.append(build_stream_delta_event(content='!'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_done())

    elif scenario == 'emoji':
        # Emoji content
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content='Hello '))
        chunks.append(build_stream_delta_event(content='🌍🚀'))
        chunks.append(build_stream_delta_event(content='🎉'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_done())

    elif scenario == 'multiline':
        # Multi-line content with \n
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content='Line 1\n'))
        chunks.append(build_stream_delta_event(content='Line 2\n'))
        chunks.append(build_stream_delta_event(content='Line 3'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_done())

    elif scenario == 'no-done':
        # No [DONE] marker, just finish_reason and connection end
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content='No done marker'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        # No [DONE]

    elif scenario == 'empty-delta':
        # Empty content delta events (valid but no content)
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content=''))
        chunks.append(build_stream_delta_event(content=''))
        chunks.append(build_stream_delta_event(content='after empty'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_done())

    elif scenario == 'role-only':
        # Role-only events (delta.role but no content)
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content=None))  # no content, no role
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_done())

    elif scenario == 'usage':
        # Streaming with usage in final event
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content='Hi'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_usage_event(prompt_tokens=10, completion_tokens=5, total_tokens=15))
        chunks.append(build_stream_done())

    elif scenario == 'finish-length':
        # finish_reason=length
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content='Truncated'))
        chunks.append(build_stream_delta_event(content='', finish_reason='length'))
        chunks.append(build_stream_done())

    elif scenario == 'invalid-json':
        # Non-JSON data event
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append('data: This is not JSON\n\n')
        chunks.append(build_stream_done())

    elif scenario == 'empty-choices':
        # Empty choices array
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append('data: ' + json.dumps({
            'id': 'chatcmpl-stream-001',
            'object': 'chat.completion.chunk',
            'created': 1700000000,
            'model': 'gpt-4-test',
            'choices': [],
        }) + '\n\n')
        chunks.append(build_stream_delta_event(content='after empty choices'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_done())

    elif scenario == 'slow':
        # Slow streaming: longer delay between chunks
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content='slow'))
        chunks.append(build_stream_delta_event(content=' response'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_done())

    elif scenario == 'abort':
        # Abort scenario: long delay so client can abort
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content='before abort'))
        # Long delay expected by client abort
        chunks.append(build_stream_delta_event(content='after abort'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_done())

    else:
        # Default: same as normal
        chunks.append(build_stream_delta_event(content=None, role='assistant'))
        chunks.append(build_stream_delta_event(content='Hello'))
        chunks.append(build_stream_delta_event(content=' from'))
        chunks.append(build_stream_delta_event(content=' stream'))
        chunks.append(build_stream_delta_event(content='', finish_reason='stop'))
        chunks.append(build_stream_done())

    return ('stream', chunks)


# ===== Known scenario lists =====

NON_STREAMING_SCENARIOS = ['401', '403', '400', '404', '408', '429', '500', '503',
                           'invalid', 'empty', 'missing', 'null', 'error2xx', 'usage', 'long', 'slow']

STREAM_SCENARIOS = ['normal', 'chinese', 'emoji', 'multiline', 'no-done', 'empty-delta',
                    'role-only', 'usage', 'finish-length', 'invalid-json', 'empty-choices',
                    '401', '429', '500', 'slow', 'abort']


class SSEHandler(http.server.BaseHTTPRequestHandler):
    """Handles /sse path with streaming SSE response and /v1/chat/completions for non-streaming and streaming."""

    # 使用 HTTP/1.1 以支持 chunked 传输和流式 POST 响应
    protocol_version = 'HTTP/1.1'

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
        """Handle Chat Completions requests (streaming and non-streaming)."""
        # Read request body
        content_length: int = int(self.headers.get('Content-Length', 0))
        # Do not print request body (security)
        request_body_str = ''
        if content_length > 0:
            try:
                request_body_str = self.rfile.read(content_length).decode('utf-8')
            except Exception:
                pass

        # Parse request JSON to check stream flag and model
        request_json = None
        is_stream = False
        model = ''
        try:
            request_json = json.loads(request_body_str)
            if isinstance(request_json, dict):
                is_stream = bool(request_json.get('stream', False))
                model = request_json.get('model', '')
                if not isinstance(model, str):
                    model = ''
        except Exception:
            pass

        # Determine scenario
        parsed = urlparse(self.path)
        query_params = parse_qs(parsed.query)
        scenario: str = 'default'
        stream_scenario: str = 'normal'

        if 'scenario' in query_params:
            scenario = query_params['scenario'][0]
        elif 'X-Mock-Scenario' in self.headers:
            scenario = self.headers['X-Mock-Scenario']
        elif isinstance(model, str) and model.startswith('mock-stream-'):
            # Streaming scenario: mock-stream-<scenario>-*
            # 使用前缀移除法,支持场景名含连字符(如 no-done, empty-delta, role-only, finish-length, invalid-json, empty-choices)
            suffix = model[len('mock-stream-'):]
            # 移除尾部 -<id> 部分(最后一个连字符后的内容如果像是序号)
            # 场景名为 suffix 中第一个连字符之前的部分,但如果场景名本身含连字符,
            # 需要匹配 STREAM_SCENARIOS 列表
            stream_scenario = 'normal'
            for sc in STREAM_SCENARIOS:
                if suffix == sc or suffix.startswith(sc + '-'):
                    stream_scenario = sc
                    break
        elif isinstance(model, str) and model.startswith('mock-'):
            # Non-streaming scenario: mock-<scenario>-*
            suffix = model[len('mock-'):]
            for sc in NON_STREAMING_SCENARIOS:
                if suffix == sc or suffix.startswith(sc + '-'):
                    scenario = sc
                    break

        # Route to streaming or non-streaming handler
        if is_stream:
            self._handle_streaming_response(stream_scenario)
        else:
            self._handle_non_streaming_response(scenario)

    def _handle_non_streaming_response(self, scenario: str):
        """Handle non-streaming Chat Completions response."""
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

    def _handle_streaming_response(self, scenario: str):
        """Handle streaming Chat Completions response."""
        result = get_stream_scenario_chunks(scenario)

        # Error scenario: return non-streaming error response
        if isinstance(result, tuple) and len(result) == 3 and result[0] == 'error':
            _, status_code, body = result
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body.encode('utf-8'))
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        # Streaming scenario: return SSE response
        if not (isinstance(result, tuple) and len(result) == 2 and result[0] == 'stream'):
            return
        chunks = result[1]

        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()

        # Delay between chunks: slow/abort scenarios use longer delay
        delay = 0.3
        if scenario == 'slow':
            delay = 1.5
        elif scenario == 'abort':
            delay = 2.0

        for chunk in chunks:
            if self.server._shutdown_requested:
                return
            try:
                self.wfile.write(chunk.encode('utf-8'))
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            time.sleep(delay)

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
    parser = argparse.ArgumentParser(description='SSE Mock Server for ArkTavern PoC, T-1.4 and T-1.5 tests')
    parser.add_argument('--host', default='0.0.0.0', help='Listen address')
    parser.add_argument('--port', type=int, default=8765, help='Listen port')
    args = parser.parse_args()

    server = ThreadedHTTPServer((args.host, args.port), SSEHandler)
    print(f'[SSE Mock] Server running on http://{args.host}:{args.port}')
    print(f'[SSE Mock] SSE endpoint: http://{args.host}:{args.port}/sse')
    print(f'[SSE Mock] Chat Completions: http://{args.host}:{args.port}/v1/chat/completions')
    print(f'[SSE Mock] Health check: http://{args.host}:{args.port}/health')
    print(f'[SSE Mock] Non-stream scenarios: ?scenario=<401|403|400|404|408|429|500|503|invalid-json|empty-choices|missing-content|null-content|error-in-2xx|usage|long-reply|slow>')
    print(f'[SSE Mock] Stream scenarios: model=mock-stream-<normal|chinese|emoji|multiline|no-done|empty-delta|role-only|usage|finish-length|invalid-json|empty-choices|401|429|500|slow|abort>-*')
    print('[SSE Mock] Press Ctrl+C to stop')

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n[SSE Mock] Shutting down...')
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
