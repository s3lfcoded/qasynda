import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qasynda/theme.dart';
import 'package:qasynda/widgets/code_cells.dart';
import 'package:qasynda/widgets/pin_pad.dart';

Widget _host(Widget child) => MaterialApp(theme: buildTheme(), home: Scaffold(body: Center(child: child)));

/// Перехватывает системный канал: тактильный отклик записывается, буфер обмена отдаёт [clipboard].
List<String> _platform(WidgetTester tester, {String? clipboard}) {
  final haptics = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') haptics.add('${call.arguments}');
    if (call.method == 'Clipboard.getData') return clipboard == null ? null : {'text': clipboard};
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return haptics;
}

int _filledDots(WidgetTester tester) => List.generate(4, (i) => i)
    .where((i) => (tester.widget<Container>(find.byKey(ValueKey('pin-dot-$i'))).decoration as BoxDecoration).color == Q.accent)
    .length;

Future<void> _type(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.text(d));
    await tester.pump();
  }
}

List<String> _cells(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byType(CodeCells), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .where((t) => RegExp(r'^\d$').hasMatch(t))
    .toList();

void main() {
  testWidgets('PIN pad: sends after the 4th digit, ignores input while waiting, shakes and clears on error', (tester) async {
    final haptics = _platform(tester);
    final submitted = <String>[];
    var answer = Completer<bool>();
    await tester.pumpWidget(_host(PinPad(
      onSubmit: (pin) {
        submitted.add(pin);
        return answer.future;
      },
      leading: const Icon(Icons.fingerprint_rounded),
    )));
    expect(find.byIcon(Icons.fingerprint_rounded), findsOneWidget);

    await _type(tester, '123');
    expect(_filledDots(tester), 3);
    await tester.tap(find.byIcon(Icons.backspace_outlined));
    await tester.pump();
    expect(_filledDots(tester), 2);
    await _type(tester, '34');
    expect(submitted, ['1234']);
    expect(_filledDots(tester), 4);
    expect(haptics.where((h) => h == 'HapticFeedbackType.selectionClick').length, 6);

    // Пока сервер не ответил, нажатия не принимаются.
    await _type(tester, '5');
    expect(submitted, ['1234']);

    answer.complete(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_filledDots(tester), 0);
    expect(haptics, contains('HapticFeedbackType.heavyImpact'));

    answer = Completer<bool>()..complete(true);
    await _type(tester, '0000');
    await tester.pump();
    expect(submitted, ['1234', '0000']);
    expect(_filledDots(tester), 4);
  });

  testWidgets('PIN pad: digits from a hardware keyboard work too', (tester) async {
    _platform(tester);
    final submitted = <String>[];
    await tester.pumpWidget(_host(PinPad(onSubmit: (pin) async {
      submitted.add(pin);
      return true;
    })));
    await tester.pump();
    for (final key in [LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit1, LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit9]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    expect(submitted, ['7259']);
  });

  testWidgets('code cells: one-time-code autofill, digits only, auto-submit on the 6th digit, paste', (tester) async {
    final haptics = _platform(tester, clipboard: 'Qasynda: код входа с нового телефона 654321. Никому его не сообщайте.');
    final codes = <String>[];
    await tester.pumpWidget(_host(SizedBox(
      width: 360,
      child: CodeCells(
        pasteLabel: 'Вставить код',
        onCompleted: (code) async {
          codes.add(code);
          return code == '654321';
        },
      ),
    )));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofillHints, contains(AutofillHints.oneTimeCode));
    expect(field.keyboardType, TextInputType.number);

    await tester.enterText(find.byType(TextField), '12 3-45');
    await tester.pump();
    expect(_cells(tester), ['1', '2', '3', '4', '5']);
    expect(codes, isEmpty);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(codes, ['123456']);
    expect(_cells(tester), isEmpty, reason: 'wrong code clears the cells');
    expect(haptics, contains('HapticFeedbackType.heavyImpact'));

    await tester.tap(find.text('Вставить код'));
    await tester.pump();
    await tester.pump();
    expect(codes, ['123456', '654321']);
    expect(_cells(tester), ['6', '5', '4', '3', '2', '1']);
  });
}
