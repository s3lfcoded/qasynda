import 'package:material_ui/material_ui.dart';

import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

/// «Безопасность»: скрывать суммы, запрет скриншотов (по умолчанию включён), вход по Face ID.
class SecurityScreen extends StatelessWidget {
  const SecurityScreen({super.key});

  Future<void> _setBio(BuildContext context, AppState app, bool value) async {
    final ok = await app.setBiometric(value);
    if (!ok && context.mounted) showError(context, app.s.t('bioFailed'));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.s;
    return Scaffold(
      appBar: QAppBar(title: s.t('security')),
      body: SafeArea(
        top: false,
        child: ListView(padding: const EdgeInsets.fromLTRB(Q.gutter, 8, Q.gutter, 24), children: [
          QGroup(children: [
            QRow(
              title: s.t('hideSensitive'),
              subtitle: s.t('hideSensitiveHint'),
              trailing: QToggle(value: app.hideSensitive, onChanged: app.setHideSensitive),
              onTap: () => app.setHideSensitive(!app.hideSensitive),
            ),
            QRow(
              title: s.t('noShots'),
              subtitle: s.t('noShotsHint'),
              trailing: QToggle(value: app.blockScreenshots, onChanged: app.setBlockScreenshots),
              onTap: () => app.setBlockScreenshots(!app.blockScreenshots),
            ),
            if (app.biometricAvailable)
              QRow(
                title: s.t('bio'),
                trailing: QToggle(value: app.biometricEnabled, onChanged: (value) => _setBio(context, app, value)),
                onTap: () => _setBio(context, app, !app.biometricEnabled),
              ),
          ]),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(s.t('detailsNote'), style: Q.secondary),
          ),
        ]),
      ),
    );
  }
}
