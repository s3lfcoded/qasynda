import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';

/// Одноразовый идентификатор маяка (8 байт) зашит в UUID сервиса: первые 8 байт — метка
/// приложения «qasynda!», последние 8 — идентификатор. Так сделано потому, что iPhone
/// умеет транслировать только UUID сервиса, а не произвольные данные.
const _prefix = '71617379-6e64-6121-';

String uuidForBleId(String bleId) => '$_prefix${bleId.substring(0, 4)}-${bleId.substring(4)}';

String? bleIdFromUuid(String uuid) {
  final u = uuid.toLowerCase();
  if (u.length != 36 || !u.startsWith(_prefix)) return null;
  final id = u.substring(19, 23) + u.substring(24);
  return RegExp(r'^[0-9a-f]{16}$').hasMatch(id) ? id : null;
}

/// Текущие координаты для сервера или null, если геолокация выключена или запрещена.
Future<Map<String, dynamic>?> currentLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 8)),
    );
    // isMocked: Android помечает координаты из программ подмены местоположения, сервер такие не принимает.
    return {
      'lat': p.latitude,
      'lon': p.longitude,
      'accuracy': p.accuracy.clamp(0, 10000).toDouble(),
      'mocked': p.isMocked,
    };
  } catch (_) {
    return null;
  }
}

/// Получатель: транслирует свой маяк по Bluetooth, пока открыт экран приёма.
class Advertiser {
  final _peripheral = FlutterBlePeripheral();

  Future<bool> start(String bleId) async {
    try {
      if (!await _peripheral.isSupported) return false;
      var state = await _peripheral.hasPermission();
      if (state != PeripheralBluetoothState.granted) state = await _peripheral.requestPermission();
      if (state != PeripheralBluetoothState.granted) return false;
      await _peripheral.start(
        advertiseData: AdvertiseDataCore(serviceUuid: uuidForBleId(bleId)),
        androidSettings: const AndroidAdvertiseSettings(
          advertiseSettings: AdvertiseSettings(
            advertiseMode: AdvertiseMode.advertiseModeLowLatency,
            txPowerLevel: AdvertiseTxPower.advertiseTxPowerMedium,
            connectable: false,
          ),
        ),
      );
      return await _peripheral.isAdvertising;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _peripheral.stop();
    } catch (_) {}
  }
}

/// Отправитель: слушает эфир и запоминает маяки Qasynda, услышанные за последние секунды.
class Scanner {
  static const _freshFor = Duration(seconds: 12);
  // Сколько меток отправлять серверу. Передатчик рядом может рассылать сотни поддельных меток,
  // поэтому берутся самые сильные сигналы: настоящий получатель обычно ближе всех.
  static const _maxIds = 20;
  final _seen = <String, (DateTime, int)>{};
  StreamSubscription<List<ScanResult>>? _sub;

  List<String> get bleIds {
    final edge = DateTime.now().subtract(_freshFor);
    _seen.removeWhere((_, seen) => seen.$1.isBefore(edge));
    final ids = _seen.keys.toList()..sort((a, b) => _seen[b]!.$2.compareTo(_seen[a]!.$2));
    return ids.take(_maxIds).toList();
  }

  Future<bool> start() async {
    try {
      if (!await FlutterBluePlus.isSupported) return false;
      // На iPhone первое обращение к Bluetooth вызывает системный запрос доступа. Пока человек
      // не ответил, состояние остаётся «неизвестно», поэтому ждём ответа дольше, чем на Android.
      const settled = {
        BluetoothAdapterState.on,
        BluetoothAdapterState.off,
        BluetoothAdapterState.unauthorized,
        BluetoothAdapterState.unavailable,
      };
      final state = await FlutterBluePlus.adapterState
          .firstWhere(settled.contains)
          .timeout(Duration(seconds: Platform.isIOS ? 30 : 3));
      if (state != BluetoothAdapterState.on) return false;
      _sub = FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          for (final uuid in result.advertisementData.serviceUuids) {
            final id = bleIdFromUuid(uuid.str128);
            if (id != null) _seen[id] = (DateTime.now(), result.rssi);
          }
        }
      }, onError: (_) {});
      await FlutterBluePlus.startScan(continuousUpdates: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }
}
