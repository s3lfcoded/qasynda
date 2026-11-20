import 'package:material_ui/material_ui.dart';

import 'state.dart';
import 'theme.dart';

class QCard extends StatelessWidget {
  const QCard({super.key, required this.child, this.color = Q.surface, this.padding = const EdgeInsets.all(20), this.onTap});
  final Widget child;
  final Color color;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      // На чёрном фоне тёмную поверхность отделяет тонкая линия, а не тень.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Q.radius),
        side: color == Q.surface ? const BorderSide(color: Q.line) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// Переключатель языка РУС / ҚАЗ.
class LangToggle extends StatelessWidget {
  const LangToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    Widget item(String code, String label) {
      final active = app.lang == code;
      return GestureDetector(
        onTap: () => app.setLang(code),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: active ? Q.text : Colors.transparent, borderRadius: BorderRadius.circular(11)),
          child: Text(label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: active ? Q.onAccent : Q.muted)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Q.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Q.line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [item('ru', 'РУС'), item('kk', 'ҚАЗ')]),
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.merchant = false, this.size = 52});
  final String name;
  final bool merchant;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: merchant ? Q.accent : Q.raised, borderRadius: BorderRadius.circular(size * 0.36)),
      child: merchant
          ? Icon(Icons.storefront_rounded, color: Q.onAccent, size: size * 0.5)
          : Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w800, color: Q.text)),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
        ),
      ]),
    );
  }
}

/// Расходящиеся круги: «идёт поиск» или «вас видят».
class Radar extends StatefulWidget {
  const Radar({super.key, required this.child, this.size = 220, this.color = Q.accent});
  final Widget child;
  final double size;
  final Color color;

  @override
  State<Radar> createState() => _RadarState();
}

class _RadarState extends State<Radar> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, child) => CustomPaint(painter: _RadarPainter(_controller.value, widget.color), child: child),
        child: Center(child: widget.child),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final max = size.shortestSide / 2;
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: (1 - phase) * 0.45);
      canvas.drawCircle(center, max * (0.35 + 0.65 * phase), paint);
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.t != t || old.color != color;
}

void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
