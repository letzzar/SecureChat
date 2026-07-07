import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

enum WsState { disconnected, connecting, connected }

typedef MessageHandler = void Function(Map<String, dynamic> msg);

class WsClient {
  final String serverUrl;
  final String jwt;

  WsState _state = WsState.disconnected;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  /// Called after every successful (re)connect, so callers can re-subscribe
  /// to their rooms — server-side room membership is dropped on disconnect.
  void Function()? onConnected;

  WsState get state => _state;

  int _backoffSeconds = 1;
  bool _disposed = false;
  Timer? _reconnectTimer;

  WsClient({required this.serverUrl, required this.jwt});

  void connect() {
    if (_state != WsState.disconnected || _disposed) return;
    _doConnect();
  }

  Future<void> _doConnect() async {
    if (_disposed) return;
    _state = WsState.connecting;

    final wsUrl = serverUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');

    final uri = Uri.parse('$wsUrl/api/v1/ws?token=${Uri.encodeQueryComponent(jwt)}');

    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _sub = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
      );

      _state = WsState.connected;
      _backoffSeconds = 1;
      _sendRaw({'type': 'ping'});
      onConnected?.call();
    } catch (_) {
      _channel = null;
      _state = WsState.disconnected;
      _scheduleReconnect();
    }
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    try {
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      _messageController.add(msg);
    } catch (_) {}
  }

  void _onError(dynamic err) {
    _cleanup();
    _scheduleReconnect();
  }

  void _onDone() {
    _cleanup();
    if (!_disposed) _scheduleReconnect();
  }

  void _cleanup() {
    _state = WsState.disconnected;
    _sub?.cancel();
    _sub = null;
    _channel = null;
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _backoffSeconds), () {
      if (!_disposed) _doConnect();
    });
    _backoffSeconds = (_backoffSeconds * 2).clamp(1, 30);
  }

  void send(Map<String, dynamic> msg) => _sendRaw(msg);

  void _sendRaw(Map<String, dynamic> msg) {
    if (_state == WsState.connected && _channel != null) {
      _channel!.sink.add(jsonEncode(msg));
    }
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _messageController.close();
  }
}
