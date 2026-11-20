#!/usr/bin/env bash
# Сборка Qasynda под iPhone. Запускать на Mac из корня репозитория:
#   ./scripts/build_ios.sh            — проверить окружение и собрать
#   ./scripts/build_ios.sh run        — собрать и запустить на подключённом iPhone
#
# Перед первым запуском один раз откройте app/ios/Runner.xcworkspace в Xcode,
# выберите Runner → Signing & Capabilities → Team (свой Apple ID) и включите
# «Automatically manage signing». Без этого Xcode не подпишет приложение.
set -euo pipefail

API="${QASYNDA_API:-https://qasynda-api.onrender.com}"
cd "$(dirname "$0")/../app"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Не найдено: $1. $2"; exit 1; }
}
[ "$(uname)" = "Darwin" ] || { echo "Сборка под iPhone возможна только на macOS."; exit 1; }
need xcodebuild "Установите Xcode из App Store и запустите его один раз."
need flutter    "Установите Flutter: https://docs.flutter.dev/get-started/install/macos"

echo "== Зависимости"
flutter pub get
# Flutter 3.50 подключает плагины через Swift Package Manager; CocoaPods нужен, только если есть Podfile.
if [ -f ios/Podfile ]; then (cd ios && pod install); fi

echo "== Проверки"
flutter analyze --no-fatal-infos
flutter test

if [ "${1:-}" = "run" ]; then
  echo "== Запуск на iPhone (сервер: $API)"
  flutter run --release --dart-define=QASYNDA_API="$API"
else
  echo "== Сборка (сервер: $API)"
  flutter build ios --release --dart-define=QASYNDA_API="$API"
  echo
  echo "Готово. Чтобы поставить на телефон: подключите iPhone и выполните ./scripts/build_ios.sh run"
fi
