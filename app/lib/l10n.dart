/// Строки интерфейса на русском и казахском.
const _ru = <String, String>{
  'tagline': 'Переводы тем, кто рядом',
  'phone': 'Номер телефона',
  'pin': 'PIN-код',
  'login': 'Войти',
  'server': 'Адрес сервера',
  'save': 'Сохранить',
  'hello': 'Здравствуйте, {name}',
  'balance': 'Баланс',
  'sendNearby': 'Перевести рядом',
  'sendNearbyHint': 'Без QR и номера',
  'receiveNearby': 'Принять рядом',
  'receiveNearbyHint': 'Покажитесь отправителю',
  'history': 'История',
  'historyEmpty': 'Переводов пока нет',
  'logout': 'Выйти',
  'searching': 'Ищем получателей рядом…',
  'searchHint': 'Попросите получателя открыть «Принять рядом»',
  'btNear': 'Bluetooth · рядом',
  'gpsNear': 'GPS · около {m} м',
  'merchant': 'ИП в банке',
  'amount': 'Сумма, ₸',
  'note': 'Комментарий',
  'limit': 'До {sum} за перевод',
  'overLimit': 'Больше лимита {sum}',
  'pay': 'Перевести {sum}',
  'payEmpty': 'Введите сумму',
  'sent': 'Перевод отправлен',
  'done': 'Готово',
  'visible': 'Вас видят рядом',
  'visibleHint': 'Пока этот экран открыт, отправитель найдёт вас в списке. Закройте его, чтобы скрыться.',
  'received': 'Получено {sum}',
  'from': 'от {name}',
  'btOn': 'Bluetooth работает',
  'btOff': 'Bluetooth недоступен',
  'gpsOn': 'Геолокация работает',
  'gpsOff': 'Геолокация недоступна',
  'needNearby': 'Включите Bluetooth или геолокацию и разрешите доступ',
  'err.invalid_credentials': 'Неверный номер или PIN-код',
  'err.too_many_attempts': 'Слишком много попыток. Подождите 5 минут',
  'err.insufficient_funds': 'Недостаточно средств',
  'err.limit_exceeded': 'Сумма больше лимита',
  'err.not_nearby': 'Получатель уже не рядом',
  'err.recipient_not_available': 'Получатель закрыл приём',
  'err.self_transfer': 'Нельзя перевести самому себе',
  'err.unauthorized': 'Войдите заново',
  'err.network': 'Нет связи с сервером',
  'err.unknown': 'Что-то пошло не так',
};

const _kk = <String, String>{
  'tagline': 'Жаныңыздағыларға аударым',
  'phone': 'Телефон нөмірі',
  'pin': 'PIN-код',
  'login': 'Кіру',
  'server': 'Сервер мекенжайы',
  'save': 'Сақтау',
  'hello': 'Сәлеметсіз бе, {name}',
  'balance': 'Баланс',
  'sendNearby': 'Жанындағыға аудару',
  'sendNearbyHint': 'QR мен нөмірсіз',
  'receiveNearby': 'Жанынан қабылдау',
  'receiveNearbyHint': 'Жіберушіге көрініңіз',
  'history': 'Тарих',
  'historyEmpty': 'Әзірге аударымдар жоқ',
  'logout': 'Шығу',
  'searching': 'Жаныңыздағы алушыларды іздеп жатырмыз…',
  'searchHint': 'Алушыдан «Жанынан қабылдау» экранын ашуды сұраңыз',
  'btNear': 'Bluetooth · жаныңызда',
  'gpsNear': 'GPS · шамамен {m} м',
  'merchant': 'Банктегі ЖК',
  'amount': 'Сома, ₸',
  'note': 'Түсініктеме',
  'limit': 'Бір аударымға {sum} дейін',
  'overLimit': '{sum} лимитінен асады',
  'pay': '{sum} аудару',
  'payEmpty': 'Соманы енгізіңіз',
  'sent': 'Аударым жіберілді',
  'done': 'Дайын',
  'visible': 'Сізді жаныңыздағылар көріп тұр',
  'visibleHint': 'Осы экран ашық тұрғанда жіберуші сізді тізімнен табады. Жасырыну үшін экранды жабыңыз.',
  'received': '{sum} түсті',
  'from': 'жіберуші: {name}',
  'btOn': 'Bluetooth жұмыс істеп тұр',
  'btOff': 'Bluetooth қолжетімсіз',
  'gpsOn': 'Геолокация жұмыс істеп тұр',
  'gpsOff': 'Геолокация қолжетімсіз',
  'needNearby': 'Bluetooth немесе геолокацияны қосып, рұқсат беріңіз',
  'err.invalid_credentials': 'Нөмір немесе PIN-код қате',
  'err.too_many_attempts': 'Әрекет тым көп. 5 минут күтіңіз',
  'err.insufficient_funds': 'Қаражат жеткіліксіз',
  'err.limit_exceeded': 'Сома лимиттен асады',
  'err.not_nearby': 'Алушы енді жаныңызда емес',
  'err.recipient_not_available': 'Алушы қабылдауды жапты',
  'err.self_transfer': 'Өзіңізге аудара алмайсыз',
  'err.unauthorized': 'Қайта кіріңіз',
  'err.network': 'Сервермен байланыс жоқ',
  'err.unknown': 'Бірдеңе дұрыс болмады',
};

class S {
  const S(this.lang);
  final String lang;

  String t(String key, [Map<String, String> args = const {}]) {
    var text = (lang == 'kk' ? _kk[key] : null) ?? _ru[key] ?? key;
    args.forEach((name, value) => text = text.replaceAll('{$name}', value));
    return text;
  }

  String error(String code) {
    final key = 'err.$code';
    return _ru.containsKey(key) ? t(key) : t('err.unknown');
  }
}

/// 1250050 тиын → «12 500,50 ₸»; копейки показываются, только если они есть.
String money(int tiyn) {
  final whole = (tiyn.abs() ~/ 100).toString();
  final buf = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buf.write(' ');
    buf.write(whole[i]);
  }
  final cents = tiyn.abs() % 100;
  final tail = cents == 0 ? '' : ',${cents.toString().padLeft(2, '0')}';
  return '${tiyn < 0 ? '−' : ''}$buf$tail ₸';
}
