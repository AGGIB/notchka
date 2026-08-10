# Спайк: чтение now playing через mediaremote-adapter

Дата: 2026-08-10
Машина: macOS 26.3, Apple Silicon
Результат: УСПЕХ

## Абсолютные пути и сборка через CMake

Репозиторий `vendor/mediaremote-adapter` собирается через **CMake** — в нём
нет ни `.xcodeproj`, ни `Package.swift`. Исходный план ссылался на Xcode,
это было неверно и исправлено по факту первой попытки.

```bash
cd vendor/mediaremote-adapter
cmake -S . -B .build -DCMAKE_BUILD_TYPE=Release
cmake --build .build
```

Результат сборки: `vendor/mediaremote-adapter/.build/MediaRemoteAdapter.framework`.
Пересборка в этом заходе не требовалась — фреймворк уже был собран
предыдущей попыткой и подтверждён рабочим (`test` → `exit=0`).

Реальный размер на диске (измерено, не оценка из плана): `du -sh` — 300K.
Сумма байт настоящих файлов бандла (`find … -type f`) — 301 098 Б ≈ 294 КБ:
бинарник `Versions/A/MediaRemoteAdapter` 297 808 Б,
`Versions/A/_CodeSignature/CodeResources` 2 442 Б,
`Versions/A/Resources/Info.plist` 848 Б. `du -shL` (со следованием по
символьным ссылкам `Versions/Current → A`, `Resources` и
`MediaRemoteAdapter` в корне бандла) даёт 896K — эта цифра задваивает
одно и то же содержимое через несколько симлинков и не отражает
реальный объём данных на диске.

Пути к `.pl`-скрипту и к `.framework`, которые передаются адаптеру, обязаны
быть **абсолютными**. С относительными путями бридж падает с
`Failed to load framework` — это не придирка к стилю, а требование самого
Perl → Objective-C моста (он резолвит путь к фреймворку изнутри
скомпилированного бинарника, без knowledge о `$PWD` вызывающего процесса).

## Проверенные пути

- ADAPTER_PL: `/path/to/notchka/vendor/mediaremote-adapter/bin/mediaremote-adapter.pl`
- ADAPTER_FRAMEWORK: `/path/to/notchka/vendor/mediaremote-adapter/.build/MediaRemoteAdapter.framework`

## Команды

Разовое чтение:
    /usr/bin/perl $ADAPTER_PL $ADAPTER_FRAMEWORK get

Поток:
    /usr/bin/perl $ADAPTER_PL $ADAPTER_FRAMEWORK stream

Управление:
    /usr/bin/perl $ADAPTER_PL $ADAPTER_FRAMEWORK send <код>

## Коды команд (проверено эмпирически)

- 0 — **play**. `playing: false → true`. Повторная отправка при уже
  `playing: true` не меняет состояние (идемпотентна, не toggle).
- 1 — **pause**. `playing: true → false`. Повторная отправка при уже
  `playing: false` не меняет состояние (идемпотентна).
- 2 — **toggle play/pause**. Каждый вызов инвертирует состояние:
  `false → true`, следующий вызов `true → false`.

Метод: baseline `get`, затем шесть переходов подряд `send 0`, `send 0`,
`send 1`, `send 1`, `send 2`, `send 2`, с `get` после каждого (~1.5–2с
задержка). Полный транскрипт наблюдаемых переходов — в отчёте задачи
(`task-1-report.md`). Результат совпал с гипотезой плана (код 2 = toggle),
но подтверждён по факту, а не принят на слово.

## Источник и канал: Chrome подтверждён отдельно

Попытка 1 (см. `progress.md`) подтвердила канал MediaRemote на **Safari**
(у Chrome тогда не было открытых окон) и не успела проверить Chrome —
агент упал в ENOSPC на этом шаге.

В этой попытке Chrome воспроизводил ролик на YouTube. Первый же `get`
вернул:

- `"bundleIdentifier": "com.google.Chrome"` — канал подтверждён именно на
  Chrome, не только на Safari.
