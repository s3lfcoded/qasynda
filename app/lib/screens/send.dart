import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../l10n.dart';
import '../nearby.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

/// «Перевести рядом»: список тех, кто поблизости открыл приём.
class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _scanner = Scanner();
  late final AppState _app;
  Timer? _timer;
  bool _started = false;
  bool _polling = false;
  bool _bluetooth = false;
  Map<String, dynamic>? _location;
  List<Map<String, dynamic>> _people = [];
  String? _error;
  bool _gpsIgnored = false;
  int _minAmount = 100 * 100;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _app = AppScope.of(context);
    _begin();
  }

  Future<void> _begin() async {
    final bluetooth = await _scanner.start();
    if (!mounted) {
      await _scanner.stop();
      return;
    }
    setState(() => _bluetooth = bluetooth);
    _locate();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    _poll();
  }

  Future<void> _locate() async {
    final location = await currentLocation();
    if (mounted) setState(() => _location = location);
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final result = await _app.api.post('/nearby/discover', {'location': _location, 'ble_ids': _scanner.bleIds});
      if (mounted) {
        setState(() {
          _people = (result['people'] as List).cast<Map<String, dynamic>>();
          _gpsIgnored = result['gps'] == 'ignored';
          if (result['min_amount'] is int) _minAmount = result['min_amount'] as int;
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.code);
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scanner.stop();
    super.dispose();
  }

  void _choose(Map<String, dynamic> person) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AmountScreen(
        person: person,
        minAmount: _minAmount,
        bleIds: () => _scanner.bleIds,
        location: () => _location,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = _app.s;
    final nothingWorks = !_bluetooth && _location == null;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('sendNearby'))),
      body: SafeArea(
        child: _people.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Radar(child: Icon(Icons.near_me_rounded, size: 44, color: Q.accent)),
                    const SizedBox(height: 16),
                    Text(_error != null ? s.error(_error!) : s.t('searching'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text(nothingWorks ? s.t('needNearby') : s.t(_gpsIgnored ? 'gpsIgnored' : 'searchHint'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 15, height: 1.35, color: nothingWorks ? Q.danger : Q.muted)),
                  ]),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: _people.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _PersonCard(person: _people[i], s: s, onTap: () => _choose(_people[i])),
              ),
      ),
    );
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.person, required this.s, required this.onTap});
  final Map<String, dynamic> person;
  final S s;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final merchant = person['is_merchant'] == true;
    final bluetooth = person['method'] == 'bluetooth';
    return QCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        Avatar(name: '${person['name']}', merchant: merchant),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(merchant ? '${person['business_name']}' : '${person['name']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            if (merchant)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('${person['name']}', style: const TextStyle(fontSize: 14, color: Q.muted)),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (merchant) Pill(icon: Icons.verified_rounded, label: s.t('merchant'), color: Q.ok),
              bluetooth
                  ? Pill(icon: Icons.bluetooth_rounded, label: s.t('btNear'), color: Q.blue)
                  : Pill(
                      icon: Icons.location_on_rounded,
                      // точное расстояние сервер не сообщает: по нему можно вычислить, где стоит человек
                      label: s.t(person['proximity'] == 'close' ? 'gpsClose' : 'gpsNear'),
                      color: Q.muted),
            ]),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: Q.muted),
      ]),
    );
  }
}

class AmountScreen extends StatefulWidget {
  const AmountScreen({
    super.key,
    required this.person,
    required this.minAmount,
    required this.bleIds,
    required this.location,
  });
  final Map<String, dynamic> person;
  final int minAmount;
  final List<String> Function() bleIds;
  final Map<String, dynamic>? Function() location;

  @override
  State<AmountScreen> createState() => _AmountScreenState();
}

