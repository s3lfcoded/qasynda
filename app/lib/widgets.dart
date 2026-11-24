import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'state.dart';
import 'theme.dart';
import 'widgets/mark.dart';

export 'widgets/mark.dart';
export 'widgets/rolling_amount.dart';

/// Шапка 56: кнопка «назад» 44×44 в 8 от края, заголовок 17/600 через 4 после неё.
class QAppBar extends StatelessWidget implements PreferredSizeWidget {
  const QAppBar({super.key, this.title, this.back = true, this.onBack, this.actions = const [], this.middle});
  final String? title;

  /// Вместо заголовка, например полоска шагов регистрации.
  final Widget? middle;
  final bool back;
  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final title = this.title;
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 56,
        child: Row(children: [
          const SizedBox(width: 8),
          if (back)
            IconButton(
              onPressed: onBack ?? () => Navigator.maybePop(context),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              style: IconButton.styleFrom(fixedSize: const Size.square(44), minimumSize: const Size.square(44)),
              icon: const Icon(Icons.arrow_back_rounded, color: Q.ink),
            ),
          const SizedBox(width: 4),
          if (middle != null)
            Expanded(child: middle!)
          else if (title != null)
            Expanded(
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Q.appBar.copyWith(color: Q.ink)),
            )
          else
            const Spacer(),
          ...actions,
          const SizedBox(width: 8),
        ]),
      ),
    );
  }
}

/// Нажатие: лёгкое сжатие до 0.97 за 100 мс.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool value) {
    if (_down != value && mounted) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: widget.enabled ? (_) => _set(true) : null,
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

enum QButtonKind { primary, secondary, danger }

/// Кнопка во всю ширину: высота 56, радиус 16.
class QButton extends StatelessWidget {
  const QButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = QButtonKind.primary,
    this.icon,
    this.busy = false,
    this.busyLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final QButtonKind kind;
  final IconData? icon;
  final bool busy;

  /// Подпись рядом с индикатором, пока идёт долгое ожидание («Сервер просыпается…»).
  final String? busyLabel;

  @override
  Widget build(BuildContext context) {
    final (bg, press, fg) = switch (kind) {
      QButtonKind.primary => (Q.accent, Q.accentPress, Q.onAccent),
      QButtonKind.secondary => (Q.surface, Q.surface2, Q.ink),
      QButtonKind.danger => (Q.dangerSoft, const Color(0xFFF6DAD7), Q.danger),
    };
    final enabled = onPressed != null && !busy;
    return Pressable(
      enabled: enabled,
      child: FilledButton(
        onPressed: busy ? () {} : onPressed,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (busy) return busyLabel != null ? press : bg;
            if (states.contains(WidgetState.disabled)) return Q.surface2;
            if (states.contains(WidgetState.pressed)) return press;
            return bg;
          }),
          foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled) ? Q.ink3 : fg),
        ),
        child: busy
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: fg)),
                if (busyLabel != null) ...[
                  const SizedBox(width: 12),
                  Flexible(child: Text(busyLabel!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg))),
                ],
              ])
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
                Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
      ),
    );
  }
}

/// Нижняя кнопка: 8 до safe area снизу.
class BottomAction extends StatelessWidget {
  const BottomAction({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(padding: const EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, 8), child: child),
      );
}

/// Компактный переключатель языка «Рус / Қаз» для первого экрана входа.
class LangToggle extends StatelessWidget {
  const LangToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Container(
      height: 36,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Q.surface, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (code, label) in const [('ru', 'Рус'), ('kk', 'Қаз')])
          _Segment(
            label: label,
            active: app.lang == code,
            onTap: () => app.setLang(code),
            radius: 999,
            fontSize: 14,
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
      ]),
    );
  }
}

/// Переключатель языка в настройках: «Русский / Қазақша» во всю ширину.
class LangSegments extends StatelessWidget {
  const LangSegments({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Q.surface, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        for (final (code, label) in const [('ru', 'Русский'), ('kk', 'Қазақша')])
          Expanded(
            child: _Segment(label: label, active: app.lang == code, onTap: () => app.setLang(code), radius: 8, fontSize: 15),
          ),
      ]),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.active,
    required this.onTap,
    required this.radius,
    required this.fontSize,
    this.padding = EdgeInsets.zero,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;
  final double radius;
  final double fontSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: padding,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? Q.bg : Q.surface,
            borderRadius: BorderRadius.circular(radius),
            boxShadow: active ? const [BoxShadow(color: Color(0x1F141E1C), blurRadius: 3, offset: Offset(0, 1))] : null,
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: fontSize, height: 20 / fontSize, fontWeight: FontWeight.w600, color: active ? Q.ink : Q.ink2)),
        ),
      ),
    );
  }
}

enum AvatarKind { initial, shop, me, bot, botShop, topup }

