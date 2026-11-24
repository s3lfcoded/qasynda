import 'package:flutter/services.dart';

import 'api.dart';

/// Платёжная система карты. qasynda — учебная виртуальная карта приложения.
enum CardBrand { visa, mastercard, unionpay, qasynda, other }

CardBrand brandFromName(String? name) =>
    CardBrand.values.firstWhere((b) => b.name == name, orElse: () => CardBrand.other);

/// Название платёжной системы; null — неизвестная.
String? brandName(CardBrand brand) => const {
      CardBrand.visa: 'Visa',
      CardBrand.mastercard: 'Mastercard',
      CardBrand.unionpay: 'UnionPay',
      CardBrand.qasynda: 'Qasynda',
    }[brand];

String digitsOnly(String text) => text.replaceAll(RegExp(r'[^0-9]'), '');

/// Платёжная система по первым цифрам (BIN): Visa — 4, Mastercard — 51–55 и 2221–2720, UnionPay — 62 и 81.
/// Так же определяет сервер.
CardBrand brandOf(String number) {
  final d = digitsOnly(number);
  if (d.startsWith('4')) return CardBrand.visa;
  if (d.length < 2) return CardBrand.other;
  final two = int.parse(d.substring(0, 2));
  if (two >= 51 && two <= 55) return CardBrand.mastercard;
  if (d.length >= 4) {
    final four = int.parse(d.substring(0, 4));
    if (four >= 2221 && four <= 2720) return CardBrand.mastercard;
  }
  if (two == 62 || two == 81) return CardBrand.unionpay;
  return CardBrand.other;
}

/// Контрольная сумма Луна.
bool luhnValid(String number) {
  final d = digitsOnly(number);
  if (d.isEmpty || d.length != number.replaceAll(' ', '').length) return false;
  var sum = 0;
  for (var i = 0; i < d.length; i++) {
    var n = d.codeUnitAt(d.length - 1 - i) - 48;
    if (i.isOdd) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
  }
  return sum % 10 == 0;
}

/// Полный номер, который можно отправить на сервер: 12–19 цифр и верная контрольная сумма.
bool cardNumberValid(String number) {
  final d = digitsOnly(number);
  return d.length >= 12 && d.length <= 19 && luhnValid(d);
}

/// «4111111111111111» → «4111 1111 1111 1111».
String formatCardNumber(String number) {
  final d = digitsOnly(number);
  final buf = StringBuffer();
  for (var i = 0; i < d.length; i++) {
    if (i > 0 && i % 4 == 0) buf.write(' ');
    buf.write(d[i]);
  }
  return buf.toString();
}

/// Номер без цифр, кроме последних четырёх: «•••• •••• •••• 1111».
String maskedCardNumber(String last4) => '•••• •••• •••• $last4';

/// Срок «MM/YY» действует до конца указанного месяца. Сроки дальше 20 лет — опечатка.
bool expiryValid(String expiry, {DateTime? now}) {
  final m = RegExp(r'^(0[1-9]|1[0-2])/(\d{2})$').firstMatch(expiry);
  if (m == null) return false;
  final month = int.parse(m[1]!);
  final year = 2000 + int.parse(m[2]!);
  final today = now ?? DateTime.now();
  final card = year * 12 + month;
  final current = today.year * 12 + today.month;
  return card >= current && card <= current + 20 * 12;
}

/// Маска ввода номера «0000 0000 0000 0000»: только цифры, до 19, пробел после каждых четырёх.
class CardNumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final cursorDigits = digitsOnly(newValue.text.substring(0, newValue.selection.end.clamp(0, newValue.text.length)));
    var digits = digitsOnly(newValue.text);
    if (digits.length > 19) digits = digits.substring(0, 19);
    final text = formatCardNumber(digits);
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: _offset(text, cursorDigits.length.clamp(0, digits.length))));
  }
}

/// Маска срока «MM/YY»: «0428» → «04/28», первая цифра больше 1 означает месяц из одной цифры: «4» → «04/».
class ExpiryFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var digits = digitsOnly(newValue.text);
    if (digits.isNotEmpty && digits.codeUnitAt(0) > 49) digits = '0$digits';
    if (digits.length > 4) digits = digits.substring(0, 4);
    final deleting = newValue.text.length < oldValue.text.length;
    final text = digits.length < 2
        ? digits
        : digits.length == 2 && deleting
            ? digits.substring(0, 1)
            : '${digits.substring(0, 2)}/${digits.substring(2)}';
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

