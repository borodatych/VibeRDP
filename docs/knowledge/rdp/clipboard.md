# RDP: буфер обмена CLIPRDR

Сверено 2026-09-25 на FreeRDP 3.32.0, задача 2.1.
Ядро — `core/src/clipboard.c` и `core/src/cliptext.c`, приложение — `client-macos/Clipboard/ClipboardBridge.swift`.
Устройство моста — решение 25 в [decisions.md](../../decisions.md), приватность буфера macOS — [macos/pasteboardPrivacy.md](../macos/pasteboardPrivacy.md).

## Ход обмена

**Суть:**
- Канал статический, `cliprdr`; клиентская часть FreeRDP грузится при `FreeRDP_RedirectClipboard`, а он у клиента включён по умолчанию (`libfreerdp/core/settings.c:1296`)
- Обмен начинает сервер: Monitor Ready; в ответ клиент шлёт свои возможности и первый список форматов — что лежит в его буфере
- Каждая сторона объявляет только список форматов, а данные идут, когда другая сторона вставляет: Format Data Request и Format Data Response
- На каждый список форматов другая сторона отвечает Format List Response
- В ответе на запрос данных нет номера запроса: ответы идут строго по порядку, и в каждую сторону разумен один вопрос за раз
- Колбэки клиентской части FreeRDP приходят на потоке сессии — там, где разбирается транспорт; отправка из канала через очередь, её можно звать с любого потока
- Пустой список форматов сервера FreeRDP до клиента не доносит: после фильтра по `FreeRDP_ClipboardFeatureMask` пустой список просто отбрасывается (`channels/cliprdr/client/cliprdr_format.c:136-144`)

**Применение:**
- Ядро хранит последнее предложение Мака и шлёт его при каждом Monitor Ready — после переподключения тоже, а до него предложение ждёт
- Вопрос сервера ждёт одного ответа приложения; формат, которого Мак не предлагал, получает отказ сразу, без вопроса
- Копия с сервера одна за раз; если она не дождалась ответа, поздний ответ ждётся и выбрасывается — иначе он достался бы следующей копии

## Текст

**Суть:**
- Windows хранит текст в `CF_UNICODETEXT`: UTF-16LE, строки — CRLF, в конце — нулевой символ; `CF_TEXT` и `CF_OEMTEXT` Windows достраивает из него сама
- Мак — UTF-8 и LF; текст с Windows может нести и одинокий CR, и мусор после нуля

**Применение:**
- Ядро объявляет только `CF_UNICODETEXT`
- Мак → Windows: одинокий LF становится CRLF, CRLF остаётся, в конце — нулевой символ; битый UTF-8 — U+FFFD
- Windows → Мак: текст кончается на первом нуле, CRLF становится LF, одинокий CR остаётся; одинокий суррогат — U+FFFD, нечётный последний байт отбрасывается

## Сервер-эхо для тестов

**Суть:**
- У sample-сервера FreeRDP своего буфера обмена нет; патч `sample-clipboard.patch` добавляет ему `--clipboard-echo`: сервер просит у клиента текст из каждого его списка и объявляет его обратно с приставкой `echo: `
- Серверная часть канала — `cliprdr_server_context_new`, возможности и Monitor Ready она шлёт сама (`autoInitializationSequence`)
- Патч идёт последним по имени: он правит те же места `sfreerdp.c`, что `kerberos-nla.patch`, и сделан поверх него

**Применение:** `build-core.sh` и `build-client.sh` запускают сервер-эхо на Unix-сокете; `clipboardEchoTests` в ядре и `testClipboardRoundTrip` в приложении проверяют путь в обе стороны на arm64, под санитайзерами и на x86_64.

**Источники:**
- `core/third_party/FreeRDP/channels/cliprdr/client/cliprdr_main.c`, `cliprdr_format.c`, `include/freerdp/client/cliprdr.h`, `include/freerdp/server/cliprdr.h`, `include/freerdp/channels/cliprdr.h`
- Клиент SDL FreeRDP как образец: `client/SDL/SDL3/sdl_clip.cpp`
