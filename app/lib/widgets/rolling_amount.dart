import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// easeOutCubic — единая кривая для roll и ввода цифр.
const rollCurve = Cubic(0.33, 1, 0.68, 1);
const _exitCurve = Cubic(0.32, 0, 0.67, 0);

/// Ширина символа в стиле с учётом шрифта по умолчанию и масштаба текста.
class _Measure {
  _Measure(BuildContext context, TextStyle style)
      : _style = DefaultTextStyle.of(context).style.merge(style),
        _scaler = MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
        _dir = Directionality.maybeOf(context) ?? TextDirection.ltr;
  final TextStyle _style;
  final TextScaler _scaler;
  final TextDirection _dir;
  final _cache = <String, double>{};

  double width(String s) {
    if (s.isEmpty) return 0;
    return _cache.putIfAbsent(s, () {
      final p = TextPainter(text: TextSpan(text: s, style: _style), textDirection: _dir, textScaler: _scaler, maxLines: 1)
        ..layout();
      final w = p.width;
      p.dispose();
      return w;
    });
  }

  double get lineHeight => _scaler.scale(_style.fontSize ?? 14) * (_style.height ?? 1.2);
}

/// Колонка шириной [width] и высотой строки: снизу/сверху затухание 16%, внутри — символы со сдвигом
/// по вертикали в долях высоты строки.
class _Column extends StatelessWidget {
  const _Column({required this.width, required this.height, required this.glyphs, required this.style});
  final double width;
  final double height;
  final List<(String, double, double)> glyphs; // символ, сдвиг по Y, прозрачность
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: math.max(0, width),
      height: height,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
          stops: [0, 0.16, 0.84, 1],
        ).createShader(rect),
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerRight,
            maxWidth: double.infinity,
            child: Stack(alignment: Alignment.centerRight, children: [
              for (final (ch, dy, opacity) in glyphs)
                if (ch.isNotEmpty && opacity > 0)
                  FractionalTranslation(
                    translation: Offset(0, dy),
                    child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: Text(ch, style: style, maxLines: 1, softWrap: false)),
                  ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Сумма, которая спокойно прокручивается по разрядам.
///
/// * Появление: символы поднимаются снизу на одну строку, место раскрывается с нуля — 360 мс, шаг 12 мс.
/// * Открытие скрытой суммы и скрытие: точка уезжает вверх, снизу приходит цифра (и наоборот),
///   лишние разряды сжимаются — 320 мс, шаг 12 мс.
/// * Изменение: только изменившиеся разряды, кратчайшим путём — вверх при росте, вниз при уменьшении, 420 мс.
/// Хвост « ₸» стоит на месте. При «уменьшить движение» — кроссфейд 150 мс.
class RollingAmount extends StatefulWidget {
  const RollingAmount(
    this.text, {
    super.key,
    required this.style,
    this.hidden = false,
    this.mask = '••••••',
    this.rollIn = false,
    this.delay = Duration.zero,
  });

  final String text;
  final TextStyle style;

  /// Вместо числа — [mask] (баланс — 6 точек, история — 5): порядок суммы не выдаётся.
  final bool hidden;
  final String mask;

  /// Прокрутить при первом показе.
  final bool rollIn;
  final Duration delay;

  @override
  State<RollingAmount> createState() => _RollingAmountState();
}

enum _Mode { idle, swap, roll }

class _RollingAmountState extends State<RollingAmount> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this);
  _Mode _mode = _Mode.idle;
  String _from = '';
  String _to = '';
  bool _up = true;
  int _dur = 320;
  int _delay = 0;
  bool _started = false;

  static final _tail = RegExp(r'[^\d]*$');

  String _body(RollingAmount w) {
    if (w.hidden) return w.mask;
    final tail = _tail.stringMatch(w.text) ?? '';
    return w.text.substring(0, w.text.length - tail.length);
  }

  String get _suffix => _tail.stringMatch(widget.text) ?? '';

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    _to = _body(widget);
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() => _mode = _Mode.idle);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.rollIn && !_reduced) _swap('', _body(widget), 360, widget.delay.inMilliseconds);
  }

  @override
  void didUpdateWidget(RollingAmount old) {
    super.didUpdateWidget(old);
    final next = _body(widget);
    final prev = _to;
    if (next == prev) return;
    if (_reduced) {
      _to = next;
      _mode = _Mode.idle;
      return;
    }
    if (old.hidden == widget.hidden && !widget.hidden && prev.length == next.length) {
      _roll(prev, next);
    } else {
      _swap(_mode == _Mode.idle ? prev : _to, next, 320, 0);
    }
  }

  void _swap(String from, String to, int dur, int delay) {
    _from = from;
    _to = to;
    _dur = dur;
    _delay = delay;
    _mode = _Mode.swap;
    var changed = 0;
    for (var i = 0; i < math.max(from.length, to.length); i++) {
      if (_at(from, i) != _at(to, i)) changed++;
    }
    _c.duration = Duration(milliseconds: delay + dur + 12 * math.max(0, changed - 1));
    _c.forward(from: 0);
  }

  void _roll(String from, String to) {
    _from = from;
    _to = to;
    _dur = 420;
    _delay = 0;
    _up = _value(to) >= _value(from);
    _mode = _Mode.roll;
    _c.duration = const Duration(milliseconds: 420);
    _c.forward(from: 0);
  }

  static int _value(String s) {
    final d = s.replaceAll(RegExp(r'\D'), '');
    final v = d.isEmpty ? 0 : int.parse(d.length > 15 ? d.substring(0, 15) : d);
    return s.contains('−') || s.contains('-') ? -v : v;
  }

  static String _at(String s, int i) => i < s.length ? s[i] : '';

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _t(int k) {
    final ms = _c.value * (_c.duration?.inMilliseconds ?? 1);
    return rollCurve.transform(((ms - _delay - k * 12) / _dur).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final shown = _body(widget);
    Widget content;
    if (_reduced) {
      content = AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        layoutBuilder: (current, previous) =>
            Stack(alignment: AlignmentDirectional.centerStart, children: [...previous, ?current]),
        child: Text('$shown$_suffix', key: ValueKey(shown), style: style, maxLines: 1, softWrap: false),
      );
    } else {
      content = AnimatedBuilder(animation: _c, builder: (context, _) => _frame(context, style));
    }
    return Semantics(label: widget.hidden ? widget.mask : widget.text, excludeSemantics: true, child: content);
  }

  Widget _frame(BuildContext context, TextStyle style) {
    if (_mode == _Mode.idle) {
      return Text('$_to$_suffix', style: style, maxLines: 1, softWrap: false);
    }
    final m = _Measure(context, style);
    final h = m.lineHeight;
    final cells = <Widget>[];
    final run = StringBuffer();
    void flush() {
      if (run.isEmpty) return;
      cells.add(Text(run.toString(), style: style, maxLines: 1, softWrap: false));
      run.clear();
    }

    if (_mode == _Mode.swap) {
      var k = 0;
      for (var i = 0; i < math.max(_from.length, _to.length); i++) {
        final a = _at(_from, i), b = _at(_to, i);
        if (a == b) {
          run.write(b);
          continue;
        }
        flush();
        final t = _t(k++);
        final wa = m.width(a), wb = m.width(b);
        cells.add(_Column(
          width: wa + (wb - wa) * t,
          height: h,
          style: style,
          glyphs: [(a, -t, 1 - t), (b, 1 - t, t)],
        ));
      }
    } else {
      final t = _t(0);
      for (var i = 0; i < _to.length; i++) {
        final a = _at(_from, i), b = _to[i];
        final da = int.tryParse(a), db = int.tryParse(b);
        if (a == b || da == null || db == null) {
          run.write(b);
          continue;
        }
        flush();
        final steps = _up ? (db - da + 10) % 10 : -((da - db + 10) % 10);
        final v = da + steps * t;
        final base = v.floor();
        final frac = v - base;
        String digit(int x) => '${((x % 10) + 10) % 10}';
        cells.add(_Column(
          width: m.width(b),
          height: h,
          style: style,
          glyphs: [(digit(base), -frac, 1), (digit(base + 1), 1 - frac, 1)],
        ));
      }
    }
    run.write(_suffix);
    flush();
    return Row(mainAxisSize: MainAxisSize.min, children: cells);
  }
}

