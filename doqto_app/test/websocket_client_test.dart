import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/websocket_client.dart';

/// Records what the client sends; `close()` ends the inbound stream like a
/// server hang-up would.
class _FakeSink implements WebSocketSink {
  _FakeSink(this._inbound);
  final StreamController<dynamic> _inbound;
  final List<Map<String, dynamic>> sent = [];
  bool closed = false;

  @override
  void add(dynamic event) =>
      sent.add(jsonDecode(event as String) as Map<String, dynamic>);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) async {}

  @override
  Future close([int? closeCode, String? closeReason]) async {
    closed = true;
    if (!_inbound.isClosed) await _inbound.close();
  }

  @override
  Future get done => _inbound.done;
}

/// A channel the test drives: push server frames with [serverSend], hang up
/// with [serverClose].
class _FakeChannel implements WebSocketChannel {
  final _inbound = StreamController<dynamic>();
  late final _FakeSink _sink = _FakeSink(_inbound);

  void serverSend(Map<String, dynamic> frame) => _inbound.add(jsonEncode(frame));
  Future<void> serverClose() => _inbound.close();

  List<Map<String, dynamic>> get sent => _sink.sent;
  bool get closedByClient => _sink.closed;

  @override
  Future<void> get ready => Future.value();

  @override
  Stream get stream => _inbound.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness(this.async) {
    client = WebsocketClient(
      channelFactory: (_) {
        final c = _FakeChannel();
        channels.add(c);
        return c;
      },
      now: () => DateTime(2026, 1, 1).add(async.elapsed),
    );
    client.states.listen(states.add);
    client.events.listen((e) => events.add(e.type));
  }

  final FakeAsync async;
  late final WebsocketClient client;
  final channels = <_FakeChannel>[];
  final states = <WsConnState>[];
  final events = <WsEventServer>[];
  int tokenCalls = 0;

  _FakeChannel get channel => channels.last;

  void connect() {
    client.connect(tokenProvider: () async {
      tokenCalls++;
      return 'jwt';
    });
    async.flushMicrotasks();
  }
}

void main() {
  test('dials /ws with an auth frame, then an immediate heartbeat probe', () {
    fakeAsync((async) {
      final h = _Harness(async)..connect();
      expect(h.channels, hasLength(1));
      expect(h.tokenCalls, 1);
      expect(h.channel.sent.first, {'type': 'auth', 'token': 'jwt'});
      expect(h.channel.sent[1], {'type': 'heartbeat'});
    });
  });

  test('connected only once the server speaks', () {
    fakeAsync((async) {
      final h = _Harness(async)..connect();
      expect(h.client.state, WsConnState.connecting);
      expect(h.states, [WsConnState.connecting]);

      h.channel.serverSend({'type': 'connected', 'data': {'user_id': 'me'}});
      async.flushMicrotasks();
      expect(h.client.state, WsConnState.connected);
      expect(h.states, [WsConnState.connecting, WsConnState.connected]);
      expect(h.events, [WsEventServer.connected]);
    });
  });

  test('an auth rejection backs off instead of redialing at once', () {
    fakeAsync((async) {
      final h = _Harness(async)..connect();
      // Server closes without ever sending a frame (4401 path).
      h.channel.serverClose();
      async.flushMicrotasks();
      expect(h.client.state, WsConnState.disconnected);
      expect(h.client.reconnectAttempts, 1);
      expect(h.channels, hasLength(1), reason: 'no synchronous redial');

      // Second dial lands inside the 1s backoff window and fails again.
      async.elapse(AppConstants.wsReconnectBaseBackoff);
      async.flushMicrotasks();
      expect(h.channels, hasLength(2));
      h.channel.serverClose();
      async.flushMicrotasks();
      expect(h.client.reconnectAttempts, 2, reason: 'attempts accumulate');

      // Third dial waits at least ~1s (2s cap /2 jitter floor).
      async.elapse(const Duration(milliseconds: 900));
      async.flushMicrotasks();
      expect(h.channels, hasLength(2));
      async.elapse(const Duration(milliseconds: 1200));
      async.flushMicrotasks();
      expect(h.channels, hasLength(3));

      // A real frame resets the counter.
      h.channel.serverSend({'type': 'heartbeat_ack', 'data': {}});
      async.flushMicrotasks();
      expect(h.client.reconnectAttempts, 0);
      expect(h.client.state, WsConnState.connected);
    });
  });

  test('connect is idempotent while a socket is live', () {
    fakeAsync((async) {
      final h = _Harness(async)..connect();
      h.channel.serverSend({'type': 'connected', 'data': {}});
      async.flushMicrotasks();
      h.connect();
      h.connect();
      expect(h.channels, hasLength(1));
    });
  });

  test('resume with a stale socket forces an immediate redial', () {
    fakeAsync((async) {
      final h = _Harness(async)..connect();
      h.channel.serverSend({'type': 'connected', 'data': {}});
      async.flushMicrotasks();
      final first = h.channel;

      // Backgrounded past one heartbeat interval with no frames: the
      // periodic heartbeat has not noticed yet (its zombie threshold is the
      // longer server timeout), so without the resume hook this socket would
      // look healthy for up to another minute.
      async.elapse(AppConstants.wsHeartbeatInterval + const Duration(seconds: 1));
      h.client.onAppResumed();
      async.flushMicrotasks();
      expect(first.closedByClient, isTrue);
      expect(h.channels, hasLength(2));
      expect(h.states.last, WsConnState.connecting);
    });
  });

  test('resume with a fresh socket probes, and redials only on silence', () {
    fakeAsync((async) {
      final h = _Harness(async)..connect();
      h.channel.serverSend({'type': 'connected', 'data': {}});
      async.flushMicrotasks();
      final sentBefore = h.channel.sent.length;

      // Probe answered → nothing else happens.
      h.client.onAppResumed();
      expect(h.channel.sent.length, sentBefore + 1);
      expect(h.channel.sent.last, {'type': 'heartbeat'});
      h.channel.serverSend({'type': 'heartbeat_ack', 'data': {}});
      async.flushMicrotasks();
      async.elapse(WebsocketClient.resumeProbeTimeout + const Duration(seconds: 1));
      expect(h.channels, hasLength(1));

      // Probe unanswered → redial after the probe timeout.
      h.client.onAppResumed();
      async.elapse(WebsocketClient.resumeProbeTimeout + const Duration(milliseconds: 10));
      async.flushMicrotasks();
      expect(h.channels, hasLength(2));
    });
  });

  test('resume while disconnected dials now, skipping the backoff', () {
    fakeAsync((async) {
      final h = _Harness(async)..connect();
      h.channel.serverClose();
      async.flushMicrotasks();
      expect(h.client.state, WsConnState.disconnected);
      h.client.onAppResumed();
      async.flushMicrotasks();
      expect(h.channels, hasLength(2));
    });
  });

  test('close stops everything; a later connect starts fresh', () {
    fakeAsync((async) {
      final h = _Harness(async)..connect();
      h.channel.serverSend({'type': 'connected', 'data': {}});
      async.flushMicrotasks();
      h.client.close();
      async.flushMicrotasks();
      expect(h.client.state, WsConnState.disconnected);
      expect(h.channel.closedByClient, isTrue);
      async.elapse(const Duration(minutes: 5));
      expect(h.channels, hasLength(1), reason: 'no reconnect after close');

      h.connect();
      expect(h.channels, hasLength(2));
    });
  });
}
