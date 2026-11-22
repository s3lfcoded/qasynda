// Обходы блокировки, найденные при проверке безопасности: теперь каждый должен упираться в экран блокировки.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qasynda/main.dart';
import 'package:qasynda/screens/home.dart';
import 'package:qasynda/screens/lock.dart';
import 'package:qasynda/screens/settings.dart';
import 'package:qasynda/state.dart';

const _storageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

Map<String, dynamic> _profile() => {
      'name': 'Айгерим Касымова',
      'phone': '+77010000001',
      'balance': 25000000,
      'is_merchant': false,
      'business_name': null,
      'card_last4': '4417',
    };

Future<void> _lifecycle(WidgetTester tester, List<AppLifecycleState> states) async {
  for (final s in states) {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
  }
}

/// В тестах нет делегатов казахской локализации Material — это предупреждение не относится к делу.
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

void main() {
  testWidgets('screens opened before the lock are closed when the app locks', _quiet((tester) async {
    final state = AppState()
      ..ready = true
      ..profile = _profile();
    state.api.token = 'session';
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    tester.takeException();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SettingsScreen), findsOneWidget);

    await _lifecycle(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 61)));
    await _lifecycle(tester, [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await tester.pump(const Duration(seconds: 1));
    tester.takeException();

    expect(state.locked, isTrue);
    expect(find.byType(SettingsScreen, skipOffstage: false), findsNothing);
    expect(find.byType(HomeScreen, skipOffstage: false), findsNothing);
    expect(find.byType(LockScreen), findsOneWidget);
  }));

  testWidgets('cold start stays locked even when the server answers with errors', _quiet((tester) async {
    HttpOverrides.global = null;
    final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    await tester.runAsync(() async => server.listen((req) async {
          req.response.headers.contentType = ContentType.json;
          if (req.uri.path == '/me') {
            req.response.write(jsonEncode(_profile()));
          } else {
            req.response.statusCode = 502;
            req.response.write('{}');
          }
          await req.response.close();
        }));
    final store = <String, String>{'token': 'valid-session-token', 'server': 'http://127.0.0.1:${server.port}'};
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_storageChannel, (call) async {
      final args = (call.arguments as Map).cast<String, Object?>();
      return call.method == 'read' ? store[args['key']] : null;
    });

    final state = AppState();
    await tester.runAsync(() => state.boot());
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    tester.takeException();

    expect(state.loggedIn, isTrue);
    expect(state.locked, isTrue);
    expect(find.byType(LockScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    await tester.runAsync(() => server.close(force: true));
  }));

  testWidgets('server saying "locked" brings the lock screen back', _quiet((tester) async {
    HttpOverrides.global = null;
    final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    await tester.runAsync(() async => server.listen((req) async {
          req.response.headers.contentType = ContentType.json;
          req.response.statusCode = 403;
          req.response.write('{"detail": {"code": "locked"}}');
          await req.response.close();
        }));
    final state = AppState()
      ..ready = true
      ..profile = _profile();
    state.api
      ..token = 'session'
      ..baseUrl = 'http://127.0.0.1:${server.port}';
    await tester.pumpWidget(QasyndaApp(state: state));
    await tester.pump();
    tester.takeException();
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.runAsync(() => state.refresh().catchError((_) {}));
    await tester.pump(const Duration(seconds: 1));
    tester.takeException();
    expect(state.locked, isTrue);
    expect(find.byType(LockScreen), findsOneWidget);
    await tester.runAsync(() => server.close(force: true));
  }));
}
