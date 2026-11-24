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
import '../widgets/pin_pad.dart';

/// Лимиты за перевод (как на сервере): Bluetooth точнее, поэтому лимит выше.
const limitBluetooth = 500000 * 100;
const limitGps = 50000 * 100;

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
      appBar: QAppBar(title: s.t('sendNearby')),
      body: SafeArea(
        top: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 16),
              children: [
                // Поиск идёт всё время, пока экран открыт: баннер остаётся и над списком.
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Q.line),
                  ),
                  child: Row(children: [
                    SearchRadar(color: nothingWorks ? Q.amberInk : Q.accent),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_error != null ? s.error(_error!) : s.t('searching'), style: Q.rowTitle.copyWith(color: Q.ink)),
                        const SizedBox(height: 4),
                        Text(
                          nothingWorks ? s.t('needNearby') : s.t(_gpsIgnored ? 'gpsIgnored' : 'searchHint'),
                          style: Q.secondary.copyWith(color: nothingWorks ? Q.amberInk : Q.ink2),
                        ),
                      ]),
                    ),
                  ]),
                ),
                // Учебные боты — всегда в конце, отдельной секцией.
                if (_people.any((p) => p['method'] != 'demo')) ...[
                  SectionLabel(s.t('nearYou')),
                  QGroup(
                    dividerIndent: 76,
                    children: [
                      for (final person in _people.where((p) => p['method'] != 'demo'))
                        _PersonRow(person: person, s: s, onTap: () => _choose(person)),
                    ],
                  ),
                ],
                if (_people.any((p) => p['method'] == 'demo')) ...[
                  SectionLabel(s.t('botsSection')),
                  QGroup(
                    dividerIndent: 76,
                    children: [
                      for (final person in _people.where((p) => p['method'] == 'demo'))
                        _PersonRow(person: person, s: s, onTap: () => _choose(person)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Q.gutter + 4, 0, Q.gutter + 4, 24),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline_rounded, size: 20, color: Q.ink2),
              const SizedBox(width: 12),
              Expanded(
                child: Text(s.t('limitsInfo', {'bt': money(limitBluetooth), 'gps': money(limitGps)}), style: Q.secondary),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Теги человека рядом: «ИП в банке» и способ, которым его нашли.
List<Widget> proximityTags(S s, Map<String, dynamic> person, {bool short = false}) {
  final merchant = person['is_merchant'] == true;
  final bluetooth = person['method'] == 'bluetooth';
  if (person['method'] == 'demo') return [QTag(kind: TagKind.bot, label: s.t('botTag'))];
  return [
    if (merchant) QTag(kind: TagKind.merchant, label: s.t('merchant')),
    if (bluetooth)
      QTag(kind: TagKind.bluetooth, label: short ? 'Bluetooth' : s.t('btNear'))
    else
      // точное расстояние сервер не сообщает: по нему можно вычислить, где стоит человек
      QTag(
        kind: TagKind.gps,
        label: short ? 'GPS' : s.t(person['proximity'] == 'close' ? 'gpsClose' : 'gpsNear'),
      ),
  ];
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person, required this.s, required this.onTap});
  final Map<String, dynamic> person;
  final S s;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final merchant = person['is_merchant'] == true;
    final bot = person['method'] == 'demo';
    final avatar = bot ? (merchant ? AvatarKind.botShop : AvatarKind.bot) : (merchant ? AvatarKind.shop : AvatarKind.initial);
    final subtitle = bot ? (merchant ? null : s.t('botReturns')) : (merchant ? '${person['name']}' : null);
    return InkWell(
      onTap: onTap,
      highlightColor: Q.surface2,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Avatar(name: '${person['name']}', kind: avatar),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(merchant ? '${person['business_name']}' : '${person['name']}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Q.rowTitle.copyWith(color: Q.ink)),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle, style: Q.secondary),
                ],
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: proximityTags(s, person)),
              ]),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.chevron_right_rounded, color: Q.ink3),
          ]),
        ),
      ),
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
  final _amountFocus = FocusNode();
  final _noteFocus = FocusNode();
  // Один ключ на экран: повторное нажатие или обрыв связи не спишет деньги второй раз.
  final _key = List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  bool _busy = false;
  // Ответ на перевод не дошёл: деньги могли уйти. Сумма и комментарий замораживаются, чтобы повтор
  // с тем же ключом получил исходный чек, а не ошибку «другая сумма» и второй перевод.
  bool _uncertain = false;

  @override
  void initState() {
    super.initState();
    void rebuild() {
      if (mounted) setState(() {});
    }

    _noteFocus.addListener(rebuild);
    _amountFocus.addListener(rebuild);
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _amountFocus.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  int get _tiyn => (int.tryParse(_amount.text) ?? 0) * 100;

  void _setAmount(String text) {
    _amount.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    setState(() {});
  }

  void _digit(String d) {
    if (_uncertain || _busy) return;
    if (_noteFocus.hasFocus) _amountFocus.requestFocus();
    final text = _amount.text;
    if ((text.isEmpty || text == '0') && d == '0') return;
    if (text.length >= 7) return;
    HapticFeedback.selectionClick();
    _setAmount(text == '0' ? d : text + d);
  }

  void _delete() {
    if (_uncertain || _busy || _amount.text.isEmpty) return;
    HapticFeedback.selectionClick();
    _setAmount(_amount.text.substring(0, _amount.text.length - 1));
  }

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
      if (!mounted) return;
      final unknownOutcome = e.status == 0 || e.status >= 500;
      if (unknownOutcome) setState(() => _uncertain = true);
      showError(context, unknownOutcome ? app.s.t('retrySame') : app.s.error(e.code, e.detail));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _amountDisplay() {
    final value = _tiyn ~/ 100;
    final digits = value == 0 ? '' : '$value';
    final glyphs = [
      for (var i = 0; i < digits.length; i++) (i > 0 && (digits.length - i) % 3 == 0) ? '$nbsp${digits[i]}' : digits[i],
    ];
    final ink = Q.amountInput.copyWith(color: Q.ink);
    final faint = Q.amountInput.copyWith(color: Q.ink3);
    final focused = _amountFocus.hasFocus || !_noteFocus.hasFocus;
    return SizedBox(
      height: 60,
      child: Stack(children: [
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (digits.isEmpty) Text('0', style: faint) else TypedText(glyphs: glyphs, style: ink),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: focused && !_uncertain ? 1 : 0,
                child: Container(
                  width: 3,
                  height: 44,
                  margin: const EdgeInsets.only(left: 4, right: 8),
                  decoration: BoxDecoration(color: Q.accent, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Text('₸', style: faint),
            ]),
          ),
        ),
        // Невидимое поле: ввод с аппаратной клавиатуры и для экранного диктора. Своя клавиатура ниже.
        Positioned.fill(
          child: TextSelectionTheme(
            data: const TextSelectionThemeData(selectionColor: Colors.transparent),
            child: TextField(
              controller: _amount,
              focusNode: _amountFocus,
              autofocus: true,
              readOnly: _uncertain,
              keyboardType: TextInputType.none,
              showCursor: false,
              enableInteractiveSelection: false,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(7)],
              style: const TextStyle(color: Colors.transparent),
              decoration: InputDecoration(
                filled: false,
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                labelText: AppScope.of(context).s.t('amount'),
                labelStyle: const TextStyle(color: Colors.transparent),
                floatingLabelBehavior: FloatingLabelBehavior.never,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
      ]),
    );
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
    final typingNote = _noteFocus.hasFocus;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      appBar: QAppBar(title: s.t('transfer')),
      body: SafeArea(
        top: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 16),
              children: [
                Row(children: [
                  Avatar(
                    name: '${person['name']}',
                    kind: person['method'] == 'demo'
                        ? (merchant ? AvatarKind.botShop : AvatarKind.bot)
                        : (merchant ? AvatarKind.shop : AvatarKind.initial),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(merchant ? '${person['business_name']}' : '${person['name']}',
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: Q.rowTitle.copyWith(color: Q.ink)),
                      if (merchant || person['method'] != null) ...[
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: proximityTags(s, person, short: true)),
                      ],
                    ]),
                  ),
                ]),
                const SizedBox(height: 32),
                _amountDisplay(),
                const SizedBox(height: 8),
                Text(
                  over
                      ? s.t('overLimit', {'sum': money(limit)})
                      : under
                          ? s.t('underMin', {'sum': money(widget.minAmount)})
                          : s.t('limit', {'min': money(widget.minAmount), 'sum': money(limit)}),
                  textAlign: TextAlign.center,
                  style: Q.secondary.copyWith(color: over || under ? Q.danger : Q.ink2),
                ),
                const SizedBox(height: 24),
                _NoteField(
                  controller: _note,
                  focusNode: _noteFocus,
                  readOnly: _uncertain,
                  label: s.t('note'),
                  hint: s.t('noteHint'),
                ),
              ],
            ),
          ),
          if (!typingNote)
            Keypad(
              keyHeight: 56,
              fontSize: 26,
              onDigit: _digit,
              onDelete: _amount.text.isEmpty || _uncertain ? null : _delete,
              deleteLabel: s.t('pinDelete'),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(Q.gutter, typingNote ? 0 : 16, Q.gutter, keyboard ? 12 : 8),
            child: QButton(
              label: _tiyn > 0 ? s.t('pay', {'sum': money(_tiyn)}) : s.t('payEmpty'),
              onPressed: ready ? _submit : null,
              busy: _busy,
            ),
          ),
        ]),
      ),
    );
  }
}

