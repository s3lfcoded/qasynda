// Ошибки приложения, найденные ревью кода: каждый тест падал до исправления.
// Review tests: each one should pass once the corresponding bug is fixed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qasynda/l10n.dart';
import 'package:qasynda/main.dart';
import 'package:qasynda/screens/home.dart';
import 'package:qasynda/screens/lock.dart';
import 'package:qasynda/screens/login.dart';
import 'package:qasynda/screens/send.dart';
import 'package:qasynda/state.dart';
import 'package:qasynda/widgets/code_cells.dart';
import 'package:qasynda/widgets/pin_pad.dart';

const _storageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _geoChannel = MethodChannel('flutter.baseflow.com/geolocator');

Map<String, dynamic> _profile() => {
      'name': 'Айгерим Касымова',
      'phone': '+77010000001',
      'balance': 25000000,
      'is_merchant': false,
      'business_name': null,
      'card_last4': '4417',
    };

typedef Route = FutureOr<(int, Object?)> Function(HttpRequest req, Map<String, dynamic> body);

class FakeServer {
  FakeServer._(this._http, this.routes);
  final HttpServer _http;
  final Map<String, Route> routes;
  final log = <String>[];
  final bodies = <String, List<Map<String, dynamic>>>{};
  final open = <WebSocket>{};
  int wsOpened = 0;

  String get url => 'http://127.0.0.1:${_http.port}';
  int count(String key) => log.where((e) => e == key).length;

  static Future<FakeServer> start(WidgetTester tester, Map<String, Route> routes) async {
    HttpOverrides.global = null;
    final http = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    final srv = FakeServer._(http, routes);
    await tester.runAsync(() async => http.listen(srv._handle));
    return srv;
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path == '/ws') {
      log.add('WS');
      final ws = await WebSocketTransformer.upgrade(req);
      wsOpened++;
      open.add(ws);
      ws.listen((_) {}, onDone: () => open.remove(ws));
      ws.add(jsonEncode({'type': 'ready'}));
      return;
    }
    final key = '${req.method} ${req.uri.path}';
    log.add(key);
    final raw = await utf8.decoder.bind(req).join();
    final body = raw.isEmpty ? <String, dynamic>{} : (jsonDecode(raw) as Map).cast<String, dynamic>();
    bodies.putIfAbsent(key, () => []).add(body);
    final route = routes[key];
    final (status, data) = route == null ? (200, {'ok': true}) : await route(req, body);
    if (status < 0) {
      final socket = await req.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data ?? {}));
    await req.response.close();
  }

  void push(Map<String, dynamic> event) {
    for (final ws in open) {
      ws.add(jsonEncode(event));
    }
  }

  Future<void> close() async {
    for (final ws in open.toList()) {
      await ws.close();
    }
    await _http.close(force: true);
  }
}

/// Secure storage fake. Calls with storageNamespace "qasynda_bio" go to the biometric store.
class FakeStorage {
  final plain = <String, String>{};
  final bio = <String, String>{};
  PlatformException? bioReadError;
  PlatformException? bioWriteError;
  int bioReads = 0;
  int bioWrites = 0;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_storageChannel, (call) async {
      final args = (call.arguments as Map).cast<String, Object?>();
      final options = (args['options'] as Map?)?.cast<String, Object?>() ?? const {};
      final isBio = options['storageNamespace'] == 'qasynda_bio' || options['accountName'] == 'qasynda_bio';
      final store = isBio ? bio : plain;
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          if (isBio) {
            bioReads++;
            if (bioReadError != null) throw bioReadError!;
          }
          return store[key];
        case 'write':
          if (isBio) {
            bioWrites++;
            if (bioWriteError != null) throw bioWriteError!;
          }
          store[key!] = args['value'] as String;
          return null;
        case 'delete':
          store.remove(key);
          return null;
      }
      return null;
    });
  }
}

Future<void> _real(WidgetTester tester, int ms) => tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