class _AmountScreenState extends State<AmountScreen> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  // Один ключ на экран: повторное нажатие или обрыв связи не спишет деньги второй раз.
  final _key = List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _tiyn => (int.tryParse(_amount.text) ?? 0) * 100;

  Future<void> _submit() async {
    final app = AppScope.of(context);
    setState(() => _busy = true);
    try {
      final receipt = await app.api.post('/transfers', {
        'public_id': widget.person['public_id'],
        'ble_ids': widget.bleIds(),
        'location': widget.location(),
        'amount': _tiyn,
        'idempotency_key': _key,
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
      });
      app.setBalance(receipt['balance'] as int);
      HapticFeedback.mediumImpact(); // короткий отклик: перевод прошёл
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => ReceiptScreen(receipt: receipt)));
    } on ApiError catch (e) {
      if (mounted) showError(context, app.s.error(e.code, e.detail));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final person = widget.person;
    final merchant = person['is_merchant'] == true;
    final limit = person['limit'] as int;
    final over = _tiyn > limit;
    final under = _tiyn > 0 && _tiyn < widget.minAmount;
    final ready = _tiyn >= widget.minAmount && !over && !_busy;

    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(children: [
            Expanded(
              child: ListView(keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: [
                Row(children: [
                  Avatar(name: '${person['name']}', merchant: merchant, size: 60),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(merchant ? '${person['business_name']}' : '${person['name']}',
                          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, height: 1.15)),
                      const SizedBox(height: 6),
                      if (merchant) Pill(icon: Icons.verified_rounded, label: s.t('merchant'), color: Q.ok),
                    ]),
                  ),
                ]),
                const SizedBox(height: 24),
                TextField(
                  controller: _amount,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(7)],
                  style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
                  decoration: InputDecoration(labelText: s.t('amount')),
                  onChanged: (_) => setState(() {}),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 8, 6, 14),
                  child: Text(
                    over
                        ? s.t('overLimit', {'sum': money(limit)})
                        : under
                            ? s.t('underMin', {'sum': money(widget.minAmount)})
                            : s.t('limit', {'min': money(widget.minAmount), 'sum': money(limit)}),
                    style: TextStyle(fontSize: 13.5, color: over || under ? Q.danger : Q.muted),
                  ),
                ),
                TextField(
                  controller: _note,
                  maxLength: 140,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: s.t('note'), counterText: ''),
                ),
              ]),
            ),
            FilledButton(
              onPressed: ready ? _submit : null,
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Q.onAccent))
                  : Text(_tiyn > 0 ? s.t('pay', {'sum': money(_tiyn)}) : s.t('payEmpty')),
            ),
          ]),
        ),
      ),
    );
  }
}

class ReceiptScreen extends StatelessWidget {
  const ReceiptScreen({super.key, required this.receipt});
  final Map<String, dynamic> receipt;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final recipient = receipt['recipient'] as Map<String, dynamic>;
    final merchant = recipient['is_merchant'] == true;
    final bluetooth = receipt['method'] == 'bluetooth';
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Expanded(
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: const BoxDecoration(color: Q.accent, shape: BoxShape.circle),
                    child: const Icon(Icons.check_rounded, size: 56, color: Q.onAccent),
                  ),
                  const SizedBox(height: 20),
                  Text(s.t('sent'), style: const TextStyle(fontSize: 17, color: Q.muted)),
                  const SizedBox(height: 6),
                  Text(money(receipt['amount'] as int), style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 10),
                  Text(merchant ? '${recipient['business_name']}' : '${recipient['name']}',
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.center, children: [
                    if (merchant) Pill(icon: Icons.verified_rounded, label: s.t('merchant'), color: Q.ok),
                    Pill(
                      icon: bluetooth ? Icons.bluetooth_rounded : Icons.location_on_rounded,
                      label: bluetooth ? 'Bluetooth' : 'GPS',
                      color: bluetooth ? Q.blue : Q.muted,
                    ),
                  ]),
                ]),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
              child: Text(s.t('done')),
            ),
          ]),
        ),
      ),
    );
  }
}
