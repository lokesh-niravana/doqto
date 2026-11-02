import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/constants/api_routes.dart';
import '../../core/constants/app_constants.dart';
import '../../core/enums/app_enums.dart';

class WsEvent {
  final WsEventServer type;
  final Map<String, dynamic> data;
  WsEvent(this.type, this.data);
}

/// Client-side socket lifecycle — drives the "Connecting…" banner and
/// reconnect gap recovery.
///
/// `connected` means the server has spoken to us on this socket (its
/// `connected` handshake frame, or any other frame on an older server) — NOT
/// merely that our auth frame went out. Everything that does gap recovery
/// (conversation refresh, message catch-up, outbox drain) keys off the
/// transition to `connected`, so it must mean "events are flowing again".
enum WsConnState { connecting, connected, disconnected }

/// Builds the channel for a URI. Injected so tests can drive frames without a
/// server.
typedef WsChannelFactory = WebSocketChannel Function(Uri uri);

class WebsocketClient {
  WebsocketClient({WsChannelFactory? channelFactory, DateTime Function()? now})
      : _factory = channelFactory ?? WebSocketChannel.connect,
        _now = now ?? DateTime.now;

  final WsChannelFactory _factory;
  final DateTime Function() _now;

  WebSocketChannel? _channel;
  Timer? _heartbeat;
  Timer? _reconnect;
  Timer? _resumeProbe;
  int _inboundFrames = 0;
  final _events = StreamController<WsEvent>.broadcast();
  final _states = StreamController<WsConnState>.broadcast();
  WsConnState _state = WsConnState.disconnected;
  bool _intentionallyClosed = true;
  int _attempts = 0;
  // Last time ANY frame arrived from the server (heartbeat_ack or otherwise).
  // Silence beyond wsHeartbeatTimeout means the socket is a zombie.
  late DateTime _lastAck = _now();
  Future<String?> Function()? _tokenProvider;

  Stream<WsEvent> get events => _events.stream;
  Stream<WsConnState> get states => _states.stream;
  WsConnState get state => _state;

  /// Wall-clock time of the last inbound frame (tests + diagnostics).
  DateTime get lastAck => _lastAck;

  void _setState(WsConnState s) {
    if (s == _state) return;
    _state = s;
    _states.add(s);
  }

  /// Open (or keep open) the user-scoped socket. Idempotent: calling it while
  /// connecting/connected is a no-op; calling it while a backoff timer is
  /// pending dials immediately. [tokenProvider] is called on every (re)connect
  /// so a refreshed access token is picked up instead of looping on an
  /// expired one.
  Future<void> connect({
    required Future<String?> Function() tokenProvider,
  }) async {
    _tokenProvider = tokenProvider;
    final wasClosed = _intentionallyClosed;
    _intentionallyClosed = false;
    if (!wasClosed && _state != WsConnState.disconnected) return;
    _reconnect?.cancel();
    _attempts = 0;
    await _open();
  }

