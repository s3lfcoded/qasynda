import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qasynda/api.dart';
import 'package:qasynda/cards.dart';
import 'package:qasynda/cards_l10n.dart';
import 'package:qasynda/screens/add_card.dart';
import 'package:qasynda/screens/card_scan.dart';
import 'package:qasynda/state.dart';

TextEditingValue _type(TextInputFormatter f, String old, String text) => f.formatEditUpdate(
      TextEditingValue(text: old, selection: TextSelection.collapsed(offset: old.length)),
      TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length)),
    );

const cardText = CardText('ru');

void main() {
  final now = DateTime(2026, 11, 24);

  test('Luhn', () {
    for (final ok in ['4111111111111111', '5555 5555 5555 4444', '79927398713', '6200000000000005']) {
      expect(luhnValid(ok), isTrue, reason: ok);
    }
    for (final bad in ['4111111111111112', '1234567812345678', '', '4111-1111-1111-1111', '41111111111111a1']) {
      expect(luhnValid(bad), isFalse, reason: bad);
    }
    expect(cardNumberValid('79927398713'), isFalse, reason: 'too short for a card');
    expect(cardNumberValid('4111 1111 1111 1111'), isTrue);
  });

  test('payment system by BIN', () {
    expect(brandOf('4111'), CardBrand.visa);
    expect(brandOf('5105 1051'), CardBrand.mastercard);
    expect(brandOf('2221000000000009'), CardBrand.mastercard);
    expect(brandOf('2720990000000007'), CardBrand.mastercard);
    expect(brandOf('2721000000000000'), CardBrand.other);
    expect(brandOf('6200000000000005'), CardBrand.unionpay);
    expect(brandOf('8100000000000000'), CardBrand.unionpay);
    expect(brandOf('3530111333300000'), CardBrand.other);
    expect(brandOf('5'), CardBrand.other);
    expect(brandName(CardBrand.mastercard), 'Mastercard');
    expect(brandName(CardBrand.other), isNull);
  });

  test('masks', () {
    expect(formatCardNumber('4111111111111111'), '4111 1111 1111 1111');
    expect(formatCardNumber('41111'), '4111 1');
    expect(maskedCardNumber('4444'), '•••• •••• •••• 4444');

    final number = CardNumberFormatter();
    expect(_type(number, '', '4111111111111111').text, '4111 1111 1111 1111');
    expect(_type(number, '', '4111-1111 1111x1111').text, '4111 1111 1111 1111');
    expect(_type(number, '', '1' * 25).text.replaceAll(' ', '').length, 19);
    // курсор остаётся после той же цифры, что и до форматирования
    final mid = number.formatEditUpdate(
      const TextEditingValue(text: '4111 1111'),
      const TextEditingValue(text: '41191 1111', selection: TextSelection.collapsed(offset: 4)),
    );
    expect(mid.text, '4119 1111 1');
    expect(mid.selection.baseOffset, 4);

    final expiry = ExpiryFormatter();
    expect(_type(expiry, '', '0428').text, '04/28');
    expect(_type(expiry, '', '4').text, '04/');
    expect(_type(expiry, '', '1').text, '1');
    expect(_type(expiry, '', '12').text, '12/');
    expect(_type(expiry, '12/', '12').text, '1', reason: 'backspace over the slash removes the digit');
    expect(_type(expiry, '', '04/2028').text, '04/20');

    expect(_type(HolderFormatter(), '', 'aigerim  kassymova1').text, 'AIGERIM KASSYMOVA');
  });

  test('expiry: valid through the end of the month, no more than 20 years ahead', () {
    expect(expiryValid('11/26', now: now), isTrue);
    expect(expiryValid('10/26', now: now), isFalse);
    expect(expiryValid('12/25', now: now), isFalse);
    expect(expiryValid('11/46', now: now), isTrue);
    expect(expiryValid('12/46', now: now), isFalse);
    expect(expiryValid('13/28', now: now), isFalse);
    expect(expiryValid('4/28', now: now), isFalse);
  });

  test('card text from the camera: number, look-alike letters, latest date', () {
    const front = 'BANK CENTERCREDIT\n'
        '4111 1111 1111 1111\n'
        'VALID FROM 01/24  THRU 01/29\n'
        'AIGERIM KASSYMOVA\nVISA';
    expect(parseCardText(front, now: now), const ScannedCard(number: '4111111111111111', expiry: '01/29'));

    // OCR путает O и 0, I и 1, S и 5; срок четырьмя цифрами года.
    const blurry = 'MASTERCARD\n5S55 5555 555S 4444\nexp 07/2030';
    expect(parseCardText(blurry, now: now), const ScannedCard(number: '5555555555554444', expiry: '07/30'));
    expect(parseCardText('41I1 1111 1l11 111|', now: now).number, '4111111111111111');
    // группа почти без цифр не превращается в номер
    expect(parseCardText('4111 IIII 1111 1111', now: now).number, isNull);

    // номер одной строкой без пробелов
    expect(parseCardText('6200000000000005', now: now).number, '6200000000000005');

    // неверная сумма Луна, слова и даты в прошлом — ничего не найдено
    expect(parseCardText('4111 1111 1111 1112\n05/20\nSECURE', now: now), const ScannedCard());
    expect(parseCardText('TEL 8 800 080 33 33', now: now).number, isNull);
    // номер и срок в одной строке
    expect(parseCardText('4111 1111 1111 1111 12/27', now: now),
        const ScannedCard(number: '4111111111111111', expiry: '12/27'));
  });

  test('scan progress: number on two shots in a row, then a few shots for the expiry', () {
    const a = ScannedCard(number: '4111111111111111');
    const b = ScannedCard(number: '5555555555554444');
    var p = CardScanProgress();
    expect(p.add(a), isNull);
    expect(p.add(b), isNull, reason: 'different number resets the candidate');
    expect(p.add(const ScannedCard()), isNull);
    expect(p.add(a), isNull, reason: 'an empty shot in between breaks "two in a row"');
    expect(p.add(a), isNull);
    expect(p.number, a.number);
    expect(p.add(const ScannedCard(expiry: '04/29')), const ScannedCard(number: '4111111111111111', expiry: '04/29'));

    p = CardScanProgress(expiryWait: 2);
    p.add(a);
    expect(p.add(const ScannedCard(number: '4111111111111111', expiry: '01/30')), const ScannedCard(number: '4111111111111111', expiry: '01/30'));

    p = CardScanProgress(expiryWait: 2);
    p.add(a);
    p.add(a);
    expect(p.add(b), isNull, reason: 'a later misread does not replace the confirmed number');
    expect(p.add(const ScannedCard()), const ScannedCard(number: '4111111111111111'));
  });

  test('OCR channel: lines from the platform, null when there is no implementation', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(CardOcr.channel, (call) async {
      calls.add(call);
      return ['4111 1111 1111 1111', 'VALID THRU 04/29'];
    });
    expect(await CardOcr.recognize('/tmp/shot.jpg'), ['4111 1111 1111 1111', 'VALID THRU 04/29']);
    expect(calls.single.method, 'recognize');
    expect(calls.single.arguments, {'path': '/tmp/shot.jpg'});
    messenger.setMockMethodCallHandler(CardOcr.channel, null);
    expect(await CardOcr.recognize('/tmp/shot.jpg'), isNull);
  });

  testWidgets('scan screen without a camera plugin falls back to manual entry', (tester) async {
    Object? popped = 'not yet';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => popped = await Navigator.of(context)
                .push<ScannedCard>(MaterialPageRoute(builder: (_) => CardScanScreen(recognize: (_) async => const []))),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    // Ответ платформенного канала камеры приходит в реальном времени.
    for (var i = 0; i < 20 && popped == 'not yet'; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(popped, isNull);
    expect(find.byType(CardScanScreen), findsNothing);
  });

  test('card errors have messages, other errors fall back to common ones', () {
    const t = CardText('ru');
    for (final code in ['invalid_card_number', 'card_expired', 'too_many_cards', 'card_exists', 'card_not_found']) {
      expect(t.error(ApiError(code, 409)), isNot('Что-то пошло не так'), reason: code);
    }
    expect(t.error(ApiError('network', 0)), 'Нет связи с сервером');
    expect(const CardText('kk').t('add'), 'Карта қосу');
  });

  testWidgets('manual entry: masks, validation, number sent once without CVV', (tester) async {
    tester.view.physicalSize = const Size(1200, 2800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    HttpOverrides.global = null;
    final bodies = <Map<String, dynamic>>[];
    final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    await tester.runAsync(() async => server.listen((req) async {
          bodies.add((jsonDecode(await utf8.decoder.bind(req).join()) as Map).cast<String, dynamic>());
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'id': 'a' * 16, 'brand': 'visa', 'last4': '1111', 'expiry': '04/29', 'holder': 'AIGERIM K',
            'is_primary': true, 'created_at': 0,
          }));
          await req.response.close();
        }));
    final state = AppState()..ready = true;
    state.api
      ..token = 'session'
      ..baseUrl = 'http://127.0.0.1:${server.port}';
    BankCard? result;
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await Navigator.of(context)
                  .push<BankCard>(MaterialPageRoute(builder: (_) => AddCardScreen(scan: (_) async => null))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(cardText.t('byCamera')), findsOneWidget);
    await tester.tap(find.text(cardText.t('manual')));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '4111111111111112');
    await tester.pump();
    expect(find.text('4111 1111 1111 1112'), findsOneWidget);
    expect(find.text(cardText.t('invalidNumber')), findsOneWidget);
    expect(find.text('Visa'), findsOneWidget);

    await tester.enterText(fields.at(0), '4111111111111111');
    await tester.enterText(fields.at(1), '0429');
    await tester.enterText(fields.at(2), 'aigerim k');
    await tester.pump();
    expect(find.text(cardText.t('invalidNumber')), findsNothing);
    expect(find.text('04/29'), findsOneWidget);
    expect(find.text(cardText.t('noCvv')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);

    await tester.tap(find.text(cardText.t('save')));
    for (var i = 0; i < 10 && result == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.runAsync(() => server.close(force: true));
    // таймер простоя HTTP-соединения (15 секунд)
    await tester.pump(const Duration(minutes: 1));
    expect(bodies, [
      {'number': '4111111111111111', 'expiry': '04/29', 'holder': 'AIGERIM K'},
    ]);
    expect(result?.last4, '1111');
  });
}