/// Имя на карте: латиница заглавными, как на лицевой стороне.
class HolderFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = newValue.text.toUpperCase().replaceAll(RegExp(r"[^A-Z .'-]"), '').replaceAll(RegExp(r' {2,}'), ' ');
    final clipped = text.length > 26 ? text.substring(0, 26) : text;
    return TextEditingValue(text: clipped, selection: TextSelection.collapsed(offset: clipped.length));
  }
}

int _offset(String formatted, int digitsBefore) {
  if (digitsBefore == 0) return 0;
  var seen = 0;
  for (var i = 0; i < formatted.length; i++) {
    if (formatted.codeUnitAt(i) != 32) seen++;
    if (seen == digitsBefore) return i + 1;
  }
  return formatted.length;
}

/// Что удалось найти на снимке карты. Любое поле может отсутствовать.
class ScannedCard {
  const ScannedCard({this.number, this.expiry});
  final String? number;
  final String? expiry;

  @override
  bool operator ==(Object other) => other is ScannedCard && other.number == number && other.expiry == expiry;

  @override
  int get hashCode => Object.hash(number, expiry);

  @override
  String toString() => 'ScannedCard(${number == null ? '-' : '…${number!.substring(number!.length - 4)}'}, $expiry)';
}

const _lookalikes = {'O': '0', 'o': '0', 'D': '0', 'Q': '0', 'I': '1', 'l': '1', '|': '1', 'i': '1', 'S': '5', 's': '5', 'B': '8', 'Z': '2', 'z': '2', 'b': '6', 'G': '6'};

/// Разбор распознанного текста карты. Номер — группы цифр в одной строке, вместе 13–19 цифр с верной
/// суммой Луна; в группах, где почти все символы цифры, похожие буквы (O, I, S, B…) читаются как цифры.
/// Срок — «MM/YY» или «MM/YYYY»; если их несколько («VALID FROM … THRU …»), берётся самый поздний.
ScannedCard parseCardText(String text, {DateTime? now}) {
  String? number;
  for (final line in text.split('\n')) {
    final groups = line.trim().split(RegExp(r'[\s\-]+')).where((g) => g.isNotEmpty).map(_asDigits).toList();
    for (var start = 0; start < groups.length && number == null; start++) {
      // Из подходящих номеров с этой группы — 16 цифр, если есть, иначе самый длинный.
      final found = <String>[];
      var joined = '';
      for (var end = start; end < groups.length; end++) {
        final g = groups[end];
        if (g == null) break;
        joined += g;
        if (joined.length > 19) break;
        if (joined.length >= 13 && luhnValid(joined)) found.add(joined);
      }
      if (found.isNotEmpty) number = found.firstWhere((n) => n.length == 16, orElse: () => found.last);
    }
    if (number != null) break;
  }

  String? expiry;
  var best = -1;
  for (final m in RegExp(r'(?<!\d)(0[1-9]|1[0-2])\s?[/\\\-.]\s?(\d{4}|\d{2})(?!\d)').allMatches(text)) {
    final yy = m[2]!.length == 4 ? m[2]!.substring(2) : m[2]!;
    final candidate = '${m[1]}/$yy';
    if (!expiryValid(candidate, now: now)) continue;
    final key = int.parse(yy) * 12 + int.parse(m[1]!);
    if (key > best) {
      best = key;
      expiry = candidate;
    }
  }
  return ScannedCard(number: number, expiry: expiry);
}

/// Ход сканирования по снимкам. Номер принимается, когда одинаково прочитан на двух снимках подряд.
/// Дальше ждём срок ещё [expiryWait] снимков; не нашёлся — отдаём номер без срока, его введут руками.
class CardScanProgress {
  CardScanProgress({this.expiryWait = 3});
  final int expiryWait;

  String? number;
  String? expiry;
  String? _candidate;
  int _afterNumber = 0;

