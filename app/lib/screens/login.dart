import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../widgets/code_cells.dart';
import '../widgets/phone_field.dart';
import '../widgets/pin_pad.dart';

enum _Step { phone, code, pin, name, newPin, repeatPin }

/// Вход в три шага: номер → код из SMS (только для нового телефона) → PIN.
/// С нового телефона PIN уходит на сервер только после верного кода.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// Повторное SMS — не раньше чем через минуту.
  static const _resendAfter = 60;

  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _lastName = TextEditingController();
  String? _newPin;
  String? _pinError;
  Timer? _slow;
  final _cells = GlobalKey<CodeCellsState>();
  _Step _step = _Step.phone;
  SmsChallenge? _challenge;
  bool _busy = false;
  bool _waking = false;
  DateTime? _sentAt;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    _slow?.cancel();
    _phone.dispose();
    _name.dispose();
    _lastName.dispose();
    super.dispose();
  }

  String get _number => '+7${phoneDigits(_phone.text)}';

  bool get _phoneValid => phoneDigits(_phone.text).length == 10;

  int get _resendLeft {
    final sent = _sentAt;
    if (sent == null) return 0;
    return math.max(0, _resendAfter - DateTime.now().difference(sent).inSeconds);
  }

  void _startResendTimer() {
    _tick?.cancel();
    _sentAt = DateTime.now();
    _tick = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {});
      if (_resendLeft == 0) timer.cancel();
    });
  }

  void _stopResendTimer() {
    _tick?.cancel();
    _tick = null;
  }

  /// Первый запрос может упереться в спящий сервер: тогда ждём, пока он проснётся, и повторяем.
  Future<SmsChallenge?> _startWithWake(AppState app) async {
    try {
      return await app.startLogin(_number);
    } on ApiError catch (e) {
      if (e.code != 'network') rethrow;
      if (mounted) setState(() => _waking = true);
      final up = await app.waitForServer();
      if (!up) rethrow;
      return app.startLogin(_number);
    }
  }

  Future<void> _start() async {
    final app = AppScope.of(context);
    setState(() => _busy = true);
    // Ответа нет дольше 3 секунд — скорее всего, учебный сервер просыпается.
    _slow?.cancel();
    _slow = Timer(const Duration(seconds: 3), () {
      if (mounted && _busy) setState(() => _waking = true);
    });
    try {
      final challenge = await _startWithWake(app);
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _step = challenge == null ? _Step.pin : _Step.code;
      });
      if (challenge != null) {
        _startResendTimer();
      } else {
        _stopResendTimer();
      }
    } on ApiError catch (e) {
      if (mounted) showError(context, e.code == 'network' && _waking ? app.s.t('serverNoAnswer') : app.s.error(e.code, e.detail));
    } finally {
      _slow?.cancel();
      if (mounted) {
        setState(() {
          _busy = false;
          _waking = false;
        });
      }
    }
  }

  Future<bool> _code(String code) async {
    final app = AppScope.of(context);
    try {
      final registered = await app.verifyCode(_challenge!, code);
      _stopResendTimer();
      // Номер не зарегистрирован: регистрация — имя, затем новый PIN дважды.
      if (mounted) setState(() => _step = registered ? _Step.pin : _Step.name);
      return true;
    } on ApiError catch (e) {
      if (mounted) _failed(e);
      return false;
    }
  }

  Future<bool> _pin(String pin) async {
    final app = AppScope.of(context);
    final challenge = _challenge;
    try {
      if (challenge == null) {
        await app.login(_number, pin);
      } else {
        // Первый вход с этого телефона: на главном предложим привязать карту, если карт нет.
        app.offerCards = true;
        await app.confirm(challenge, pin);
      }
      return true;
    } on ApiError catch (e) {
      app.offerCards = false;
      if (mounted) _failed(e);
      return false;
    }
  }

  /// Запрос входа устарел или телефон перестал быть привязанным — вход начинается с номера.
  void _failed(ApiError e) {
    final s = AppScope.of(context).s;
    if (const {'challenge_expired', 'start_over', 'code_required'}.contains(e.code)) _back();
    showError(context, e.code == 'invalid_credentials' ? s.t('pinWrong') : s.error(e.code, e.detail));
  }

  void _back() {
    _stopResendTimer();
    setState(() {
      _step = _Step.phone;
      _challenge = null;
      _newPin = null;
    });
  }

  /// «Назад» на шагах регистрации возвращает на шаг раньше, а не к номеру.
  void _stepBack() {
    switch (_step) {
      case _Step.repeatPin:
        setState(() => _step = _Step.newPin);
      case _Step.newPin:
        setState(() => _step = _Step.name);
      default:
        _back();
    }
  }

  static final _nameRule = RegExp(r"^[\p{L}]+(?:[ -][\p{L}]+)*$", unicode: true);

  String get _fullName => '${_name.text.trim()} ${_lastName.text.trim()}'.trim();

  bool get _nameValid {
    final name = _fullName;
    return _name.text.trim().isNotEmpty && name.length >= 2 && name.length <= 60 && _nameRule.hasMatch(name);
  }

  /// Как имя увидят получатели: «Айгерим К.».
  String get _shortName {
    final first = _name.text.trim();
    final last = _lastName.text.trim();
    if (first.isEmpty) return '…';
    return last.isEmpty ? first : '$first ${last.characters.first}.';
  }

  /// Простые коды: 4 одинаковые цифры, последовательности вверх и вниз (1234, 9876), годы 1950–2015,
  /// чередование (1212) — сервер их тоже не примет.
  static bool _weak(String pin) {
    final d = pin.split('').map(int.parse).toList();
    if (d.toSet().length == 1) return true;
    final up = [for (var i = 1; i < 4; i++) d[i] - d[i - 1]].every((x) => x == 1);
    final down = [for (var i = 1; i < 4; i++) d[i] - d[i - 1]].every((x) => x == -1);
    final year = int.parse(pin);
    return up || down || (year >= 1950 && year <= 2015) || (d[0] == d[2] && d[1] == d[3]);
  }

  Future<bool> _setNewPin(String pin) async {
    final s = AppScope.of(context).s;
    if (_weak(pin)) {
      setState(() => _pinError = s.t('weakPin'));
      return false;
    }
    setState(() {
      _newPin = pin;
      _pinError = null;
      _step = _Step.repeatPin;
    });
    return true;
  }

  Future<bool> _register(String pin) async {
    final app = AppScope.of(context);
    final s = app.s;
    if (pin != _newPin) {
      setState(() {
        _newPin = null;
        _pinError = s.t('pinMismatch');
        _step = _Step.newPin;
      });
      return false;
    }
    try {
      // Дальше на главном: «Входить по Face ID?» и «Привяжите карту» — шаги 3 и 4 регистрации.
      app.offerCards = true;
      app.registrationSteps = true;
      await app.register(_challenge!, _fullName, pin);
      return true;
    } on ApiError catch (e) {
      app.offerCards = false;
      app.registrationSteps = false;
      if (!mounted) return false;
      switch (e.code) {
        case 'weak_pin' || 'invalid_request':
          setState(() {
            _pinError = s.t('weakPin');
            _step = _Step.newPin;
          });
          return false;
        case 'invalid_name':
          setState(() => _step = _Step.name);
        case 'challenge_expired' || 'code_required' || 'already_registered':
          _back();
      }
      showError(context, s.error(e.code, e.detail));
      return false;
    }
  }

  Future<void> _editServer() async {
    final app = AppScope.of(context);
    final controller = TextEditingController(text: app.api.baseUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(app.s.t('server')),
        content: TextField(controller: controller, keyboardType: TextInputType.url, autocorrect: false),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(app.s.t('save'))),
        ],
      ),
    );
    if (value != null && value.trim().isNotEmpty) await app.setServer(value);
  }

  Widget _phoneStep(BuildContext context, bool keyboard) {
    final s = AppScope.of(context).s;
    final ready = _phoneValid && !_busy;
    return SafeArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Q.gutter),
          child: SizedBox(
            height: 56,
            child: Row(children: [
              AnimatedMark(
                size: 32,
                once: true,
                label: Text('Qasynda', style: Q.section.copyWith(color: Q.ink, letterSpacing: -0.2)),
              ),
              const Spacer(),
              if (canChangeServer)
                IconButton(
                  onPressed: _editServer,
                  tooltip: s.t('server'),
                  icon: const Icon(Icons.dns_outlined, color: Q.ink3, size: 20),
                ),
              const LangToggle(),
            ]),
          ),
        ),
        Expanded(
          child: ListView(
            // На цифровой клавиатуре iPhone нет кнопки «Готово»: клавиатура убирается жестом вниз.
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(Q.gutter, 32, Q.gutter, 24),
            children: [
              Text(s.t('phoneTitle'), style: Q.title.copyWith(color: Q.ink)),
              const SizedBox(height: 8),
              Text(s.t('phoneHint'), style: Q.body),
              const SizedBox(height: 24),
              PhoneField(
                controller: _phone,
                label: s.t('phone'),
                clearLabel: s.t('clear'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => ready ? _start() : null,
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, keyboard ? 12 : 8),
          child: QButton(
            label: s.t('continue'),
            onPressed: ready ? _start : null,
            busy: _busy,
            busyLabel: _waking ? s.t('waking') : null,
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: _waking
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(Q.gutter + 16, 4, Q.gutter + 16, 16),
                  child: Text(s.t('wakingHint'), textAlign: TextAlign.center, style: Q.secondary),
                )
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }

  Widget _codeStep(BuildContext context, SmsChallenge challenge) {
    final s = AppScope.of(context).s;
    final demo = challenge.demoCode;
    final left = _resendLeft;
    final Widget footer;
    if (left > 0) {
      final parts = s.t('resendIn').split('{t}');
      final time = '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';
      const style = TextStyle(fontSize: 15, height: 20 / 15, color: Q.ink2, fontFeatures: Q.tabular);
      footer = Text.rich(TextSpan(style: style, children: [
        TextSpan(text: parts.first),
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: RollingAmount(time, style: style),
        ),
        if (parts.length > 1) TextSpan(text: parts.last),
      ]));
    } else {
      footer = Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          onPressed: _busy ? null : _start,
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 40)),
          child: Text(s.t('resend')),
        ),
      );
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 24),
      children: [
        Text(s.t('smsTitle'), style: Q.title.copyWith(color: Q.ink)),
        const SizedBox(height: 8),
        Text(s.t('smsHint', {'phone': phoneText(_number)}), style: Q.body),
        if (demo != null) ...[
          const SizedBox(height: 24),
          // Учебный режим сервера: настоящего SMS нет, код показывается здесь.
          Container(
            height: 48,
            padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
            decoration: BoxDecoration(color: Q.amberSoft, borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              const Icon(Icons.sms_rounded, size: 20, color: Q.amberInk),
              const SizedBox(width: 12),
              Expanded(
                child: Text(s.t('demoSms', {'code': demo}),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Q.label.copyWith(color: Q.amberInk, fontFeatures: Q.tabular)),
              ),
              TextButton(
                onPressed: () => _cells.currentState?.fill(demo),
                style: TextButton.styleFrom(
                  foregroundColor: Q.amberInk,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 40),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(s.t('paste')),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 24),
        CodeCells(
          key: _cells,
          onCompleted: _code,
          pasteLabel: s.t('paste'),
          semanticLabel: s.t('smsCode'),
          showPaste: demo == null,
          footer: footer,
        ),
      ],
    );
  }

  Widget _nameStep(BuildContext context, bool keyboard) {
    final s = AppScope.of(context).s;
    const style = TextStyle(fontSize: 18, height: 24 / 18, fontWeight: FontWeight.w500, color: Q.ink);
    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(text, style: Q.secondary.copyWith(fontWeight: FontWeight.w500)),
        );
    void next() {
      if (_nameValid) setState(() => _step = _Step.newPin);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 24),
          children: [
            Text(s.t('nameTitle'), style: Q.title.copyWith(color: Q.ink)),
            const SizedBox(height: 8),
            Text(s.t('nameHint', {'name': _shortName}), style: Q.body),
            const SizedBox(height: 24),
            label(s.t('firstName')),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.givenName],
              maxLength: 40,
              style: style,
              decoration: const InputDecoration(counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            label(s.t('lastName')),
            TextField(
              controller: _lastName,
              textCapitalization: TextCapitalization.words,
              autofillHints: const [AutofillHints.familyName],
              maxLength: 40,
              style: style,
              decoration: InputDecoration(
                counterText: '',
                hintText: s.t('lastNameHint'),
                hintStyle: style.copyWith(color: Q.ink3, fontWeight: FontWeight.w400),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => next(),
            ),
          ],
        ),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, keyboard ? 12 : 8),
        child: QButton(label: s.t('continue'), onPressed: _nameValid ? next : null),
      ),
    ]);
  }

  Widget _newPinStep(BuildContext context, {required bool repeat}) {
    final s = AppScope.of(context).s;
    return Column(children: [
      const SizedBox(height: 32),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Q.gutter),
        child: Column(children: [
          Text(s.t(repeat ? 'repeatPinTitle' : 'newPinTitle'), textAlign: TextAlign.center, style: Q.titleM.copyWith(color: Q.ink)),
          const SizedBox(height: 8),
          Text(s.t(repeat ? 'repeatPinHint' : 'newPinHint'), textAlign: TextAlign.center, style: Q.body),
        ]),
      ),
      const SizedBox(height: 32),
      Expanded(
        child: PinPad(
          key: ValueKey(repeat),
          onSubmit: repeat ? _register : _setNewPin,
          deleteLabel: s.t('pinDelete'),
          expand: true,
          errorText: repeat ? null : _pinError,
          onInput: () {
            if (_pinError != null) setState(() => _pinError = null);
          },
        ),
      ),
    ]);
  }

  Widget _pinStep(BuildContext context) {
    final s = AppScope.of(context).s;
    return Column(children: [
      const SizedBox(height: 40),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Q.gutter),
        child: Column(children: [
          Text(s.t('pinTitle'), textAlign: TextAlign.center, style: Q.titleM.copyWith(color: Q.ink)),
          const SizedBox(height: 8),
          Text(s.t('pinHint', {'phone': phoneText(_number)}),
              textAlign: TextAlign.center, style: Q.body.copyWith(fontFeatures: Q.tabular)),
        ]),
      ),
      const SizedBox(height: 40),
      Expanded(child: PinPad(onSubmit: _pin, deleteLabel: s.t('pinDelete'), expand: true)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final challenge = _challenge;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    // Шаги входа сменяют друг друга сдвигом, как экраны.
    final Widget body = switch (_step) {
      _Step.phone => _phoneStep(context, keyboard),
      _Step.code => SafeArea(top: false, child: _codeStep(context, challenge!)),
      _Step.pin => SafeArea(top: false, child: _pinStep(context)),
      _Step.name => SafeArea(top: false, child: _nameStep(context, keyboard)),
      _Step.newPin => SafeArea(top: false, child: _newPinStep(context, repeat: false)),
      _Step.repeatPin => SafeArea(top: false, child: _newPinStep(context, repeat: true)),
    };
    return PopScope(
      canPop: _step == _Step.phone,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stepBack();
      },
      child: Scaffold(
        appBar: _step == _Step.phone
            ? null
            : QAppBar(
                onBack: _stepBack,
                // Регистрация: имя, PIN, Face ID, карта.
                middle: switch (_step) {
                  _Step.name => const StepsBar(count: 4, done: 1),
                  _Step.newPin || _Step.repeatPin => const StepsBar(count: 4, done: 2),
                  _ => null,
                },
              ),
        body: _StepSwitcher(step: _step.index, child: KeyedSubtree(key: ValueKey(_step), child: body)),
      ),
    );
  }
}

/// Смена шагов входа: новый шаг въезжает сдвигом и проявляется — вперёд справа, назад слева.
/// Старый шаг убирается сразу, чтобы на экране никогда не было двух клавиатур или полей.
class _StepSwitcher extends StatefulWidget {
  const _StepSwitcher({required this.step, required this.child});
  final int step;
  final Widget child;

  @override
  State<_StepSwitcher> createState() => _StepSwitcherState();
}

class _StepSwitcherState extends State<_StepSwitcher> {
  bool _forward = true;

  @override
  void didUpdateWidget(_StepSwitcher old) {
    super.didUpdateWidget(old);
    if (old.step != widget.step) _forward = widget.step > old.step;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final dir = _forward ? 1.0 : -1.0;
    return TweenAnimationBuilder<double>(
      key: ValueKey(widget.step),
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: reduced ? 150 : (_forward ? 300 : 200)),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: reduced ? child : FractionalTranslation(translation: Offset(dir * 0.08 * (1 - t), 0), child: child),
      ),
      child: widget.child,
    );
  }
}