/// Lets real sockets and the fake clock both make progress.
Future<void> _settle(WidgetTester tester, [int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await _real(tester, 60);
    await tester.pump();
  }
}

Future<void> Function(WidgetTester) _quiet(Future<void> Function(WidgetTester) body) => (tester) async {
      final prev = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exceptionAsString().contains('localization delegates')) return;
        prev?.call(d);
      };
      try {
        await body(tester);
      } finally {
        FlutterError.onError = prev;
      }
    };

/// Ждёт, пока на экране не появится [finder]: запросы к настоящему сокету идут в реальном времени.
Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
    await _real(tester, 60);
    await tester.pump();
  }
}

(int, Object?) _ok(HttpRequest _, Map<String, dynamic> _) => (200, {'ok': true});
(int, Object?) _me(HttpRequest _, Map<String, dynamic> _) => (200, _profile());
(int, Object?) _history(HttpRequest _, Map<String, dynamic> _) => (200, {'items': <Object>[]});
(int, Object?) _ticket(HttpRequest _, Map<String, dynamic> _) => (200, {'ticket': 'ticket-123'});
(int, Object?) _bad(HttpRequest _, Map<String, dynamic> _) => (502, {});

void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2800);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

AppState _unlockedState(FakeServer srv) {
  final state = AppState()
    ..ready = true
    ..profile = _profile();
  state.api
    ..token = 'session'
    ..baseUrl = srv.url;
  return state;
}

