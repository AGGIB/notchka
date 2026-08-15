#!/usr/bin/env bash
# Собирает Notchka в Release, при наличии сертификата подписывает Developer ID
# Application-подписью, упаковывает в DMG с фирменным фоном и (опционально)
# нотаризует готовый образ через notarytool.
#
# Личная подпись и credentials нотаризации никогда не хранятся в репозитории —
# они передаются через переменные окружения на момент запуска. Без них скрипт
# соберёт ad-hoc DMG, пригодный для локальной проверки, но не для публичной
# раздачи (Gatekeeper такую сборку не пропустит без предупреждения).
#
# Переменные окружения:
#   CODE_SIGN_IDENTITY   Полная строка идентичности подписи
#                        (например "Developer ID Application: Имя (TEAMID)").
#                        По умолчанию — ad-hoc ("-").
#   DEVELOPMENT_TEAM     10-символьный Team ID. Обязателен вместе с
#                        CODE_SIGN_IDENTITY, если она не ad-hoc.
#   NOTARIZE             "1" — нотаризовать готовый DMG. Требует
#                        NOTARY_KEYCHAIN_PROFILE.
#   NOTARY_KEYCHAIN_PROFILE
#                        Имя профиля, заранее сохранённого через
#                        `xcrun notarytool store-credentials`.
#
# Пример полного публичного релиза:
#   CODE_SIGN_IDENTITY="Developer ID Application: Имя (TEAMID)" \
#   DEVELOPMENT_TEAM=TEAMID \
#   NOTARIZE=1 NOTARY_KEYCHAIN_PROFILE=notchka-notary \
#   ./scripts/build-dmg.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

if [[ "$NOTARIZE" == "1" && -z "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  echo "error: NOTARIZE=1 требует NOTARY_KEYCHAIN_PROFILE" >&2
  exit 1
fi
if [[ "$CODE_SIGN_IDENTITY" != "-" && -z "$DEVELOPMENT_TEAM" ]]; then
  echo "error: указана CODE_SIGN_IDENTITY, но не задан DEVELOPMENT_TEAM" >&2
  exit 1
fi

VERSION="$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD_DIR="$REPO_ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGING_DIR="$BUILD_DIR/dmg-staging"
DMG_TMP="$BUILD_DIR/Notchka-tmp.dmg"
DMG_FINAL="$BUILD_DIR/Notchka-$VERSION.dmg"
VOLUME_NAME="Notchka"

rm -rf "$STAGING_DIR" "$DMG_TMP" "$DMG_FINAL"
mkdir -p "$STAGING_DIR"

echo "==> Генерирую Xcode-проект"
xcodegen generate

echo "==> Собираю Release (identity: $CODE_SIGN_IDENTITY)"
xcodebuild \
  -project Notchka.xcodeproj \
  -scheme Notchka \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  clean build

APP_PATH="$DERIVED_DATA/Build/Products/Release/Notchka.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: сборка не создала $APP_PATH" >&2
  exit 1
fi

echo "==> Проверяю подпись"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Собираю содержимое DMG"
cp -R "$APP_PATH" "$STAGING_DIR/Notchka.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$STAGING_DIR/.background"
cp "$REPO_ROOT/scripts/dmg-assets/dmg-background.png" "$STAGING_DIR/.background/background.png"

echo "==> Создаю временный образ"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDRW -size 200m "$DMG_TMP"

MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TMP" | tail -1 | awk '{print $NF}')"
if [[ -z "$MOUNT_DIR" ]]; then
  echo "error: не удалось смонтировать временный образ" >&2
  exit 1
fi

echo "==> Настраиваю оформление окна Finder ($MOUNT_DIR)"
# Позиции иконок здесь синхронизированы с координатами бейджа и стрелки в
# scripts/dmg-assets/dmg-background.png (см. IconRenderer/main.swift,
# функция dmgBackground) — фон рисует подсказку именно под этими точками.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 1060, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Notchka.app" of container window to {180, 175}
        set position of item "Applications" of container window to {480, 175}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR"

echo "==> Конвертирую в сжатый read-only образ"
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL"
rm -f "$DMG_TMP"
rm -rf "$STAGING_DIR"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "==> Отправляю на нотаризацию (профиль: $NOTARY_KEYCHAIN_PROFILE)"
  xcrun notarytool submit "$DMG_FINAL" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  echo "==> Прикрепляю тикет нотаризации"
  xcrun stapler staple "$DMG_FINAL"
  xcrun stapler validate "$DMG_FINAL"
fi

echo "==> Готово: $DMG_FINAL"
shasum -a 256 "$DMG_FINAL"
