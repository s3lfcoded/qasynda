import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'send.dart' show limitBluetooth, limitGps;

/// Контакты поддержки — заглушки, их заменят настоящими.
const supportTelegram = 'qasynda_support';
const supportPhone = '+77000000000';

/// «Поддержка»: частые вопросы (первый раскрыт), внизу — Telegram и звонок.
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key, this.open});

  /// Открытие ссылок; в тестах подменяется.
  final Future<bool> Function(Uri uri)? open;

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  int? _expanded = 0;

  Future<void> _launch(Uri uri, {Uri? fallback}) async {
    final s = AppScope.of(context).s;
    final open = widget.open ?? (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    var ok = false;
    try {
      ok = await open(uri);
      if (!ok && fallback != null) ok = await open(fallback);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) showError(context, s.t('cantOpen'));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).s;
    final sums = {'bt': money(limitBluetooth), 'gps': money(limitGps), 'min': money(100 * 100)};
    return Scaffold(
      appBar: QAppBar(title: s.t('support')),
      body: SafeArea(
        top: false,
        child: CustomScrollView(slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Q.gutter, 0, Q.gutter, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SectionLabel(s.t('faq'), top: 8),
                QGroup(children: [
                  for (var i = 0; i < 7; i++)
                    _FaqItem(
                      question: s.t('faq${i + 1}q'),
                      answer: s.t('faq${i + 1}a', sums),
                      expanded: _expanded == i,
                      onTap: () => setState(() => _expanded = _expanded == i ? null : i),
                    ),
                ]),
                const Spacer(),
                const SizedBox(height: 24),
                Text(s.t('noAnswer'), textAlign: TextAlign.center, style: Q.secondary),
                const SizedBox(height: 12),
                QButton(
                  icon: Icons.chat_outlined,
                  label: s.t('writeTelegram'),
                  onPressed: () => _launch(
                    Uri.parse('tg://resolve?domain=$supportTelegram'),
                    fallback: Uri.parse('https://t.me/$supportTelegram'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 44,
                  child: TextButton.icon(
                    onPressed: () => _launch(Uri(scheme: 'tel', path: supportPhone)),
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontFamily: Q.font, fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w600),
                    ),
                    icon: const Icon(Icons.call_outlined, size: 20),
                    label: Text('${s.t('call')} ${phoneText(supportPhone)}', style: const TextStyle(fontFeatures: Q.tabular)),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Вопрос, который раскрывается за 240 мс; шеврон поворачивается на 180°.
class _FaqItem extends StatelessWidget {
  const _FaqItem({required this.question, required this.answer, required this.expanded, required this.onTap});
  final String question;
  final String answer;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const duration = Duration(milliseconds: 240);
    return Semantics(
      expanded: expanded,
      child: InkWell(
        onTap: onTap,
        highlightColor: Q.surface2,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            // 16 сверху и снизу: строка из одной линии — 56, вопрос по центру шеврона.
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: AnimatedSize(
                  duration: duration,
                  curve: rollCurve,
                  alignment: Alignment.topCenter,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const SizedBox(height: 2),
                    Text(question, style: Q.rowTitle.copyWith(color: Q.ink)),
                    if (expanded) ...[
                      const SizedBox(height: 8),
                      Text(answer, style: const TextStyle(fontSize: 15, height: 20 / 15, color: Q.ink2)),
                    ],
                  ]),
                ),
              ),
              const SizedBox(width: 12),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: duration,
                curve: rollCurve,
                child: const Icon(Icons.expand_more_rounded, color: Q.ink2),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