/// Строка ввода (номер телефона, сумма): новый знак поднимается снизу и проявляется, его место
/// раскрывается по ширине — 180 мс; стёртый уходит вниз, место сжимается — 140 мс. Если знак меняется
/// (пробел маски раскрывается перед цифрой), ширина меняется плавно. Вставка целиком — с шагом 20 мс.
/// [glyphs] — по элементу на введённый символ, с пробелом-разделителем перед ним, если он нужен.
class TypedText extends StatefulWidget {
  const TypedText({super.key, required this.glyphs, required this.style});
  final List<String> glyphs;
  final TextStyle style;

  @override
  State<TypedText> createState() => _TypedTextState();
}

class _TypedTextState extends State<TypedText> {
  int _known = 0;
  final _leaving = <(Key, String)>[];
  int _leaveId = 0;

  @override
  void initState() {
    super.initState();
    _known = widget.glyphs.length;
  }

  @override
  void didUpdateWidget(TypedText old) {
    super.didUpdateWidget(old);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!reduced && widget.glyphs.length < old.glyphs.length) {
      for (var i = widget.glyphs.length; i < old.glyphs.length; i++) {
        _leaving.add((ValueKey('leave-${_leaveId++}'), old.glyphs[i]));
      }
    } else if (widget.glyphs.length > old.glyphs.length) {
      _leaving.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final glyphs = widget.glyphs;
    final known = _known;
    _known = glyphs.length;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < glyphs.length; i++)
        _Glyph(
          key: ValueKey(i),
          text: glyphs[i],
          style: widget.style,
          enter: i >= known && !reduced,
          delay: Duration(milliseconds: i >= known ? (i - known) * 20 : 0),
        ),
      for (final (key, text) in _leaving)
        _Glyph(
          key: key,
          text: text,
          style: widget.style,
          enter: false,
          leaving: true,
          onGone: () {
            if (mounted) setState(() => _leaving.removeWhere((e) => e.$1 == key));
          },
        ),
    ]);
  }
}

