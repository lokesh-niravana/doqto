import 'dart:async';

import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/websocket_client.dart';

/// A socket tests can push frames and lifecycle transitions into. Overrides
/// BOTH streams: the list notifiers subscribe to `states` for reconnect gap
/// recovery, so a fake that only stubs `events` leaks the real client in.
/// Also records `connect`/`close` so lifecycle tests can assert on them
/// without any network.
class FakeSocket extends WebsocketClient {
  final _events = StreamController<WsEvent>.broadcast();
  final _states = StreamController<WsConnState>.broadcast();

  int connectCalls = 0;
  int closeCalls = 0;
  Future<String?> Function()? lastTokenProvider;

  @override
  Stream<WsEvent> get events => _events.stream;

  @override
  Stream<WsConnState> get states => _states.stream;

  void emit(WsEventServer type, [Map<String, dynamic> data = const {}]) =>
      _events.add(WsEvent(type, data));

  void emitState(WsConnState s) => _states.add(s);

  @override
  Future<void> connect({
    required Future<String?> Function() tokenProvider,
  }) async {
    connectCalls++;
    lastTokenProvider = tokenProvider;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await _states.close();
  }
}

/// Let queued microtasks and zero-delay timers run.
Future<void> settle([int rounds = 4]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
