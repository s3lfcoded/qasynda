import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qasynda/bank_card.dart';

Future<List<bool>> _card(WidgetTester t) async {
  final sides = <bool>[];
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListView(children: [
        SizedBox(height: 200, child: FlipCard(onSide: sides.add, front: const Text('FRONT'), back: const Text('BACK'))),
      ]),
    ),
  ));
  return sides;
}

void main() {
  testWidgets('card flips on a 400 ms long press and back again', (t) async {
    final sides = await _card(t);
    var g = await t.startGesture(t.getCenter(find.text('FRONT')));
    await t.pump(const Duration(milliseconds: 300));
    await g.up();
    await t.pump(const Duration(seconds: 1));
    expect(sides, isEmpty, reason: 'shorter than 400 ms is not a long press');

    g = await t.startGesture(t.getCenter(find.text('FRONT')));
    await t.pump(const Duration(milliseconds: 450));
    await g.up();
    await t.pump(const Duration(seconds: 1));
    expect(sides, [true]);
    expect(find.text('BACK'), findsOneWidget);

    g = await t.startGesture(t.getCenter(find.text('BACK')));
    await t.pump(const Duration(milliseconds: 450));
    await g.up();
    await t.pump(const Duration(seconds: 1));
    expect(sides, [true, false]);
  });

  testWidgets('a short slow swipe returns the card, a long one turns it', (t) async {
    final sides = await _card(t);
    await t.timedDrag(find.text('FRONT'), const Offset(60, 0), const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(sides, isEmpty);

    await t.timedDrag(find.text('FRONT'), const Offset(400, 0), const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(sides, [true]);
  });
}
