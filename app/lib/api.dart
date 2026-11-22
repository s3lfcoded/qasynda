import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiError implements Exception {
  ApiError(this.code, this.status, [this.detail = const {}]);
  final String code;
  final int status;
  final Map<String, dynamic> detail;

  @override
  String toString() => 'ApiError($status, $code)';
}

class Api {
  String baseUrl = '';
  String? token;
  final _client = http.Client();

  /// Сервер ответил, что сессия заблокирована: приложение должно показать экран блокировки.
  void Function()? onLocked;

  Future<Map<String, dynamic>> get(String path) => _send('GET', path);
  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic> body = const {}]) =>
      _send('POST', path, body);
  Future<Map<String, dynamic>> delete(String path) => _send('DELETE', path);

  Future<Map<String, dynamic>> _send(String method, String path, [Map<String, dynamic>? body]) async {
    http.Response response;
    try {
      final request = http.Request(method, Uri.parse('$baseUrl$path'));
      request.headers['Accept'] = 'application/json';
      if (token != null) request.headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final streamed = await _client.send(request).timeout(const Duration(seconds: 10));
      response = await http.Response.fromStream(streamed).timeout(const Duration(seconds: 10));
    } catch (_) {
      throw ApiError('network', 0);
    }

    Object? data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {}

    if (response.statusCode >= 200 && response.statusCode < 300 && data is Map<String, dynamic>) {
      return data;
    }
    final detail = data is Map<String, dynamic> ? data['detail'] : null;
    if (detail is Map<String, dynamic> && detail['code'] is String) {
      if (response.statusCode == 403 && detail['code'] == 'locked') onLocked?.call();
      throw ApiError(detail['code'] as String, response.statusCode, detail);
    }
    throw ApiError('unknown', response.statusCode);
  }
}
