import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qasynda/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sleeping server: /health is asked every few seconds until it answers', () async {
    HttpOverrides.global = null;
    var calls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      calls++;
      // Первые два запроса — как у спящего сервера: ответа нет (502 от прокси считается ответом,
      // поэтому имитируем обрыв соединения).
      if (calls <= 2) {
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"ok": true}');
      await req.response.close();
    });
    final state = AppState()..api.baseUrl = 'http://127.0.0.1:${server.port}';
    final up = await state.waitForServer(timeout: const Duration(seconds: 5), every: const Duration(milliseconds: 50));
    await server.close(force: true);
    expect(up, isTrue);
    expect(calls, 3);
  });

  test('server that never wakes up: give up after the timeout', () async {
    final state = AppState()..api.baseUrl = 'http://127.0.0.1:9';
    final up = await state.waitForServer(timeout: const Duration(milliseconds: 300), every: const Duration(milliseconds: 50));
    expect(up, isFalse);
  });
}
