# FreeRDP: клавиатура в VibeRDPCore

Сверено по исходникам FreeRDP 3.32.0 — 2026-09-25, задача 1.4.
Реализация — `core/src/input.c` и `core/src/session.c`, сторона macOS — [macos/keyboardInput.md](../macos/keyboardInput.md).

## Как клавиша идёт по протоколу

**Суть:**
- Клавиша RDP — скан-код набора 1: байт кода и признак расширенной клавиши `KBDEXT` (0x100), у FreeRDP это `MAKE_RDP_SCANCODE` (`include/freerdp/scancode.h:33-35`)
- Код выше 0x7F — не клавиша: старший бит в клавиатурном протоколе означает отпускание
- `freerdp_input_send_keyboard_event_ex(input, down, repeat, scancode)` сам ставит флаги: `KBD_FLAGS_EXTENDED` у расширенной, `KBD_FLAGS_RELEASE` у отпускания, `KBD_FLAGS_DOWN` у повтора нажатия (`libfreerdp/core/input.c:1064-1074`, флаги — `include/freerdp/input.h:31-36`)
- У Pause своего скан-кода нет: `RDP_SCANCODE_PAUSE` (расширенный 0x46) — условное имя (`scancode.h:180-181`), а `freerdp_input_send_keyboard_pause_event` шлёт последовательность mstsc — Ctrl и Num Lock с `KBD_FLAGS_EXTENDED1` (`input.c:358-382`)
- Символ из скан-кода получает сервер своей раскладкой; раскладку сессии клиент объявляет полем `KeyboardLayout`, по умолчанию 0 (`libfreerdp/core/settings.c:992`, `libfreerdp/core/freerdp.c:138-141`)

**Применение:**
- Ядро принимает клавишу `uint16_t` в той же записи, что FreeRDP, и сверяет свои `VRC_KEY_EXTENDED` и `VRC_KEY_PAUSE` с `KBDEXT` и `RDP_SCANCODE_PAUSE` проверкой при компиляции
- `VRCSessionSendKey` отказывает коду 0, коду выше 0x7F и лишним битам — `InvalidArgument`
- Pause ядро отправляет последовательностью при нажатии, а отпускание пропускает: сервер эту клавишу нажатой не держит
- Раскладку ядро пока не объявляет — это задача 3.3

## Фокус и залипшие клавиши

**Суть:**
- `freerdp_input_send_focus_in_event(input, toggleStates)` повторяет mstsc: отпускание Tab, синхронизация Scroll, Num, Caps и Kana Lock, снова отпускание Tab (`input.c:344-356`, по fastpath — `611-644`)
- Флаги синхронизации — `KBD_SYNC_SCROLL_LOCK`, `KBD_SYNC_NUM_LOCK`, `KBD_SYNC_CAPS_LOCK`, `KBD_SYNC_KANA_LOCK` (`input.h:55-61`)
- Сам FreeRDP не помнит, какие клавиши нажаты: если клиент потерял фокус с зажатой клавишей, на сервере она так и останется нажатой

**Применение:**
- Поток сессии ведёт битовую карту нажатых на сервере клавиш (`VRCKeyState`, 512 бит) по тем событиям, что действительно отправил
- `VRCSessionReleaseKeys` ставит в очередь событие, по которому поток сессии отпускает все нажатые клавиши, — после ⌘Tab ничего не залипает
- `VRCSessionSendFocusIn(capsLock, numLock)` идёт той же очередью: событие ждёт ACTIVE, как мышь

## Таблица winpr для Мака не годится

**Суть:**
- `GetVirtualKeyCodeFromKeycode(..., WINPR_KEYCODE_TYPE_APPLE)` отдаёт правый ⌃ (0x3E) и fn (0x3F) как `VK_RWIN`, а JIS-клавиши ¥ и _ — как `VK_NONE` (`winpr/libwinpr/input/keycode.c:97-98`, `128`)
- Upstream Mac-клиент в `flagsChanged` шлёт каждый модификатор как левый, а ⌘ всегда как левую клавишу Windows (`client/Mac/MRDPView.m:481-660`)
- Перестановку ISO-клавиш upstream делает по `KBGetLayoutType` (`MRDPView.m:425-478`); этой функции нет в заголовках SDK

**Применение:** у клиента своя таблица «код клавиши Мака → скан-код» по именам `kVK_` из `Events.h` и `scancode.h` — `client-macos/Session/KeyCodeMap.swift`; модификаторы ⌃, ⌥ и ⌘ в ней нет, их скан-код выбирают настройки.

## Живой тест: клавиша G sample-сервера

**Суть:** интерактивный sample-сервер по нажатию G переключает рабочий стол между 800×600 и размером по умолчанию и вызывает `DesktopResize`, сбрасывая активацию (`server/Sample/sfreerdp.c:882-909`).

**Применение:** `testKeyReachesTheServer` нажимает G дважды и ждёт новый размер кадра — так проверяется весь путь клавиши до сервера, а второе нажатие заодно проверяет, что событие дождалось повторной активации в очереди — [sampleServer.md](sampleServer.md).
