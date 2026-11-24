import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../cards.dart';
import '../cards_l10n.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'cards.dart';
import 'security.dart';
import 'support.dart';

/// Настройки: скрытие сумм, Face ID и устройства, на которых открыт аккаунт.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AppState _app;
  bool _started = false;
  List<Map<String, dynamic>>? _devices;
  int? _cardCount;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _app = AppScope.of(context);
    _load();
    _loadCards();
  }

  /// Счётчик в строке «Мои карты»: привязанные карты и учебная карта Qasynda.
  Future<void> _loadCards() async {
    try {
      final list = await CardsApi(_app.api).list();
      if (mounted) setState(() => _cardCount = list.items.length + 1);
    } catch (_) {
      // Без счётчика строка всё равно открывает «Мои карты».
    }
  }

  Future<void> _load() async {
    try {
      final items = await _app.devices();
      if (mounted) setState(() => _devices = items);
    } on ApiError catch (e) {
      if (mounted) showError(context, _app.s.error(e.code, e.detail));
    }
  }

  Future<bool> _ask(String text) async {
    final s = _app.s;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.t('kick'), style: const TextStyle(color: Q.danger)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on ApiError catch (e) {
      if (mounted) showError(context, _app.s.error(e.code, e.detail));
    }
    await _load();
  }

  String _when(num seconds) {
    final at = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.day)}.${two(at.month)}, ${two(at.hour)}:${two(at.minute)}';
  }

  /// Шторка выбора языка.
  Future<void> _pickLanguage() async {
    final app = _app;
    await showQSheet<void>(
      context,
      (context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(app.s.t('language'), style: Q.appBar.copyWith(color: Q.ink)),
        const SizedBox(height: 16),
        QGroup(children: [
          for (final (code, label) in const [('ru', 'Русский'), ('kk', 'Қазақша')])
            QRow(
              title: label,
              trailing: app.lang == code
                  ? const Icon(Icons.check_circle_rounded, color: Q.accent)
                  : const Icon(Icons.radio_button_unchecked_rounded, color: Q.ink3),
              onTap: () {
                app.setLang(code);
                Navigator.pop(context);
              },
            ),
        ]),
      ]),
    );
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    _loadCards();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    final devices = _devices;
    final others = devices?.where((d) => d['current'] != true).toList() ?? const [];

    return Scaffold(
      appBar: QAppBar(title: s.t('settings')),
      body: SafeArea(
        top: false,
        child: CustomScrollView(slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                QGroup(dividerIndent: 52, children: [
                  QRow(
                    icon: Icons.credit_card_rounded,
                    title: CardText(app.lang).t('title'),
                    value: _cardCount == null ? null : '$_cardCount',
                    chevron: true,
                    onTap: () => _open(const CardsScreen()),
                  ),
                  QRow(
                    icon: Icons.shield_outlined,
                    title: s.t('security'),
                    chevron: true,
                    onTap: () => _open(const SecurityScreen()),
                  ),
                  QRow(
                    icon: Icons.support_agent_rounded,
                    title: s.t('support'),
                    chevron: true,
                    onTap: () => _open(const SupportScreen()),
                  ),
                  QRow(
                    icon: Icons.language_rounded,
                    title: s.t('language'),
                    value: app.lang == 'kk' ? 'Қазақша' : 'Русский',
                    chevron: true,
                    onTap: _pickLanguage,
                  ),
                ]),
                SectionLabel(s.t('devices')),
                if (devices == null)
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                else
                  QGroup(dividerIndent: 68, children: [
                    for (final device in devices)
                      QRow(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(color: Q.bg, shape: BoxShape.circle),
                          child: Icon(
                            '${device['name']}' == 'iPhone' ? Icons.phone_iphone_rounded : Icons.smartphone_rounded,
                            size: 20,
                            color: Q.ink,
                          ),
                        ),
                        title: '${device['name']}',
                        subtitle: device['current'] == true
                            ? s.t('thisDevice')
                            : s.t('lastSeen', {'when': _when(device['last_seen'] as num)}),
                        subtitleStyle: device['current'] == true
                            ? Q.secondary.copyWith(color: Q.accentInk, fontWeight: FontWeight.w500)
                            : Q.secondary.copyWith(fontFeatures: Q.tabular),
                        trailing: device['current'] == true
                            ? null
                            : TextButton(
                                onPressed: () async {
                                  if (await _ask(s.t('kickConfirm', {'name': '${device['name']}'}))) {
                                    await _run(() => app.removeDevice('${device['id']}'));
                                  }
                                },
                                style: TextButton.styleFrom(
                                  backgroundColor: Q.dangerSoft,
                                  foregroundColor: Q.danger,
                                  minimumSize: const Size(0, 36),
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  shape: const StadiumBorder(),
                                ),
                                child: Text(s.t('kick')),
                              ),
                      ),
                    if (others.isNotEmpty)
                      InkWell(
                        onTap: () async {
                          if (await _ask('${s.t('kickOthers')}?')) await _run(app.logoutOthers);
                        },
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 48),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Text(s.t('kickOthers'),
                              textAlign: TextAlign.center, style: Q.label.copyWith(color: Q.danger)),
                        ),
                      ),
                  ]),
                const Spacer(),
                const SizedBox(height: 24),
                QButton(
                  kind: QButtonKind.danger,
                  icon: Icons.logout_rounded,
                  label: s.t('forgot'),
                  onPressed: () async {
                    Navigator.of(context).popUntil((route) => route.isFirst);
                    await app.logout();
                  },
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

}