  Future<void> _open() async {
    if (_intentionallyClosed) return;
    final provider = _tokenProvider;
    if (provider == null) return;
    _setState(WsConnState.connecting);
    String? token;
    try {
      token = await provider();
    } catch (_) {
      token = null;
    }
    if (_intentionallyClosed) return;
    if (token == null || token.isEmpty) {
      // Nothing to authenticate with right now (storage race, refresh
      // in flight). Back off and try again rather than giving up forever.
      _scheduleReconnect();
      return;
    }

    // Token goes in a first `auth` frame, not the URL (query strings get
    // logged by proxies).
    final uri = Uri.parse('${AppConstants.wsBaseUrl}${ApiRoutes.ws}');
    final WebSocketChannel channel;
    try {
      channel = _factory(uri);
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _channel = channel;
    _lastAck = _now(); // activity clock starts at dial time

    try {
      await channel.ready;
      if (channel != _channel || _intentionallyClosed) return;
      channel.sink.add(jsonEncode({'type': 'auth', 'token': token}));
      // Immediate liveness probe: an older server sends nothing after auth
      // to a user with no org, so the heartbeat_ack is what flips us to
      // `connected` there. A current server answers with `connected` first.
      channel.sink.add(jsonEncode({'type': WsEventClient.heartbeat.wire}));
    } catch (_) {
      if (channel != _channel) return;
      if (!_intentionallyClosed) _scheduleReconnect();
      return;
    }

    channel.stream.listen(
      (data) {
        if (channel != _channel) return;
        _lastAck = _now(); // any inbound frame proves liveness
        _inboundFrames++;
        if (_state != WsConnState.connected) {
          _attempts = 0; // a real server frame = this dial succeeded
          _setState(WsConnState.connected);
        }
        try {
          final decoded = jsonDecode(data as String) as Map<String, dynamic>;
          final type = WsEventServer.fromWire(decoded['type'] as String);
          if (type != null) {
            _events.add(
              WsEvent(type, (decoded['data'] ?? {}) as Map<String, dynamic>),
            );
          }
        } catch (_) {}
      },
      onDone: () {
        // Ignore callbacks from a channel we've already replaced.
        if (channel != _channel) return;
        if (!_intentionallyClosed) _scheduleReconnect();
      },
      onError: (_) {
        if (channel != _channel) return;
        if (!_intentionallyClosed) _scheduleReconnect();
      },
      cancelOnError: true,
    );

    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(AppConstants.wsHeartbeatInterval, (_) {
      if (channel != _channel) return;
      // Zombie detection: nothing (not even a heartbeat_ack) has arrived for
      // longer than the server's own idle deadline — tear down and redial now.
      if (_now().difference(_lastAck) > AppConstants.wsHeartbeatTimeout) {
        _forceReconnect();
        return;
      }
      try {
        channel.sink.add(jsonEncode({'type': WsEventClient.heartbeat.wire}));
      } catch (_) {}
    });
  }

  /// Drop the (presumed dead) socket and reconnect immediately — no backoff.
  void _forceReconnect() {
    if (_intentionallyClosed) return;
    _heartbeat?.cancel();
    _reconnect?.cancel();
    _resumeProbe?.cancel();
    _attempts = 0;
    final stale = _channel;
    _channel = null; // detaches stale onDone/onError from reconnect logic
    stale?.sink.close();
    _setState(WsConnState.disconnected);
    _open();
  }

  /// App came to the foreground. iOS suspends sockets in the background and
  /// the server reaps silent ones, so a socket can look healthy for up to a
  /// heartbeat interval after resume while delivering nothing. Decide now:
  ///  - disconnected → dial immediately, skipping any pending backoff;
  ///  - silent for longer than one heartbeat interval → force a reconnect
  ///    (the `connected` transition then drives full gap recovery);
  ///  - otherwise → send a heartbeat and force a reconnect if no frame
  ///    arrives within [resumeProbeTimeout].
  void onAppResumed() {
    if (_intentionallyClosed || _tokenProvider == null) return;
    switch (_state) {
      case WsConnState.disconnected:
        _reconnect?.cancel();
        _attempts = 0;
        _open();
      case WsConnState.connecting:
        return; // a dial is already in flight
      case WsConnState.connected:
        final silence = _now().difference(_lastAck);
        if (silence > AppConstants.wsHeartbeatInterval) {
          _forceReconnect();
          return;
        }
        final framesAtProbe = _inboundFrames;
        send({'type': WsEventClient.heartbeat.wire});
        _resumeProbe?.cancel();
        _resumeProbe = Timer(resumeProbeTimeout, () {
          if (_intentionallyClosed || _state != WsConnState.connected) return;
          // Any frame since the probe (not just its ack) proves the pipe.
          if (_inboundFrames == framesAtProbe) _forceReconnect();
        });
    }
  }

  /// How long a resume probe waits for any server frame before redialing.
  static const Duration resumeProbeTimeout = Duration(seconds: 5);

  /// Fire-and-forget client → server message (typing, heartbeat, …).
  void send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {}
  }

  void _scheduleReconnect() {
    if (_tokenProvider == null || _intentionallyClosed) return;
    _setState(WsConnState.disconnected);
    _heartbeat?.cancel();
    _channel = null;
    // Exponential backoff with jitter: 1s, 2s, 4s … capped at 30s. Attempts
    // only reset once the server actually speaks, so an auth rejection
    // (4401) backs off like any other failure instead of redialing at once.
    final capped = min(
      AppConstants.wsReconnectMaxBackoff.inMilliseconds,
      AppConstants.wsReconnectBaseBackoff.inMilliseconds *
          (1 << min(_attempts, 10)),
    );
    final delay = Duration(
      milliseconds: capped ~/ 2 + Random().nextInt(capped ~/ 2 + 1),
    );
    _attempts++;
    _reconnect?.cancel();
    _reconnect = Timer(delay, () {
      if (_intentionallyClosed) return;
      _open();
    });
  }

  /// Reconnect attempts made since the last successful connection (tests).
  int get reconnectAttempts => _attempts;

  Future<void> close() async {
    _intentionallyClosed = true;
    _heartbeat?.cancel();
    _reconnect?.cancel();
    _resumeProbe?.cancel();
    _setState(WsConnState.disconnected);
    final channel = _channel;
    _channel = null;
    await channel?.sink.close();
  }

  Future<void> dispose() async {
    await close();
    await _events.close();
    await _states.close();
  }
}
