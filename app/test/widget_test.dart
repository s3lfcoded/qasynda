import 'package:flutter_test/flutter_test.dart';
import 'package:qasynda/l10n.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qasynda/nearby.dart';
import 'package:qasynda/state.dart';
import 'package:qasynda/widgets.dart';

void main() {
  test('money formats tiyn as tenge', () {
    expect(money(0), '0 ₸');
    expect(money(350000), '3 500 ₸');
    expect(money(125000050), '1 250 000,50 ₸');
  });

  test('beacon id survives the trip through a service UUID', () {
    const id = '0123456789abcdef';
    final uuid = uuidForBleId(id);
    expect(uuid, '71617379-6e64-6121-0123-456789abcdef');
    expect(bleIdFromUuid(uuid.toUpperCase()), id);
    expect(bleIdFromUuid('0000180f-0000-1000-8000-00805f9b34fb'), isNull);
  });

  test('kazakh falls back to russian and unknown errors are generic', () {
    expect(const S('kk').t('login'), 'Кіру');
    expect(const S('kk').t('pay', {'sum': '5 ₸'}), '5 ₸ аудару');
    expect(const S('ru').error('no_such_code'), 'Что-то пошло не так');
  });

  test('server limits are explained with time and money', () {
    expect(const S('ru').error('too_many_attempts', {'retry_after': 290}), 'Слишком много попыток. Попробуйте через 5 мин');
    expect(const S('ru').error('too_many_attempts', {'retry_after': 80000}), 'Слишком много попыток. Попробуйте через 23 ч');
    expect(const S('ru').error('daily_limit_exceeded', {'left': 100000}), endsWith(money(100000)));
    expect(const S('kk').error('amount_too_small', {'min': 10000}), 'Ең аз сома — ${money(10000)}');
  });

  testWidgets('sensitive values are dots until tapped and hide again after 5 seconds', (tester) async {
    final state = AppState();
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(
        home: Scaffold(body: Sensitive(builder: (_, shown) => Text(shown ? '250 000 ₸' : masked))),
      ),
    ));
    expect(find.text(masked), findsOneWidget);
    await tester.tap(find.text(masked));
    await tester.pump();
    expect(find.text('250 000 ₸'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.text(masked), findsOneWidget);

    // Хранилище в тестах не отвечает, поэтому запись не ждём: настройка меняется сразу, в памяти.
    state.setHideSensitive(false);
    await tester.pump();
    expect(find.text('250 000 ₸'), findsOneWidget);
  });
}
