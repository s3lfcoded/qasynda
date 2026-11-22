import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalCupertinoLocalizations, GlobalWidgetsLocalizations;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'screens/home.dart';
import 'screens/lock.dart';
import 'screens/login.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(darkOverlay);
  runApp(QasyndaApp(state: AppState()..boot()));
}

class QasyndaApp extends StatelessWidget {
  const QasyndaApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => MaterialApp(
          title: 'Qasynda',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          locale: Locale(state.lang),
          supportedLocales: const [Locale('ru'), Locale('kk')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: !state.ready
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : !state.loggedIn
                  ? const LoginScreen()
                  : state.locked
                      ? const LockScreen()
                      : const HomeScreen(),
          // Пока приложение в фоне, поверх всего — заставка: в списке открытых приложений не видно баланса.
          builder: (context, child) => Stack(children: [
            ?child,
            if (state.covered) const Positioned.fill(child: PrivacyCover()),
          ]),
        ),
      ),
    );
  }
}
