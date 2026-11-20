import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../l10n.dart';
import '../nearby.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

/// «Принять рядом»: пока экран открыт, телефон виден отправителям поблизости.
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _advertiser = Advertiser();
  late final AppState _app;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer;
  bool _started = false;
  bool _bluetooth = false;
  bool _gps = false;
  bool _online = true;
  bool _checked = false; // Bluetooth и геолокация уже опрошены: до этого предупреждение не показываем
  Map<String, dynamic>? _last;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _app = AppScope.of(context);
    _sub = _app.incoming.listen((event) {
      if (mounted) setState(() => _last = event);
    });
    _begin();
  }

  Future<void> _begin() async {
    final bleId = await _beat();
    if (!mounted) return;
    if (bleId != null) {
      final ok = await _advertiser.start(bleId);
      if (!mounted) {
        await _advertiser.stop();
        return;
      }
      setState(() => _bluetooth = ok);
    }
    setState(() => _checked = true);
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _beat());
  }

  /// Продлевает маяк на сервере. Возвращает идентификатор для трансляции по Bluetooth.
  Future<String?> _beat() async {
    final location = await currentLocation();
    try {
      final beacon = await _app.api.post('/nearby/beacon', {'location': location});
      if (mounted) {
        setState(() {
          _gps = location != null;
          _online = true;
        });
      }
      return beacon['ble_id'] as String;
    } on ApiError {
      if (mounted) setState(() => _online = false);
      return null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _advertiser.stop();
    _app.api.delete('/nearby/beacon').catchError((_) => <String, dynamic>{});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _app.s;
    final last = _last;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('receiveNearby'))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(children: [
            Expanded(
              child: Center(
                child: last == null
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        Radar(
                          child: Container(
                            width: 84,
                            height: 84,
                            decoration: BoxDecoration(color: Q.accent, borderRadius: BorderRadius.circular(30)),
                            child: const Icon(Icons.sensors_rounded, size: 40, color: Q.ink),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(_online ? s.t('visible') : s.t('err.network'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Text(s.t('visibleHint'),
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, color: Q.muted, height: 1.35)),
                      ])
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 96,
                          height: 96,
                          decoration: const BoxDecoration(color: Q.accent, shape: BoxShape.circle),
                          child: const Icon(Icons.check_rounded, size: 56, color: Q.ink),
                        ),
                        const SizedBox(height: 20),
                        Text(s.t('received', {'sum': money(last['amount'] as int)}),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 6),
                        Text(s.t('from', {'name': '${last['sender']}'}),
                            style: const TextStyle(fontSize: 17, color: Q.muted)),
                        if (last['note'] != null && '${last['note']}'.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text('«${last['note']}»', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                        ],
                      ]),
              ),
            ),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              Pill(
                icon: Icons.bluetooth_rounded,
                label: s.t(_bluetooth ? 'btOn' : 'btOff'),
                color: _bluetooth ? Q.blue : Q.muted,
              ),
              Pill(
                icon: Icons.location_on_rounded,
                label: s.t(_gps ? 'gpsOn' : 'gpsOff'),
                color: _gps ? Q.ok : Q.muted,
              ),
            ]),
            if (_checked && !_bluetooth && !_gps) ...[
              const SizedBox(height: 12),
              Text(s.t('needNearby'), textAlign: TextAlign.center, style: const TextStyle(color: Q.danger)),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(s.t('done'))),
          ]),
        ),
      ),
    );
  }
}