/// Комментарий: подпись 13/16 над текстом 16/24, справа карандаш. Высота 56.
class _NoteField extends StatelessWidget {
  const _NoteField({
    required this.controller,
    required this.focusNode,
    required this.readOnly,
    required this.label,
    required this.hint,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool readOnly;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final focused = focusNode.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 56,
      padding: const EdgeInsets.only(left: 16),
      decoration: BoxDecoration(
        color: focused ? Q.bg : Q.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: focused ? Q.accent : Q.surface, width: 2),
      ),
      child: Row(children: [
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: Q.tag.copyWith(color: Q.ink2, fontWeight: FontWeight.w400)),
            TextField(
              controller: controller,
              focusNode: focusNode,
              readOnly: readOnly,
              // Сервер считает длину по символам Юникода, а не по видимым знакам: эмодзи из нескольких
              // символов иначе проходили бы здесь и отклонялись там.
              inputFormatters: [_CodePointLimit(140)],
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 16, height: 24 / 16, color: Q.ink),
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
                filled: false,
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintStyle: const TextStyle(fontSize: 16, height: 24 / 16, color: Q.ink3),
              ),
            ),
          ]),
        ),
        IconButton(
          onPressed: readOnly ? null : focusNode.requestFocus,
          tooltip: label,
          style: IconButton.styleFrom(fixedSize: const Size.square(44)),
          icon: const Icon(Icons.edit_outlined, size: 20, color: Q.ink2),
        ),
      ]),
    );
  }
}