- `"processIdentifier": 59148` — совпадает с PID процесса
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`,
  проверено кросс-чеком с `ps aux`.

Наблюдение, зафиксированное как факт, а не как провал: в момент самого
первого чтения `playing` было `false`, хотя ожидалось, что музыка играет.
Два опроса `get` подряд с разницей 5 секунд вернули идентичные
`elapsedTime` (183.119747) и `timestamp` — трек был на паузе по факту в
этот момент, не играл. Дальнейшие тесты (см. раздел про коды команд)
подтвердили, что канал живой и полностью управляемый: `send 0`
немедленно перевёл `playing` в `true`, `elapsedTime` начал расти в такт
реальному времени.

Safari отдельно в этой попытке не перепроверялся: пока тестировался
Chrome, у Safari не было активной now-playing сессии, конкурирующей за
канал. Это ожидаемое поведение, а не пробел — **MediaRemote отдаёт только
одну активную now-playing сессию за раз**, а не список всех источников
разом. Для плана 2 это значит: если пользователь одновременно слушает
что-то в двух приложениях, адаптер покажет только то, что macOS считает
текущим "now playing" источником (обычно — последнее приложение,
зарегистрировавшее событие воспроизведения), а не оба сразу.

Итог: Chrome подтверждён напрямую и убедительно — bundleIdentifier,
processIdentifier и полная управляемость через `send` однозначно
указывают на реальный канал Chrome → MediaRemote → адаптер.

## Образец payload из Chrome

```json
{
  "playbackRate": 1,
  "album": "",
  "elapsedTime": 200.349576,
  "timestamp": "2026-08-10T11:35:25Z",
  "bundleIdentifier": "com.google.Chrome",
  "processIdentifier": 59148,
  "artworkData": "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6AB...<обрезано>",
  "title": "Deep Work Music – Deep Focus | Background Music for Productivity, Mental Clarity and Focused Tasks",
  "artworkMimeType": "image/jpeg",
  "duration": 7279.961,
  "artist": "Deep Idle Room",
  "contentItemIdentifier": "F06E3460-AF16-445A-AF1E-2600F5CA2D5E",
  "playing": true
}
```

## Поток обновлений

Проверено: `stream` эмитит строки вида
`{"type":"data","diff":true,"payload":{...}}` на каждое изменение
состояния. У агента нет GUI-доступа к окну браузера пользователя, поэтому
вместо ручной паузы/воспроизведения диффы триггерились командой `send`
(тот же канал управления, что и в разделе про коды команд) — это честная
и технически эквивалентная замена ручному клику.

Пример пары диффов на один `send 2` (toggle):

    {"type":"data","diff":true,"payload":{"playing":true}}
    {"type":"data","diff":true,"payload":{"playbackRate":1,"contentItemIdentifier":"...","timestamp":"..."}}

Первая строка потока после подключения — служебная
`{"type":"data","diff":false,"payload":{}}`, вторая — полный снимок
текущего состояния (`diff:false` с заполненным payload). Дальше идут
только диффы.

`Ctrl+C` не нажимался физически (нет TTY-доступа к интерактивному
процессу); эквивалент — `kill -INT` по PID процесса. Процесс завершился в
пределах 1 секунды, `wait` вернул `exit code=0` — адаптер перехватывает
SIGINT и завершается чисто, а не падает по голому сигналу.

## Задержки

- От `send <код>` до появления diff-строк в потоке: в пределах ~1 секунды
  (разрешение замера — опрос счётчика строк лога раз в секунду; в обоих
  toggle-событиях новые строки уже были на первой секундной отметке после
  команды). Порядок величины — сотни миллисекунд, точно не единицы секунд.
- От `kill -INT` до завершения процесса: < 1 секунды.

## Дополнительное наблюдение (не по плану, но важно для плана 2)

- `elapsedTime`/`timestamp` — это снимок на момент последнего события, а
  не поле, тикающее вживую. Между событиями оно не меняется, даже если
  трек реально играет. Текущую позицию нужно вычислять как
  `elapsedTime + (now - timestamp) * playbackRate`, а не читать
  `elapsedTime` напрямую.
- `contentItemIdentifier` меняется почти на каждое обновление payload —
  это токен конкретного снимка от MediaRemote, не стабильный ID трека.
  Не использовать как ключ дедупликации.
- Один раз за сессию одиночный `get` вернул текст
  `Reading now playing information timed out after 2000 milliseconds`
  вместо JSON (замечено на фоне быстрых повторных вызовов подряд; точный
  exit code не зафиксирован из-за бага в собственном скрипте наблюдения
  в этот момент — по независящим от адаптера причинам). План 2 должен
  быть готов ретраить/агрегировать такие ответы, а не считать их
  провалом канала.
