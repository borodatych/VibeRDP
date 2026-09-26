# FreeRDP: сборка сообщения статического канала из кусков

Сверено по исходникам FreeRDP 3.32.0, истории его основной ветки и журналу живой проверки — 2026-09-26 (решение 36).
Патч — `core/freerdp/patches/channel-total-length.patch`; тест — `clipboardLargeRoundTrip` в `core/tests/clipboardEchoTests.c`.

## Дефект 3.32.0: всё больше одного куска рвёт сессию

**Суть:**
- Сообщение статического канала приходит кусками до 1600 байт с флагами `CHANNEL_FLAG_FIRST` и `CHANNEL_FLAG_LAST`; `channel_client_post_message` собирает их в поток (`channels/client/addin.c:640-735`)
- В 3.32.0 поток заводится по размеру первого куска (`Stream_New(nullptr, dataLength)`), а растёт через `Stream_EnsureRemainingCapacity`, которая округляет ёмкость вверх до кратного 128 и всегда оставляет запас (`winpr/libwinpr/utils/stream.c:44-91`)
- На последнем куске проверка `Stream_Capacity(data_in) != Stream_GetPosition(data_in)` для сообщения из двух и больше кусков почти всегда истинна: `read error` и `ERROR_INTERNAL_ERROR` (1359)
- Ошибка канала для FreeRDP фатальна: `checkChannelErrorEvent` → `ERRCONNECT_CONNECT_TRANSPORT_FAILED`, и сессия рвётся как при обрыве сети
- В журнале: `cliprdr_plugin_process_received: read error`, затем `cliprdr_virtual_channel_open_event_ex ... failed with error 1359`
- У живой Windows так рвала сессию копия 130 строк в Блокноте; с Мака на Windows дефект не виден — собирает сервер
- Внесено коммитом `ead997147` «allocate buffer only for data received» (2026-09-21), исправлено коммитом `190167212` «correct and tighthen length checks» (2026-09-24): длина сообщения запоминается на первом куске и сравнивается с позицией; то же в drdynvc, encomsp, rdpdr, rdpsnd, remdesk и прокси
- sample-сервер FreeRDP воспроизводит дефект: его ответы тоже режутся на куски по 1600 байт

**Применение:**
- Коммит `190167212` наложен патчем целиком, без правок; снять при переходе на релиз, где он есть — пункт в roadmap
- Живые тесты буфера раньше гоняли только крошечные данные и дефект не видели; `clipboardLargeRoundTrip` возит 122 КБ текста и картинку и без патча падает на той же ошибке

## Переподключение после ошибки канала

**Суть:**
- После такой ошибки FreeRDP считает обрыв сетевым и сразу, через 50 мс, начинает переподключение
- Живая Windows в обоих случаях 2026-09-26 ответила на повторное подключение `ERRINFO_RPC_INITIATED_DISCONNECT` на этапе обмена возможностями, и сессия закончилась без восстановления
- Причина _не разобрана_: вероятно, сервер ещё держит прежнее подключение, которое клиент бросил сам, а не сеть — пункт в roadmap

**Источники:**
- `core/third_party/FreeRDP/channels/client/addin.c`, `winpr/libwinpr/utils/stream.c`
- https://github.com/FreeRDP/FreeRDP/commit/190167212b9af27d375b09e75a8e3e41aa7d0284, https://github.com/FreeRDP/FreeRDP/commit/ead997147
- Журнал владельца `~/VibeRDP/logs/viberdp-2026-09-26-12-36-28.log`, 12:43:49 и 12:44:08
