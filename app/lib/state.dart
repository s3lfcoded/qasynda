import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'l10n.dart';

/// Адрес сервера задаётся при сборке:
///   flutter build apk --dart-define=QASYNDA_API=https://example.org
/// 10.0.2.2 — это компьютер разработчика, если приложение запущено в эмуляторе Android.
/// В обычной (release) сборке адрес поменять нельзя: иначе человека можно уговорить «вписать сервер»
/// и получить его PIN.
const defaultServer = String.fromEnvironment('QASYNDA_API', defaultValue: 'http://10.0.2.2:8000');
const canChangeServer = !kReleaseMode;

/// Сколько приложение может пробыть свёрнутым, прежде чем снова спросит код.
const _lockAfter = Duration(seconds: 60);

/// Вход с нового телефона: сервер ждёт код из SMS. demoCode приходит только в учебном режиме сервера.
class SmsChallenge {
  const SmsChallenge(this.id, this.demoCode);
  final String id;
  final String? demoCode;
}

class AppState extends ChangeNotifier {
  final api = Api();
  final _storage = const FlutterSecureStorage();
  final _auth = LocalAuthentication();
  final _incoming = StreamController<Map<String, dynamic>>.broadcast();
  final _alerts = StreamController<Map<String, dynamic>>.broadcast();
  late final AppLifecycleListener _life;

  String lang = 'ru';
  bool ready = false;
  Map<String, dynamic>? profile;
  List<Map<String, dynamic>> history = [];

  /// Приложение открыто, но код или Face ID ещё не введены.
  bool locked = false;

  /// Приложение уходит в фон: экран закрывается заставкой, чтобы в списке открытых приложений
  /// не было видно баланса.
  bool covered = false;

  /// Суммы, номер и карта показываются точками, пока на них не нажали.
  bool hideSensitive = true;
  bool biometricEnabled = true;
  bool biometricAvailable = false;

  DateTime? _hiddenAt;
  WebSocketChannel? _socket;
  Timer? _reconnect;

  AppState() {
    _life = AppLifecycleListener(
      onInactive: () => _setCovered(true),
      onResume: () => _setCovered(false),
      onHide: () => _hiddenAt = DateTime.now(),
      onShow: () {
        final at = _hiddenAt;
        _hiddenAt = null;
        if (loggedIn && at != null && DateTime.now().difference(at) > _lockAfter) {
          locked = true;
          notifyListeners();
        }
      },
    );
  }

  S get s => S(lang);
  bool get loggedIn => api.token != null && profile != null;

  /// Входящие переводы в реальном времени.
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  /// Предупреждения безопасности: вход в аккаунт с нового телефона.
  Stream<Map<String, dynamic>> get alerts => _alerts.stream;

  void _setCovered(bool value) {
    if (covered == value) return;
    covered = value && hideSensitive;
    notifyListeners();
  }

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
    hideSensitive = await _read('hide') != '0';
    biometricEnabled = await _read('bio') != '0';
    api.baseUrl = canChangeServer ? await _read('server') ?? defaultServer : defaultServer;
    try {
      biometricAvailable = await _auth.isDeviceSupported() && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      biometricAvailable = false;
    }
    api.token = await _read('token');
    if (api.token != null) {
      try {
        await refresh();
        locked = true;
        _connect();
      } on ApiError catch (e) {
        if (e.status == 401) await _forget();
      }
    }
    ready = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> setLang(String value) async {
    lang = value;
    notifyListeners();
    await _write('lang', value);
  }

  Future<void> setServer(String value) async {
    if (!canChangeServer) return;
    api.baseUrl = value.trim().replaceAll(RegExp(r'/+$'), '');
    await _write('server', api.baseUrl);
  }

  Future<void> setHideSensitive(bool value) async {
    hideSensitive = value;
    notifyListeners();
    await _write('hide', value ? '1' : '0');
  }

  Future<void> setBiometric(bool value) async {
    biometricEnabled = value;
    notifyListeners();
    await _write('bio', value ? '1' : '0');
  }