class _Glyph extends StatefulWidget {
  const _Glyph({
    super.key,
    required this.text,
    required this.style,
    required this.enter,
    this.delay = Duration.zero,
    this.leaving = false,
    this.onGone,
  });
  final String text;
  final TextStyle style;
  final bool enter;
  final Duration delay;
  final bool leaving;
  final VoidCallback? onGone;

  @override
  State<_Glyph> createState() => _GlyphState();
}

class _GlyphState extends State<_Glyph> with TickerProviderStateMixin {
  late final _in = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 180 + widget.delay.inMilliseconds),
    value: widget.enter ? 0 : 1,
  );
  late final _out = AnimationController(vsync: this, duration: const Duration(milliseconds: 140));
  late final _resize = AnimationController(vsync: this, duration: const Duration(milliseconds: 180), value: 1);
  String _old = '';

  @override
  void initState() {
    super.initState();
    if (widget.enter) _in.forward();
    if (widget.leaving) {
      _out.forward().whenComplete(() => widget.onGone?.call());
    }
  }

  @override
  void didUpdateWidget(_Glyph old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _old = old.text;
      _resize.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    _resize.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_in, _out, _resize]),
      builder: (context, _) {
        final m = _Measure(context, widget.style);
        final w = m.width(widget.text);
        final delay = widget.delay.inMilliseconds;
        final total = _in.duration!.inMilliseconds;
        final tin = rollCurve.transform((((_in.value * total) - delay) / 180).clamp(0.0, 1.0));
        final tout = _exitCurve.transform(_out.value);
        final tr = rollCurve.transform(_resize.value);
        if (tin >= 1 && tout <= 0 && tr >= 1) {
          return Text(widget.text, style: widget.style, maxLines: 1, softWrap: false);
        }
        var width = w;
        if (tr < 1) width = m.width(_old) + (w - m.width(_old)) * tr;
        width *= tin * (1 - tout);
        return _Column(
          width: width,
          height: m.lineHeight,
          style: widget.style,
          glyphs: [(widget.text, (1 - tin) + tout, tin * (1 - tout))],
        );
      },
    );
  }
}