/// Аватар 48: инициал на surface2, «я» на accentSoft, ИП — скруглённый квадрат с витриной.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.kind = AvatarKind.initial, this.size = 48});
  final String name;
  final AvatarKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      AvatarKind.initial => (Q.surface2, Q.ink),
      AvatarKind.shop || AvatarKind.me || AvatarKind.topup => (Q.accentSoft, Q.accentInk),
      AvatarKind.bot || AvatarKind.botShop => (Q.botSoft, Q.botInk),
    };
    final square = kind == AvatarKind.shop || kind == AvatarKind.botShop;
    final icon = switch (kind) {
      AvatarKind.shop => Icons.storefront_rounded,
      AvatarKind.botShop => Icons.local_cafe_rounded,
      AvatarKind.topup => Icons.add_rounded,
      _ => null,
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(square ? 16 : size / 2)),
      child: icon != null
          ? Icon(icon, color: fg, size: size / 2)
          : Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: TextStyle(fontSize: size * 0.375, height: 1, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

enum TagKind { bluetooth, gps, merchant, neutral, bot }

/// Тег 24: Bluetooth — бирюзовый, GPS — янтарный, «ИП в банке» — белый с галочкой.
class QTag extends StatelessWidget {
  const QTag({super.key, required this.kind, required this.label});
  final TagKind kind;
  final String label;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon, iconColor) = switch (kind) {
      TagKind.bluetooth => (Q.accentSoft, Q.accentInk, Icons.bluetooth_rounded, Q.accentInk),
      TagKind.gps => (Q.amberSoft, Q.amberInk, Icons.location_on_rounded, Q.amberInk),
      TagKind.merchant => (Q.bg, Q.ink, Icons.verified_rounded, Q.accent),
      TagKind.neutral => (Q.surface2, Q.ink, null, Q.ink),
      TagKind.bot => (Q.botSoft, Q.botInk, Icons.smart_toy_rounded, Q.botInk),
    };
    return Container(
      height: 24,
      padding: EdgeInsets.only(left: icon == null ? 8 : 4, right: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: kind == TagKind.merchant ? Border.all(color: Q.line) : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 16, color: iconColor), const SizedBox(width: 4)],
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Q.tag.copyWith(color: fg)),
        ),
      ]),
    );
  }
}

/// Группа в духе inset grouped: фон surface, радиус 20, разделители 1 pt.
class QGroup extends StatelessWidget {
  const QGroup({super.key, required this.children, this.dividerIndent = 16, this.padding = EdgeInsets.zero});
  final List<Widget> children;
  final double dividerIndent;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Q.surface,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, indent: dividerIndent, color: Q.line),
            children[i],
          ],
        ]),
      ),
    );
  }
}

/// Подзаголовок группы: 15/600, 24 сверху, 8 снизу.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.top = 24});
  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(4, top, 4, 8),
        child: Text(text, style: Q.label.copyWith(color: Q.ink2)),
      );
}

/// Тумблер 52×32.
class QToggle extends StatelessWidget {
  const QToggle({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: 52,
          height: 32,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(color: value ? Q.accent : Q.surface2, borderRadius: BorderRadius.circular(16)),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Color(0x2E000000), blurRadius: 4, offset: Offset(0, 2))],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Кольца радиуса вокруг аватара на «Принять рядом»: ближний круг залит accentSoft, раз в несколько
/// секунд от него расходится едва заметная волна.
class RadiusRings extends StatefulWidget {
  const RadiusRings({super.key, required this.child, this.size = 256});
  final Widget child;
  final double size;

  @override
  State<RadiusRings> createState() => _RadiusRingsState();
}

class _RadiusRingsState extends State<RadiusRings> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _RingsPainter(_c),
        child: Center(child: widget.child),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.wave) : super(repaint: wave);
  final AnimationController wave;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final k = size.shortestSide / 256;
    Paint ring(double alpha) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Q.accent.withValues(alpha: alpha);
    canvas.drawCircle(c, 126 * k, ring(0.10));
    canvas.drawCircle(c, 96 * k, ring(0.18));
    if (wave.isAnimating) {
      final t = Curves.easeOut.transform(wave.value);
      canvas.drawCircle(c, (66 + 60 * t) * k, ring(0.16 * (1 - t)));
    }
    canvas.drawCircle(c, 66 * k, Paint()..color = Q.accentSoft);
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) => false;
}

/// Маленький радар 56 в баннере поиска: два кольца, центр и точка, которая медленно обходит круг.
class SearchRadar extends StatefulWidget {
  const SearchRadar({super.key, this.color = Q.accent});
  final Color color;

  @override
  State<SearchRadar> createState() => _SearchRadarState();
}

class _SearchRadarState extends State<SearchRadar> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 4000));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: 56, child: CustomPaint(painter: _SearchPainter(_c, widget.color)));
}

class _SearchPainter extends CustomPainter {
  _SearchPainter(this.turn, this.color) : super(repaint: turn);
  final AnimationController turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    Paint ring(double a) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color.withValues(alpha: a);
    canvas.drawCircle(c, 27, ring(0.14));
    canvas.drawCircle(c, 18, ring(0.28));
    canvas.drawCircle(c, 9, Paint()..color = color);
    // Точка стоит на северо-востоке, как стрелка знака, и медленно обходит внешнее кольцо.
    final a = -0.574 + turn.value * 2 * math.pi;
    canvas.drawCircle(c + Offset.fromDirection(a, 20.2), 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SearchPainter oldDelegate) => oldDelegate.color != color;
}

