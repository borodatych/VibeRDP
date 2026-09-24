# FreeRDP: жизненный цикл клиента в VibeRDPCore

Сверено по исходникам FreeRDP 3.32.0 и тестам `core/tests` — 2026-09-24.
Реализация — `core/src/session.c`, публичный API — `core/include/VibeRDPCore/VibeRDPCore.h`.

## Поток сессии и остановка

**Суть:**
- Клиент описывается точками входа `RDP_CLIENT_ENTRY_POINTS`: `freerdp_client_context_new` выделяет контекст размером `ContextSize`, так что свой тип клиента — это структура, первым полем которой лежит `rdpClientContext`
- Mac-клиент апстрима создаёт поток в `ClientStart` через `CreateThread` и кладёт его в `common.thread`, а `ClientStop` отдаёт `freerdp_client_common_stop`: тот зовёт `freerdp_abort_connect_context` и ждёт поток (`client/Mac/MRDPView.m`, `client/common/client.c`)
- Событие прерывания входит в набор ожидания цикла (`rdp_get_event_handles`, `libfreerdp/core/rdp.c`) и в ожидание TCP-подключения (`libfreerdp/core/tcp.c:836`): прерывание снимает сессию на любом этапе
- `freerdp_abort_connect_context` ставит последней ошибкой `FREERDP_ERROR_CONNECT_CANCELLED`, только если ошибки ещё нет: по коду отличается отмена пользователем от настоящей причины
- `GlobalInit` вызывается через `IFCALLRESULT` и может отсутствовать; `client/Sample` ставит в нём `freerdp_handle_signals()` — обработчики сигналов процесса, которым в библиотеке приложения не место
- `CreateThread` в WinPR не заполняет идентификатор потока (параметр помечен `WINPR_ATTR_UNUSED`, `winpr/libwinpr/thread/thread.c:679`)

**Применение:**
- Все колбэки VibeRDPCore идут из потока сессии; отмена через `VRCSessionDisconnect` не сообщается как ошибка
- После подключения ядро поднимает программный GDI, как `client/Sample`: `gdi_init(instance, PIXEL_FORMAT_XRGB32)`; формат пикселей ещё предстоит согласовать с выводом через Metal
- Защита от вызова `VRCSessionDestroy` из колбэка — переменная `_Thread_local`, а не сравнение идентификаторов потоков
- Замер тестами: отмена во время подключения и уничтожение сессии укладываются в ~100 мс

## RDP8-функции тянут каналы rdpdr и rdpsnd

**Суть:**
- `freerdp_client_load_addins` включает `DeviceRedirection`, если включена любая из `NetworkAutoDetect`, `SupportHeartbeatPdu`, `SupportMultitransport` — с пометкой, что этим RDP8-функциям нужен зарегистрированный rdpdr (`client/common/cmdline.c:6282`)
- При `DeviceRedirection` FreeRDP загружает статический канал rdpdr и добавляет rdpsnd с подсистемой `sys:fake` (`cmdline.c:6401-6417`)
- Все три функции по умолчанию включены (`libfreerdp/core/settings.c`)
- Проверено: без выключения этих функций сборка с пятью каналами падает ещё до TCP — `Failed to load channel rdpdr`, затем `ERRCONNECT_PRE_CONNECT_FAILED`

**Применение:** VibeRDPCore выключает все три функции перед подключением; вернуть их можно, только добавив rdpdr и rdpsnd в сборку — развилка 9 в [decisions.md](../../decisions.md).

## Сертификаты и учётные данные по умолчанию

**Суть:**
- Если не заданы ни `VerifyCertificateEx`, ни `AutoAcceptCertificate`, FreeRDP отклоняет сертификат: `accept_certificate` начинается с 0 (`libfreerdp/crypto/tls.c:1897`)
- Хранилище принятых сертификатов FreeRDP ведёт в `FreeRDP_ConfigPath` (по умолчанию `~/.config/freerdp`); тесты до TLS не доходят и туда не пишут

**Применение:** до задачи 1.1 VibeRDPCore не принимает ни одного сертификата — безопасное поведение по умолчанию; колбэк проверки появится вместе с диалогом.

## Коды ошибок, которые видят тесты

- Порт закрыт: `0x00020006` `ERRCONNECT_CONNECT_FAILED` — «The connection failed.»
- Сервер принял TCP и сразу закрыл: `0x0002000d` `ERRCONNECT_CONNECT_TRANSPORT_FAILED` — «The connection transport layer failed.»
- Канал не загрузился на этапе подготовки: `0x00020001` `ERRCONNECT_PRE_CONNECT_FAILED`

## Swift видит API как задумано

**Суть:**
- Перечисления с `enum_extensibility(closed)` и базовым типом `int32_t` приходят в Swift как нативные `enum`: `VRCSessionState.connecting`, `VRCResult.OK`
- При печати импортированные перечисления показывают только тип (`__C.VRCSessionState`), без имени случая
- `module.modulemap` в `core/include` даёт `import VibeRDPCore`; CMake собирает Swift только генераторами Ninja и Xcode, а `swiftc` не принимает UndefinedBehaviorSanitizer

**Источники:**
- `core/third_party/FreeRDP/client/Sample/tf_freerdp.c`, `client/Mac/mf_client.m`, `client/Mac/MRDPView.m`
- `core/third_party/FreeRDP/client/common/client.c`, `client/common/cmdline.c:6198-6420`
- `core/third_party/FreeRDP/libfreerdp/core/freerdp.c`, `libfreerdp/core/rdp.c`, `libfreerdp/core/tcp.c`, `libfreerdp/crypto/tls.c`
- `core/tests/sessionTests.c`, `core/tests/swift/main.swift`