void main() {
  testWidgets('cold start: PIN unlock with a failing /me must not drop the user on the login screen', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /auth/lock': _ok,
      'POST /ws/ticket': _bad,
      'POST /auth/unlock': _ok,
      'GET /me': _bad,
      'GET /transfers': _bad,
    });
    final storage = FakeStorage()
      ..plain.addAll({'token': 'valid-session', 'server': srv.url});
    storage.install(tester);

    final state = AppState();
    await tester.runAsync(state.boot);
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    tester.takeException();
    expect(find.byType(LockScreen), findsOneWidget);

    await tester.runAsync(() => state.unlock('1111'));
    await tester.pump();
    tester.takeException();

    final stuck = find.byType(LoginScreen).evaluate().isNotEmpty;
    final tokenKept = state.api.token != null && storage.plain['token'] != null;
    state.api.token = null;
    await tester.runAsync(srv.close);
    expect(stuck && tokenKept, isFalse,
        reason: 'unlock succeeded, the session token is still stored, yet the app shows LoginScreen '
            '(loggedIn=${state.loggedIn}, locked=${state.locked}, profile=${state.profile})');
  }));

  testWidgets('logout while the WebSocket is still connecting leaves a live socket for the old account', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /auth/lock': _ok,
      'POST /ws/ticket': (_, _) async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return (200, {'ticket': 'ticket-123'});
      },
      'POST /auth/logout': _ok,
    });
    final storage = FakeStorage()
      ..plain.addAll({'token': 'valid-session', 'server': srv.url});
    storage.install(tester);

    final state = AppState();
    final events = <Map<String, dynamic>>[];
    await tester.runAsync(() async {
      state.incoming.listen(events.add);
      await state.boot();
      await state.logout();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      srv.push({'type': 'transfer_received', 'amount': 500000, 'sender': 'Данияр А.', 'balance': 1});
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    final openAfterLogout = srv.open.length;
    await tester.runAsync(srv.close);
    expect(state.api.token, isNull);
    expect((openAfterLogout, events.length), (0, 0),
        reason: 'after logout: open sockets=$openAfterLogout, transfer events delivered=${events.length}');
  }));

  testWidgets('cold start on a network that never answers: spinner for 10 s before the lock screen', _quiet((tester) async {
    final hang = Completer<(int, Object?)>();
    final srv = await FakeServer.start(tester, {'POST /auth/lock': (_, _) => hang.future});
    final storage = FakeStorage()
      ..plain.addAll({'token': 'valid-session', 'server': srv.url});
    storage.install(tester);
    final state = AppState();
    await tester.runAsync(() async {
      unawaited(state.boot());
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    final readyAfter3s = state.ready;
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 8)));
    state.api.token = null;
    await tester.runAsync(srv.close);
    expect(readyAfter3s, isTrue, reason: 'boot() awaits POST /auth/lock (10 s timeout) before ready=true; locked=${state.locked}');
  }));

  testWidgets('cold start with /auth/lock failing: realtime socket never connects, even after unlock', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /auth/lock': _bad,
      'POST /ws/ticket': _ticket,
      'POST /auth/unlock': _ok,
      'GET /me': _me,
      'GET /transfers': _history,
    });
    final storage = FakeStorage()
      ..plain.addAll({'token': 'valid-session', 'server': srv.url});
    storage.install(tester);

    final state = AppState();
    await tester.runAsync(() async {
      await state.boot();
      await state.unlock('1111');
      await Future<void>.delayed(const Duration(seconds: 4));
    });
    final tickets = srv.count('POST /ws/ticket');
    state.api.token = null;
    await tester.runAsync(srv.close);
    expect(state.locked, isFalse);
    expect(tickets, greaterThan(0), reason: 'no /ws/ticket request was ever made in this session');
  }));

  testWidgets('new-device alert snackbar must not survive the lock (and its action must not crash)', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /auth/login': (_, _) => (200, {'token': 'session'}),
      'POST /ws/ticket': _ticket,
      'GET /me': _me,
      'GET /transfers': _history,
      'POST /auth/lock': _ok,
    });
    final storage = FakeStorage()..plain['server'] = srv.url;
    storage.install(tester);
    final state = AppState()..ready = true;
    state.api.baseUrl = srv.url;
    await tester.runAsync(() async {
      await state.login('+77010000001', '1111');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    tester.takeException();
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.runAsync(() async {
      srv.push({'type': 'new_device', 'name': 'Android'});
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('нового устройства'), findsOneWidget);

    await tester.runAsync(() async {
      state.lockNow();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    tester.takeException();
    expect(find.byType(LockScreen), findsOneWidget);
    final overLock = find.textContaining('нового устройства').evaluate().isNotEmpty;
    Object? crash;
    if (overLock) {
      await tester.tap(find.text('Настройки'));
      await tester.pump();
      crash = tester.takeException();
    }
    await _settle(tester);
    state.api.token = null;
    await tester.runAsync(srv.close);
    await tester.pump(const Duration(seconds: 11));
    expect(overLock, isFalse,
        reason: 'alert is still on top of LockScreen; tapping its "Настройки" action threw: $crash');
  }));

  testWidgets('alerts queued while locked are handed to the next account after logout', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /auth/login': (_, _) => (200, {'token': 'session'}),
      'POST /ws/ticket': _ticket,
      'GET /me': _me,
      'GET /transfers': _history,
      'POST /auth/lock': _ok,
      'POST /auth/logout': _ok,
    });
    final storage = FakeStorage()..plain['server'] = srv.url;
    storage.install(tester);
    final state = AppState()..ready = true;
    state.api.baseUrl = srv.url;
    await tester.runAsync(() async {
      await state.login('+77010000001', '1111');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      state.lockNow();
      srv.push({'type': 'new_device', 'name': 'Android'});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await state.logout();
    });
    final leftovers = state.takePendingAlerts();
    await tester.runAsync(srv.close);
    expect(leftovers, isEmpty);
  }));

  testWidgets('closing "Receive nearby" quickly must not re-create the beacon after DELETE', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /nearby/beacon': (_, _) => (200, {'public_id': 'a' * 16, 'ble_id': 'b' * 16, 'ttl': 45, 'gps': 'off'}),
      'DELETE /nearby/beacon': _ok,
      'GET /me': _me,
      'GET /transfers': _history,
    });
    FakeStorage().install(tester);
    // Location lookup takes 2 s (GPS fix), then reports location services off.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_geoChannel, (call) async {
      if (call.method == 'isLocationServiceEnabled') {
        await Future<void>.delayed(const Duration(seconds: 2));
        return false;
      }
      return null;
    });
    _tallScreen(tester);
    final state = _unlockedState(srv);
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    tester.takeException();

    await tester.tap(find.byIcon(Icons.sensors_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Готово'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await _settle(tester);
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);
    tester.takeException();

    final beaconOps = srv.log.where((e) => e.endsWith('/nearby/beacon')).toList();
    await tester.runAsync(srv.close);
    // Дать отработать таймерам запросов, начатых в тесте (таймаут HTTP — 10 секунд).
    await tester.pump(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(beaconOps.last, 'DELETE /nearby/beacon', reason: 'server saw $beaconOps');
  }));

  testWidgets('biometric enrollment cancelled: toggle stays on, failure is silent, user is re-prompted on every unlock', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /auth/bio-key': (_, _) => (200, {'bio_secret': 'A' * 43}),
      'DELETE /auth/bio-key': _ok,
      'POST /auth/unlock': _ok,
      'POST /auth/lock': _ok,
      'GET /me': _me,
      'GET /transfers': _history,
    });
    final storage = FakeStorage()
      ..bioWriteError = PlatformException(code: 'Exception encountered', message: 'User canceled');
    storage.install(tester);
    final state = _unlockedState(srv)..biometricAvailable = true;

    Object? surfaced;
    await tester.runAsync(() async {
      try {
        await state.setBiometric(true);
      } catch (e) {
        surfaced = e;
      }
      for (var i = 0; i < 2; i++) {
        state.lockNow();
        await state.unlock('1111');
      }
    });
    await tester.runAsync(srv.close);
    expect(
      (state.biometricEnabled && surfaced == null, storage.bioWrites),
      (false, 1),
      reason: 'biometricEnabled=${state.biometricEnabled}, error surfaced=$surfaced, biometric prompts=${storage.bioWrites}, '
          'DELETE /auth/bio-key=${srv.count('DELETE /auth/bio-key')}',
    );
  }));

  testWidgets('biometric key invalidated (read throws): PIN unlock must re-enroll', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /auth/bio-key': (_, _) => (200, {'bio_secret': 'B' * 43}),
      'POST /auth/unlock': _ok,
      'POST /auth/lock': _ok,
      'GET /me': _me,
      'GET /transfers': _history,
    });
    final storage = FakeStorage()
      ..plain['bio_enrolled'] = '1'
      ..bio['bio_secret'] = 'A' * 43
      ..bioReadError = PlatformException(code: 'Exception encountered', message: 'Key permanently invalidated');
    storage.install(tester);
    final state = _unlockedState(srv)
      ..biometricAvailable = true
      ..locked = true;

    late bool first;
    await tester.runAsync(() async {
      first = await state.unlockWithBiometrics();
      await state.unlock('1111');
    });
    final enrolls = srv.count('POST /auth/bio-key');
    await tester.runAsync(srv.close);
    expect(first, isFalse);
    expect(enrolls, greaterThan(0),
        reason: 'bio_enrolled stays "1" after the unreadable key, so enrollment is skipped forever '
            '(bio reads=${storage.bioReads})');
  }));

  testWidgets('lock screen hides the biometric button when biometrics are not enrolled', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {});
    final storage = FakeStorage();
    storage.install(tester);
    final state = _unlockedState(srv)
      ..biometricAvailable = true
      ..locked = true;
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    tester.takeException();
    expect(find.byType(LockScreen), findsOneWidget);
    expect(find.byType(PinPad), findsOneWidget);
    // Кнопка, которая ничего не делает, хуже её отсутствия: пока биометрия не привязана, её нет.
    expect(find.byTooltip('Face ID или отпечаток'), findsNothing);
    await tester.runAsync(srv.close);
  }));

  testWidgets('after a dropped request the amount is frozen and the retry gets the original receipt', _quiet((tester) async {
    final seen = <String, int>{};
    final srv = await FakeServer.start(tester, {
      // Mirrors db.make_transfer: the first request is committed but the reply is lost.
      'POST /transfers': (_, body) {
        final key = body['idempotency_key'] as String;
        final amount = body['amount'] as int;
        if (!seen.containsKey(key)) {
          seen[key] = amount;
          return (-1, null);
        }
        if (seen[key] != amount) return (409, {'detail': {'code': 'idempotency_conflict'}});
        return (200, {
          'id': 't1', 'amount': amount, 'method': 'bluetooth', 'note': null, 'created_at': 0,
          'recipient': {'name': 'Данияр А.', 'is_merchant': false, 'business_name': null}, 'balance': 100,
        });
      },
      'GET /me': _me,
      'GET /transfers': _history,
    });
    FakeStorage().install(tester);
    final state = _unlockedState(srv);
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    state.navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => AmountScreen(
        person: const {'public_id': 'aaaaaaaaaaaaaaaa', 'name': 'Данияр А.', 'is_merchant': false, 'limit': 50000000},
        minAmount: 10000,
        bleIds: () => const [],
        location: () => null,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    tester.takeException();

    await tester.enterText(find.byType(TextField).first, '500');
    await tester.pump();
    await tester.tap(find.text('Перевести ${money(50000)}'));
    await _settle(tester);
    expect(find.textContaining('деньги не спишутся дважды'), findsOneWidget);

    // Сумму поменять уже нельзя: поле только для чтения, повтор уходит с той же суммой и тем же ключом.
    await tester.enterText(find.byType(TextField).first, '600');
    await tester.pump();
    expect(find.text('Перевести ${money(50000)}'), findsOneWidget);
    await tester.tap(find.text('Перевести ${money(50000)}'));
    await _settle(tester);
    final keys = srv.bodies['POST /transfers']!.map((b) => '${b['idempotency_key']}/${b['amount']}').toSet();
    final generic = find.text('Что-то пошло не так').evaluate().isNotEmpty;
    await tester.runAsync(srv.close);
    // Дать отработать таймерам сообщений и запросов, начатых в тесте.
    await tester.pump(const Duration(minutes: 1));
    expect(keys.length, 1, reason: 'requests (key/amount): $keys');
    expect(generic, isFalse);
  }));

  testWidgets('new phone: number, then SMS code cells, then PIN pad; PIN is sent only after the right code', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /auth/start': (_, _) => (200, {'next': 'sms', 'challenge': 'c' * 24, 'ttl': 300, 'demo_code': '123456'}),
      'POST /auth/code': (_, body) => body['code'] == '123456'
          ? (200, {'next': 'pin'})
          : (401, {'detail': {'code': 'invalid_code', 'attempts_left': 4}}),
      'POST /auth/confirm': (_, body) =>
          body['pin'] == '1111' ? (200, {'token': 'session'}) : (401, {'detail': {'code': 'invalid_credentials'}}),
      'POST /ws/ticket': _ticket,
      'GET /me': _me,
      'GET /transfers': _history,
    });
    FakeStorage().install(tester);
    _tallScreen(tester);
    final state = AppState()..ready = true;
    state.api.baseUrl = srv.url;
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    tester.takeException();

    await tester.enterText(find.byType(TextField), '+77010000001');
    await tester.pump();
    await tester.tap(find.text('Продолжить'));
    await _until(tester, find.byType(CodeCells));
    expect(find.byType(CodeCells), findsOneWidget);
    expect(find.text('Учебное SMS: 123456'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '000000');
    await _until(tester, find.text('Неверный код. Осталось попыток: 4'));
    expect(find.text('Неверный код. Осталось попыток: 4'), findsOneWidget);
    expect(find.byType(CodeCells), findsOneWidget);
    expect(srv.count('POST /auth/confirm'), 0);

    await tester.enterText(find.byType(TextField), '123456');
    await _until(tester, find.byType(PinPad));
    expect(find.byType(PinPad), findsOneWidget);

    for (final pin in ['9999', '1111']) {
      for (final d in pin.split('')) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await _until(tester, pin == '9999' ? find.text('Неверный PIN-код') : find.byType(HomeScreen));
      if (pin == '9999') expect(find.text('Неверный PIN-код'), findsOneWidget);
    }
    expect(find.byType(HomeScreen), findsOneWidget);
    final confirms = srv.bodies['POST /auth/confirm']!;
    final start = srv.bodies['POST /auth/start']!.single;
    final log = List.of(srv.log);
    state.api.token = null;
    await tester.runAsync(srv.close);
    await tester.pump(const Duration(minutes: 1));
    expect(start['phone'], '+77010000001');
    expect(start.containsKey('pin'), isFalse);
    expect(confirms, [
      {'challenge': 'c' * 24, 'pin': '9999'},
      {'challenge': 'c' * 24, 'pin': '1111'},
    ]);
    expect(log.indexOf('POST /auth/confirm'), greaterThan(log.lastIndexOf('POST /auth/code')));
    expect(log, isNot(contains('POST /auth/login')));
  }));

  testWidgets('bound phone: number, then straight to the PIN pad and /auth/login', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /auth/start': (_, _) => (200, {'next': 'pin'}),
      'POST /auth/login': (_, _) => (200, {'token': 'session'}),
      'POST /ws/ticket': _ticket,
      'GET /me': _me,
      'GET /transfers': _history,
    });
    FakeStorage().install(tester);
    _tallScreen(tester);
    final state = AppState()..ready = true;
    state.api.baseUrl = srv.url;
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    tester.takeException();

    await tester.enterText(find.byType(TextField), '+77010000001');
    await tester.pump();
    await tester.tap(find.text('Продолжить'));
    await _until(tester, find.byType(PinPad));
    expect(find.byType(CodeCells), findsNothing);
    for (final d in '1111'.split('')) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await _until(tester, find.byType(HomeScreen));
    expect(find.byType(HomeScreen), findsOneWidget);
    final login = srv.bodies['POST /auth/login']!.single;
    final start = srv.bodies['POST /auth/start']!.single;
    state.api.token = null;
    await tester.runAsync(srv.close);
    await tester.pump(const Duration(minutes: 1));
    expect(login['phone'], '+77010000001');
    expect(login['pin'], '1111');
    expect(login['device_secret'], start['device_secret']);
    expect(srv.count('POST /auth/code'), 0);
  }));

  testWidgets('lock screen: PIN pad unlocks; after a wrong PIN it shows the error and takes a new PIN', _quiet((tester) async {
    final srv = await FakeServer.start(tester, {
      'POST /auth/unlock': (_, body) => body['pin'] == '1111' ? (200, {'ok': true}) : (403, {'detail': {'code': 'invalid_pin'}}),
      'POST /ws/ticket': _ticket,
      'GET /me': _me,
      'GET /transfers': _history,
    });
    FakeStorage().install(tester);
    _tallScreen(tester);
    final state = _unlockedState(srv)..locked = true;
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    tester.takeException();
    expect(find.byType(LockScreen), findsOneWidget);

    for (final pin in ['2222', '1111']) {
      for (final d in pin.split('')) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await _until(tester, pin == '2222' ? find.text('Неверный код') : find.byType(HomeScreen));
      if (pin == '2222') {
        expect(find.text('Неверный код'), findsOneWidget);
        expect(find.byType(LockScreen), findsOneWidget);
      }
    }
    expect(find.byType(HomeScreen), findsOneWidget);
    final unlocks = srv.bodies['POST /auth/unlock']!;
    state.api.token = null;
    await tester.runAsync(srv.close);
    await tester.pump(const Duration(minutes: 1));
    expect(unlocks, [
      {'pin': '2222'},
      {'pin': '1111'},
    ]);
  }));

  test('every error code the server can return has a message', () {
    const generic = 'Что-то пошло не так';
    final missing = ['idempotency_conflict', 'recipient_not_found', 'device_required', 'pin_or_bio_required',
      'invalid_code', 'code_required', 'start_over']
        .where((c) => const S('ru').error(c) == generic)
        .toList();
    expect(missing, isEmpty);
  });
}