/// Баланс, номер, суммы и карта: при включённой настройке показываются точками и открываются
/// нажатием на 5 секунд. Так их нет ни на скриншоте, ни на записи экрана, если специально не открыть.
class Sensitive extends StatefulWidget {
  const Sensitive({super.key, required this.builder});
  final Widget Function(BuildContext context, bool shown) builder;

  @override
  State<Sensitive> createState() => _SensitiveState();
}

class _SensitiveState extends State<Sensitive> {
  bool _shown = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    _timer?.cancel();
    setState(() => _shown = !_shown);
    if (_shown) _timer = Timer(const Duration(seconds: 5), () => mounted ? setState(() => _shown = false) : null);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (!app.hideSensitive) return widget.builder(context, true);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      child: Semantics(
        hint: app.s.t('tapToShow'),
        child: widget.builder(context, _shown),
      ),
    );
  }
}

/// Заставка поверх приложения, пока оно в фоне: в списке открытых приложений не видно баланса.
class PrivacyCover extends StatelessWidget {
  const PrivacyCover({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Q.bg,
      alignment: Alignment.center,
      child: Container(
        width: 80,
        height: 80,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Q.accent, borderRadius: BorderRadius.circular(20)),
        child: const QasyndaMark(size: 56, color: Q.onAccent),
      ),
    );
  }
}

const masked = '••••';

void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Строка группы: от 56, padding 12/16, иконка или аватар → текст 12.
class QRow extends StatelessWidget {
  const QRow({
    super.key,
    required this.title,
    this.icon,
    this.leading,
    this.subtitle,
    this.subtitleStyle,
    this.value,
    this.trailing,
    this.chevron = false,
    this.onTap,
    this.minHeight = 56,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.titleColor = Q.ink,
  });
  final String title;
  final IconData? icon;
  final Widget? leading;
  final String? subtitle;
  final TextStyle? subtitleStyle;
  final String? value;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;
  final double minHeight;
  final EdgeInsets padding;
  final Color titleColor;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final value = this.value;
    final lead = leading ?? (icon != null ? Icon(icon, color: Q.ink) : null);
    return InkWell(
      onTap: onTap,
      highlightColor: Q.surface2,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Padding(
          padding: padding,
          child: Row(
            crossAxisAlignment: subtitle != null && leading == null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              if (lead != null) ...[lead, const SizedBox(width: 12)],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(title, style: Q.rowTitle.copyWith(color: titleColor)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(subtitle, style: subtitleStyle ?? Q.secondary),
                  ],
                ]),
              ),
              if (value != null) ...[
                const SizedBox(width: 8),
                Text(value, style: const TextStyle(fontSize: 15, height: 20 / 15, color: Q.ink2)),
              ],
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              if (chevron) ...[const SizedBox(width: 4), const Icon(Icons.chevron_right_rounded, color: Q.ink3)],
            ],
          ),
        ),
      ),
    );
  }
}

/// Шторка снизу: радиус сверху 24, ручка 36×4 (8 от верха, 16 под ней), поля 20, затемнение ink 40%.
Future<T?> showQSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Q.bg,
    barrierColor: Q.ink.withValues(alpha: 0.4),
    isScrollControlled: true,
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 280),
      reverseDuration: Duration(milliseconds: 200),
    ),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: Q.surface2, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          builder(context),
        ]),
      ),
    ),
  );
}

/// Пояснение с иконкой слева: 14/20 ink2, иконка 20, зазор 12.
class QNote extends StatelessWidget {
  const QNote({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: Q.ink2),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: Q.secondary)),
      ]);
}

/// Полоска шагов регистрации: сегменты 4 pt, зазор 4, заполненные — accent.
class StepsBar extends StatelessWidget {
  const StepsBar({super.key, required this.count, required this.done, this.end = 56});
  final int count;
  final int done;

  /// Отступ справа: по умолчанию как кнопка «назад» слева, чтобы полоска стояла по центру.
  final double end;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: 8, right: end),
        child: Row(children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                height: 4,
                decoration: BoxDecoration(color: i < done ? Q.accent : Q.surface2, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ],
        ]),
      );
}

/// Янтарная плашка «учебное»: иконка 20, текст 13/16, радиус 16, от 40 в высоту.
class Plaque extends StatelessWidget {
  const Plaque({super.key, required this.text, this.icon = Icons.school_outlined, this.center = false});
  final String text;
  final IconData icon;
  final bool center;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: Q.amberSoft, borderRadius: BorderRadius.circular(16)),
        child: Row(mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start, children: [
          Icon(icon, size: 20, color: Q.amberInk),
          const SizedBox(width: 8),
          Flexible(
            child: Text(text, style: const TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w600, color: Q.amberInk)),
          ),
        ]),
      );
}