class ReceiptScreen extends StatefulWidget {
  const ReceiptScreen({super.key, required this.receipt});
  final Map<String, dynamic> receipt;

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final receipt = widget.receipt;
    final recipient = receipt['recipient'] as Map<String, dynamic>;
    final merchant = recipient['is_merchant'] == true;
    final bluetooth = receipt['method'] == 'bluetooth';
    final note = '${receipt['note'] ?? ''}';
    final created = receipt['created_at'];
    final reduced = MediaQuery.disableAnimationsOf(context);

    Widget row(String label, Widget value) => ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Text(label, style: const TextStyle(fontSize: 15, height: 20 / 15, color: Q.ink2)),
              const SizedBox(width: 16),
              Expanded(child: Align(alignment: AlignmentDirectional.centerEnd, child: value)),
            ]),
          ),
        );
    Text bold(String text) => Text(text,
        textAlign: TextAlign.end,
        style: const TextStyle(fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w600, color: Q.ink, fontFeatures: Q.tabular));

    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Q.gutter, 48, Q.gutter, 16),
              children: [
                Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: reduced ? 1 : 0.6, end: 1),
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutBack,
                    builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(color: Q.accent, shape: BoxShape.circle),
                      child: const Icon(Icons.check_rounded, size: 40, color: Q.onAccent),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(s.t('sent'), textAlign: TextAlign.center, style: Q.appBar.copyWith(color: Q.ink2, fontWeight: FontWeight.w400)),
                const SizedBox(height: 4),
                Center(
                  child: Sensitive(
                    builder: (_, shown) => RollingAmount(
                      money(receipt['amount'] as int),
                      style: Q.balance.copyWith(color: Q.ink),
                      hidden: !shown,
                      rollIn: true,
                      delay: const Duration(milliseconds: 120),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(merchant ? '${recipient['business_name']}' : '${recipient['name']}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w600, color: Q.ink)),
                const SizedBox(height: 32),
                Material(
                  color: Q.surface,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(children: [
                      if (merchant) row(s.t('recipient'), bold('${recipient['name']}')),
                      if (merchant) row(s.t('status'), QTag(kind: TagKind.merchant, label: s.t('merchant'))),
                      row(
                        s.t('foundBy'),
                        receipt['method'] == 'demo'
                            ? QTag(kind: TagKind.bot, label: s.t('botTag'))
                            : QTag(kind: bluetooth ? TagKind.bluetooth : TagKind.gps, label: bluetooth ? 'Bluetooth' : 'GPS'),
                      ),
                      if (note.isNotEmpty) row(s.t('note'), bold(note)),
                      // Переводы идут с баланса Qasynda, карта — только для пополнения.
                      row(s.t('paidFrom'), bold(s.t('balanceQasynda'))),
                      if (created is num)
                        row(s.t('date'), bold(s.date(DateTime.fromMillisecondsSinceEpoch((created * 1000).round())))),
                    ]),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, 8),
            child: QButton(
              label: s.t('done'),
              onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Ограничивает текст числом символов Юникода (как считает сервер), а не видимых знаков.
class _CodePointLimit extends TextInputFormatter {
  _CodePointLimit(this.max);
  final int max;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.runes.length <= max) return newValue;
    return oldValue;
  }
}