  /// Секрет этого телефона. IMEI приложениям недоступен ни на iPhone, ни на новых Android,
  /// поэтому телефон узнаётся по случайному ключу, который живёт в Keychain / Keystore.
  Future<String> _deviceSecret() async {
    final saved = await _read('device');
    if (saved != null) return saved;
    final random = Random.secure();
    final secret = base64Url.encode(List.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
    await _write('device', secret);
    return secret;
  }

  String get _deviceName => Platform.isIOS ? 'iPhone' : (Platform.isAndroid ? 'Android' : Platform.operatingSystem);

  /// Вход. Возвращает null, если вход выполнен, или запрос кода из SMS, если телефон новый.
  Future<SmsChallenge?> login(String phone, String pin) async {
    final result = await api.post('/auth/login', {
      'phone': phone,
      'pin': pin,
      'device_secret': await _deviceSecret(),
      'device_name': _deviceName,
    });
    if (result['sms_required'] == true) {
      return SmsChallenge(result['challenge'] as String, result['demo_code'] as String?);
    }
    await _signedIn(result['token'] as String);
    return null;
  }

  Future<void> confirm(SmsChallenge challenge, String code, String pin) async {
    final result = await api.post('/auth/confirm', {'challenge': challenge.id, 'code': code, 'pin': pin});
    await _signedIn(result['token'] as String);
  }

  Future<void> _signedIn(String token) async {
    api.token = token;
    await _write('token', token);
    locked = false;
    await refresh();
    _connect();
  }

  /// Разблокировка кодом: его проверяет сервер, после пяти ошибок сессия закрывается.
  Future<void> unlock(String pin) async {
    try {
      await api.post('/auth/unlock', {'pin': pin});
    } on ApiError catch (e) {
      if (e.status == 401) {
        await _forget();
        notifyListeners();
      }
      rethrow;
    }
    locked = false;
    notifyListeners();
  }

  /// Разблокировка Face ID или отпечатком. false — человек отменил или биометрия недоступна.
  Future<bool> unlockWithBiometrics() async {
    if (!biometricAvailable || !biometricEnabled) return false;
    try {
      final ok = await _auth.authenticate(localizedReason: s.t('bioReason'), persistAcrossBackgrounding: true);
      if (ok) {
        locked = false;
        notifyListeners();
      }
      return ok;
    } on LocalAuthException {
      return false;
    }
  }

  Future<void> logout() async {
    try {
      await api.post('/auth/logout');
    } catch (_) {}
    await _forget();
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> devices() async =>
      ((await api.get('/devices'))['items'] as List).cast<Map<String, dynamic>>();

  Future<void> removeDevice(String id) => api.delete('/devices/$id');

  Future<void> logoutOthers() => api.post('/devices/logout-others');

  Future<void> _forget() async {
    _reconnect?.cancel();
    await _socket?.sink.close();
    _socket = null;
    api.token = null;
    profile = null;
    history = [];
    locked = false;
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
    if (api.token == null) return;
    try {
      // Сервер проверяет одноразовый пропуск до того, как примет соединение. Токен сессии в адрес не попадает.
      final ticket = (await api.post('/ws/ticket'))['ticket'] as String;
      final base = Uri.parse(api.baseUrl);
      final uri = base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '${base.path}/ws',
        queryParameters: {'ticket': ticket},
      );
      final socket = WebSocketChannel.connect(uri);
      await socket.ready;
      _socket = socket;
      socket.stream.listen(_onMessage, onDone: _retryLater, onError: (_) => _retryLater(), cancelOnError: true);
    } on ApiError catch (e) {
      if (e.status == 401) {
        await _forget();
        notifyListeners();
        return;
      }
      _retryLater();
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
    if (event is! Map<String, dynamic>) return;
    if (event['type'] == 'transfer_received') {
      if (event['balance'] is int) setBalance(event['balance'] as int);
      _incoming.add(event);
      refresh().catchError((_) {});
    } else if (event['type'] == 'new_device') {
      _alerts.add(event);
    }
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
