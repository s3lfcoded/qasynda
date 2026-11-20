import 'package:flutter_test/flutter_test.dart';
import 'package:qasynda/l10n.dart';
import 'package:qasynda/nearby.dart';

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
}
