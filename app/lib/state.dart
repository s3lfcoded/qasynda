import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb, kReleaseMode;
import 'package:flutter/services.dart' show PlatformException;
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
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  // «Только на этом устройстве»: токен и ключ телефона не попадают в резервную копию iPhone
  // и не переезжают на другой телефон при восстановлении из неё.
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  final _auth = LocalAuthentication();
  final _incoming = StreamController<Map<String, dynamic>>.broadcast();
  final _alerts = StreamController<Map<String, dynamic>>.broadcast();
  final _pendingAlerts = <Map<String, dynamic>>[];
  final _hidden = Stopwatch();
  DateTime? _hiddenAt;
  int _connection = 0;
  bool _bioEnrolled = false;
  Future<void>? _lockRequest;
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

  WebSocketChannel? _socket;
  Timer? _reconnect;

  AppState() {
    api.onLocked = lockNow;
    _life = AppLifecycleListener(
      onInactive: () => _setCovered(true),
      onResume: () => _setCovered(false),
      // Время в фоне считается и по монотонным часам, и по обычным, и берётся большее: перевод часов
      // назад не отменит блокировку, а глубокий сон телефона (монотонные часы в нём стоят) — тоже.
      onHide: () {
        _hidden
          ..reset()
          ..start();
        _hiddenAt = DateTime.now();
      },
      onShow: () {
        _hidden.stop();
        final wall = _hiddenAt == null ? Duration.zero : DateTime.now().difference(_hiddenAt!);
        _hiddenAt = null;
        final away = wall > _hidden.elapsed ? wall : _hidden.elapsed;
        if (loggedIn && away > _lockAfter) lockNow();
      },
    );
  }

  S get s => S(lang);

  /// В заблокированном приложении профиля может не быть: сервер отдаёт его только после разблокировки.
  bool get loggedIn => api.token != null && (locked || profile != null);

  /// Кнопка Face ID на экране блокировки показывается, только если биометрия действительно привязана.
  bool get biometricReady => biometricAvailable && biometricEnabled && _bioEnrolled;

  /// Входящие переводы в реальном времени.
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  /// Предупреждения безопасности: вход в аккаунт с нового телефона.
  Stream<Map<String, dynamic>> get alerts => _alerts.stream;

  /// Предупреждения, пришедшие, пока их некому было показать (например, пока приложение заблокировано).
  List<Map<String, dynamic>> takePendingAlerts() {
    final list = List.of(_pendingAlerts);
    _pendingAlerts.clear();
    return list;
  }

  void _setCovered(bool value) {
    if (covered == value) return;
    covered = value && hideSensitive;
    notifyListeners();
  }

  /// Хранилище секрета для биометрии: открывается только лицом или пальцем владельца.
  /// На iPhone — Keychain с biometryCurrentSet, на Android — ключ Keystore только для сильной биометрии.
  /// Код телефона его не открывает, а добавление нового пальца или лица делает его недействительным.
  FlutterSecureStorage get _bioStorage => FlutterSecureStorage(
        iOptions: const IOSOptions(
          accountName: 'qasynda_bio',
          accessibility: KeychainAccessibility.unlocked_this_device,
          accessControlFlags: [AccessControlFlag.biometryCurrentSet],
        ),
        aOptions: AndroidOptions.biometric(
          enforceBiometrics: true,
          requireBiometricsPerOperation: true,
          biometricType: AndroidBiometricType.strongBiometricOnly,
          storageNamespace: 'qasynda_bio',
          biometricPromptTitle: s.t('bioReason'),
          biometricPromptNegativeButton: s.t('cancel'),
        ),
      );

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
    _bioEnrolled = await _read('bio_enrolled') == '1';
    api.token = await _read('token');
    if (api.token != null) {
      // Блокировка ставится сразу, до любых запросов: ни сбой сети, ни ошибка сервера её не снимут.
      // Экран блокировки показывается сразу, запросы к серверу идут в фоне.
      locked = true;
      _lockRequest = api.post('/auth/lock').then<void>((_) {}).catchError((Object e) async {
        if (e is ApiError && e.status == 401) {
          await _forget();
          notifyListeners();
        }
      });
      _connect();
    }
    ready = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  /// Блокирует приложение: закрывает все открытые поверх главного экраны (перевод, настройки, приём)
  /// и сообщает серверу, чтобы он тоже перестал пускать к переводам.
  void lockNow() {
    if (api.token == null) return;
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
    // Всплывающие сообщения живут поверх всех экранов: без этого они переезжали бы на экран блокировки.
    messengerKey.currentState?.clearSnackBars();
    if (!locked) {
      locked = true;
      notifyListeners();
    }
    _lockRequest = api.post('/auth/lock').then<void>((_) {}).catchError((_) {});
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

  /// Включает или выключает вход по биометрии. false — включить не удалось (человек отменил или
  /// хранилище недоступно): переключатель тогда остаётся выключенным.
  Future<bool> setBiometric(bool value) async {
    biometricEnabled = value;
    notifyListeners();
    await _write('bio', value ? '1' : '0');
    if (!value) {
      await _dropBiometrics();
      return true;
    }
    return _enrollBiometrics();
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

  String get _deviceName => kIsWeb
      ? 'Браузер'
      : switch (defaultTargetPlatform) {
          TargetPlatform.iOS => 'iPhone',
          TargetPlatform.android => 'Android',
          _ => 'Телефон',
        };

  /// Первый шаг входа — номер. null: телефон привязан к этому номеру, дальше PIN.
  /// Иначе сервер отправил SMS, и дальше нужен код.
  Future<SmsChallenge?> startLogin(String phone) async {
    final result = await api.post('/auth/start', {
      'phone': phone,
      'device_secret': await _deviceSecret(),
      'device_name': _deviceName,
    });
    if (result['next'] == 'sms') {
      return SmsChallenge(result['challenge'] as String, result['demo_code'] as String?);
    }
    return null;
  }

  /// Код из SMS. Верный код только открывает шаг PIN.
  Future<void> verifyCode(SmsChallenge challenge, String code) =>
      api.post('/auth/code', {'challenge': challenge.id, 'code': code});

  /// PIN с привязанного телефона.
  Future<void> login(String phone, String pin) async {
    final result = await api.post('/auth/login', {'phone': phone, 'pin': pin, 'device_secret': await _deviceSecret()});
    await _signedIn(result['token'] as String);
  }

  /// PIN с нового телефона, после верного кода из SMS.
  Future<void> confirm(SmsChallenge challenge, String pin) async {
    final result = await api.post('/auth/confirm', {'challenge': challenge.id, 'pin': pin});
    await _signedIn(result['token'] as String);
  }

  Future<void> _signedIn(String token) async {
    _connection++;
    await _socket?.sink.close();
    _socket = null;
    api.token = token;
    await _write('token', token);
    await _write('bio_enrolled', null);
    _bioEnrolled = false;
    locked = false;
    await refresh();
    _connect();
    await _enrollBiometrics();
  }

  /// Разблокировка кодом: его проверяет сервер, после пяти ошибок сессия закрывается.
  Future<void> unlock(String pin) async {
    await _unlockWith({'pin': pin});
    await _enrollBiometrics();
  }

  /// Разблокировка Face ID или отпечатком: секрет достаётся из хранилища под биометрией и проверяется
  /// сервером. false — человек отменил, биометрия изменилась или секрета ещё нет: тогда нужен PIN.
  Future<bool> unlockWithBiometrics() async {
    if (!biometricReady) return false;
    String? secret;
    try {
      secret = await _bioStorage.read(key: 'bio_secret');
    } on PlatformException {
      // Отмена или ключ стал недействительным (например, добавили новый палец): после входа по коду
      // биометрия привяжется заново.
      await _markBioEnrolled(false);
      return false;
    }
    // При сбое хранилища Android может вернуть вместо секрета служебную строку.
    if (secret == null || !RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(secret)) {
      await _markBioEnrolled(false);
      return false;
    }
    try {
      await _unlockWith({'bio_secret': secret});
      return true;
    } on ApiError catch (e) {
      if (e.code == 'invalid_bio') await _markBioEnrolled(false);
      rethrow;
    }
  }

  Future<void> _unlockWith(Map<String, dynamic> proof) async {
    // Блокировка, отправленная только что, не должна дойти до сервера после разблокировки и закрыть её.
    await _lockRequest;
    try {
      await api.post('/auth/unlock', proof);
    } on ApiError catch (e) {
      if (e.status == 401) {
        await _forget();
        notifyListeners();
      }
      rethrow;
    }
    // Профиль загружается до снятия блокировки: без него приложение показало бы экран входа.
    try {
      await refresh();
    } on ApiError {
      if (profile == null) rethrow;
    }
    locked = false;
    notifyListeners();
    if (_socket == null) _connect();
  }

  Future<void> _markBioEnrolled(bool value) async {
    _bioEnrolled = value;
    await _write('bio_enrolled', value ? '1' : null);
  }

  /// Привязывает биометрию к этому телефону: сервер выдаёт секрет, приложение кладёт его
  /// в хранилище под биометрией. Делается из разблокированной сессии, один раз.
  /// Если человек отменил окно биометрии или хранилище не сработало, биометрия выключается целиком,
  /// чтобы не спрашивать снова при каждой разблокировке; включить можно в настройках.
  Future<bool> _enrollBiometrics() async {
    if (!biometricAvailable || !biometricEnabled || locked) return false;
    if (_bioEnrolled) return true;
    try {
      final secret = (await api.post('/auth/bio-key'))['bio_secret'] as String;
      await _bioStorage.write(key: 'bio_secret', value: secret);
      await _markBioEnrolled(true);
      notifyListeners();
      return true;
    } catch (_) {
      biometricEnabled = false;
      await _write('bio', '0');
      await _dropBiometrics();
      notifyListeners();
      return false;
    }
  }

  Future<void> _dropBiometrics() async {
    await _markBioEnrolled(false);
    try {
      await _bioStorage.delete(key: 'bio_secret');
    } catch (_) {}
    try {
      await api.delete('/auth/bio-key');
    } catch (_) {}
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
    _connection++;
    _reconnect?.cancel();
    await _socket?.sink.close();
    _socket = null;
    api.token = null;
    profile = null;
    history = [];
    locked = false;
    _pendingAlerts.clear();
    messengerKey.currentState?.clearSnackBars();
    await _write('token', null);
    await _markBioEnrolled(false);
    try {
      await _bioStorage.delete(key: 'bio_secret');
    } catch (_) {}
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

  /// Каждое подключение получает номер. Если пока оно ждало ответа, человек вышел или вошёл заново,
  /// устаревшее соединение закрывается: иначе события старого аккаунта пришли бы следующему.
  Future<void> _connect() async {
    _reconnect?.cancel();
    if (api.token == null) return;
    final attempt = ++_connection;
    bool stale() => attempt != _connection || api.token == null;
    try {
      // Сервер проверяет одноразовый пропуск до того, как примет соединение. Токен сессии в адрес не попадает.
      final ticket = (await api.post('/ws/ticket'))['ticket'] as String;
      if (stale()) return;
      final base = Uri.parse(api.baseUrl);
      final uri = base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '${base.path}/ws',
        queryParameters: {'ticket': ticket},
      );
      final socket = WebSocketChannel.connect(uri);
      await socket.ready;
      if (stale()) {
        await socket.sink.close();
        return;
      }
      _socket = socket;
      socket.stream.listen(_onMessage, onDone: _retryLater, onError: (_) => _retryLater(), cancelOnError: true);
    } on ApiError catch (e) {
      if (stale()) return;
      if (e.status == 401) {
        await _forget();
        notifyListeners();
        return;
      }
      _retryLater();
    } catch (_) {
      if (!stale()) _retryLater();
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
      if (!locked) refresh().catchError((_) {});
    } else if (event['type'] == 'new_device') {
      // Пока приложение заблокировано, главного экрана нет и показать некому: предупреждение ждёт.
      if (_alerts.hasListener && !locked) {
        _alerts.add(event);
      } else {
        _pendingAlerts.add(event);
      }
    }
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
