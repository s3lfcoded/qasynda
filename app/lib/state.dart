import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'l10n.dart';

/// Адрес сервера по умолчанию задаётся при сборке:
///   flutter build apk --dart-define=QASYNDA_API=https://example.org
/// 10.0.2.2 — это компьютер разработчика, если приложение запущено в эмуляторе Android.
const defaultServer = String.fromEnvironment('QASYNDA_API', defaultValue: 'http://10.0.2.2:8000');

class AppState extends ChangeNotifier {
  final api = Api();
  final _storage = const FlutterSecureStorage();
  final _incoming = StreamController<Map<String, dynamic>>.broadcast();

  String lang = 'ru';
  bool ready = false;
  Map<String, dynamic>? profile;
  List<Map<String, dynamic>> history = [];

  WebSocketChannel? _socket;
  Timer? _reconnect;

  S get s => S(lang);
  bool get loggedIn => api.token != null && profile != null;

  /// Входящие переводы в реальном времени.
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String? value) async {
    try {
      value == null ? await _storage.delete(key: key) : await _storage.write(key: key, value: value);
    } catch (_) {}
  }

  Future<void> boot() async {
    lang = await _read('lang') ?? 'ru';
    api.baseUrl = await _read('server') ?? defaultServer;
    api.token = await _read('token');
    if (api.token != null) {
      try {
        await refresh();
        _connect();
      } on ApiError catch (e) {
        if (e.status == 401) await _forget();
      }
    }
    ready = true;
    notifyListeners();
  }

  Future<void> setLang(String value) async {
    lang = value;
    notifyListeners();
    await _write('lang', value);
  }

  Future<void> setServer(String value) async {
    api.baseUrl = value.trim().replaceAll(RegExp(r'/+$'), '');
    await _write('server', api.baseUrl);
  }

  Future<void> login(String phone, String pin) async {
    final result = await api.post('/auth/login', {'phone': phone, 'pin': pin});
    api.token = result['token'] as String;
    await _write('token', api.token);
    await refresh();
    _connect();
  }

  Future<void> logout() async {
    try {
      await api.post('/auth/logout');
    } catch (_) {}
    await _forget();
    notifyListeners();
  }

  Future<void> _forget() async {
    _reconnect?.cancel();
    await _socket?.sink.close();
    _socket = null;
    api.token = null;
    profile = null;
    history = [];
    await _write('token', null);
  }

  Future<void> refresh() async {
    try {
      profile = await api.get('/me');
      final list = await api.get('/transfers');
      history = (list['items'] as List).cast<Map<String, dynamic>>();
      notifyListeners();
    } on ApiError catch (e) {
      if (e.status == 401) {
        await _forget();
        notifyListeners();
      }
      rethrow;
    }
  }

  void setBalance(int balance) {
    if (profile == null) return;
    profile = {...profile!, 'balance': balance};
    notifyListeners();
  }

  Future<void> _connect() async {
    _reconnect?.cancel();
    final token = api.token;
    if (token == null) return;
    try {
      final uri = Uri.parse('${api.baseUrl.replaceFirst('http', 'ws')}/ws');
      final socket = WebSocketChannel.connect(uri);
      await socket.ready;
      _socket = socket;
      // Токен идёт первым сообщением, а не в адресе.
      socket.sink.add(jsonEncode({'token': token}));
      socket.stream.listen(_onMessage, onDone: _retryLater, onError: (_) => _retryLater(), cancelOnError: true);
    } catch (_) {
      _retryLater();
    }
  }

  void _retryLater() {
    _socket = null;
    if (api.token == null) return;
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 3), _connect);
  }

  void _onMessage(dynamic raw) {
    Object? event;
    try {
      event = jsonDecode(raw as String);
    } catch (_) {
      return;
    }
    if (event is Map<String, dynamic> && event['type'] == 'transfer_received') {
      if (event['balance'] is int) setBalance(event['balance'] as int);
      _incoming.add(event);
      refresh().catchError((_) {});
    }
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