  /// Разобранный снимок. Возвращает итог, когда сканирование закончено, иначе null.
  ScannedCard? add(ScannedCard shot) {
    if (shot.expiry != null) expiry = shot.expiry;
    if (number == null) {
      if (shot.number != null && shot.number == _candidate) {
        number = shot.number;
      } else {
        _candidate = shot.number;
      }
    } else {
      _afterNumber++;
    }
    if (number != null && (expiry != null || _afterNumber >= expiryWait)) {
      return ScannedCard(number: number, expiry: expiry);
    }
    return null;
  }
}

/// Распознавание текста на снимке: свой канал qasynda/ocr — Apple Vision на iOS, ML Kit на Android.
class CardOcr {
  static const channel = MethodChannel('qasynda/ocr');

  /// Строки текста на снимке. null — на этой платформе распознавания нет.
  static Future<List<String>?> recognize(String path) async {
    try {
      return await channel.invokeListMethod<String>('recognize', {'path': path}) ?? const [];
    } on MissingPluginException {
      return null;
    }
  }
}

String? _asDigits(String group) {
  if (group.length > 6) {
    return RegExp(r'^\d+$').hasMatch(group) ? group : null;
  }
  final digits = group.split('').where((c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57).length;
  if (digits < group.length - 1 || digits == 0) return null;
  final mapped = group.split('').map((c) => _lookalikes[c] ?? c).join();
  return RegExp(r'^\d+$').hasMatch(mapped) ? mapped : null;
}

/// Привязанная карта. Полного номера у приложения нет: сервер его не хранит и не отдаёт.
class BankCard {
  const BankCard({
    required this.id,
    required this.brand,
    required this.last4,
    required this.expiry,
    required this.holder,
    required this.isPrimary,
  });

  factory BankCard.fromJson(Map<String, dynamic> json) => BankCard(
        id: json['id'] as String,
        brand: brandFromName(json['brand'] as String?),
        last4: json['last4'] as String,
        expiry: json['expiry'] as String,
        holder: json['holder'] as String,
        isPrimary: json['is_primary'] == true,
      );

  final String id;
  final CardBrand brand;
  final String last4;
  final String expiry;
  final String holder;
  final bool isPrimary;

  String get masked => maskedCardNumber(last4);
}

/// Учебная карта Qasynda без реквизитов — то, что видно в списке.
class VirtualCard {
  const VirtualCard({required this.last4, required this.holder});
  factory VirtualCard.fromJson(Map<String, dynamic> json) =>
      VirtualCard(last4: json['last4'] as String, holder: json['holder'] as String);
  final String last4;
  final String holder;
  String get masked => maskedCardNumber(last4);
}

/// Реквизиты учебной карты. Не сохраняются: показываются и сразу забываются.
class VirtualCardSecret {
  const VirtualCardSecret({required this.number, required this.expiry, required this.cvv, required this.holder});
  factory VirtualCardSecret.fromJson(Map<String, dynamic> json) => VirtualCardSecret(
        number: json['number'] as String,
        expiry: json['expiry'] as String,
        cvv: json['cvv'] as String,
        holder: json['holder'] as String,
      );
  final String number;
  final String expiry;
  final String cvv;
  final String holder;
}

/// Запросы карт поверх клиента приложения (AppState.api). Все они работают только в разблокированной сессии.
class CardsApi {
  CardsApi(this.api);
  final Api api;

  Future<({List<BankCard> items, int max})> list() async {
    final data = await api.get('/cards');
    final items = (data['items'] as List).cast<Map<String, dynamic>>().map(BankCard.fromJson).toList();
    return (items: items, max: data['max'] as int? ?? 5);
  }

  /// Номер уходит на сервер один раз; CVV приложение не спрашивает и не отправляет.
  Future<BankCard> add({required String number, required String expiry, required String holder}) async =>
      BankCard.fromJson(await api.post('/cards', {'number': digitsOnly(number), 'expiry': expiry, 'holder': holder.trim()}));

  Future<void> delete(String id) => api.delete('/cards/$id');

  Future<void> setPrimary(String id) => api.post('/cards/$id/primary');

  Future<VirtualCard> virtualCard() async => VirtualCard.fromJson(await api.get('/cards/virtual'));

  Future<VirtualCardSecret> virtualSecret() async => VirtualCardSecret.fromJson(await api.get('/cards/virtual/secret'));
}
