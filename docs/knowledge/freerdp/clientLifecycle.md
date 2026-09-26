# FreeRDP: жизненный цикл клиента в VibeRDPCore

Сверено по исходникам FreeRDP 3.32.0 и тестам `core/tests` — 2026-09-24, дополнено на задачах 1.1 и 1.2.
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
- После подключения ядро поднимает программный GDI поверх IOSurface в формате `PIXEL_FORMAT_BGRX32`, а не `XRGB32` из `client/Sample` — [graphicsOutput.md](graphicsOutput.md)
- Защита от вызова `VRCSessionDestroy` из колбэка — переменная `_Thread_local`, а не сравнение идентификаторов потоков
- Замер тестами: отмена во время подключения и уничтожение сессии укладываются в ~100 мс

## RDP8-функции тянут каналы rdpdr и rdpsnd

**Суть:**
- `freerdp_client_load_addins` включает `DeviceRedirection`, если включена любая из `NetworkAutoDetect`, `SupportHeartbeatPdu`, `SupportMultitransport` — с пометкой, что этим RDP8-функциям нужен зарегистрированный rdpdr (`client/common/cmdline.c:6282`)
- При `DeviceRedirection` FreeRDP загружает статический канал rdpdr и добавляет rdpsnd с подсистемой `sys:fake` (`cmdline.c:6401-6417`)
- Все три функции по умолчанию включены (`libfreerdp/core/settings.c`)
- Проверено: без выключения этих функций сборка с пятью каналами падает ещё до TCP — `Failed to load channel rdpdr`, затем `ERRCONNECT_PRE_CONNECT_FAILED`

**Применение:** до 0.1.17 VibeRDPCore выключал все три функции; с rdpdr и rdpsnd в сборке автоопределение сети и heartbeat включены (`applyNetwork`), UDP-транспорт — нет — развилка 9 в [decisions.md](../../decisions.md).

**Звук (2026-09-26):** `AudioPlayback` добавляет rdpsnd в статические и динамические каналы, а тот включает `DeviceRedirection` с пометкой «rdpsnd requires rdpdr to be registered» — без rdpdr в сборке подключение со звуком падает так же; rdpsnd выбирает подсистему по порядку из доступных, на Маке — `mac` (`channels/rdpsnd/client/rdpsnd_main.c:1060-1085`), которая есть, только если собрано с `WITH_MACAUDIO=ON`; вывод — AudioQueue, форматы — только PCM (`channels/rdpsnd/client/mac/rdpsnd_mac.m:241-247`); `RemoteConsoleAudio` оставляет звук на сервере — [решение 45](../../decisions.md).

## Консольные колбэки клиентской библиотеки

**Суть:**
- `freerdp_client_context_new` ставит колбэки для консоли (`set_default_callbacks`, `client/common/client.c:128`): `AuthenticateEx`, `ChooseSmartcard`, `PresentGatewayMessage` и `GetAccessToken` читают stdin, `VerifyCertificateEx`, `VerifyChangedCertificateEx` и `LogonErrorInfo` печатают в него
- Проверено: без имени пользователя подключение к серверу, выбравшему TLS, напечатало `Username:` и попыталось читать stdin — в приложении это тихая поломка
- `ClientNew` из точек входа вызывается после них и может их заменить; повторно их ставит только старт клиента с `UseCommonStdioCallbacks`, а эта настройка по умолчанию выключена и включается лишь опцией командной строки
- Без `AuthenticateEx` движок продолжает без вопросов: `utils_authenticate` возвращает `AUTH_NO_CREDENTIALS` (`libfreerdp/core/utils.c:252-256`); так же обнуляет колбэки собственный тест FreeRDP (`libfreerdp/core/test/TestConnect.c:29`)

**Применение:** `clientNew` в `core/src/session.c` обнуляет все семь; запрос пароля во время подключения — задача 1.5.

## Сертификат сервера проверяет приложение

**Суть:**
- С `ExternalCertificateManagement` FreeRDP не смотрит ни в своё хранилище `known_hosts`, ни в хранилище OpenSSL и отдаёт решение `VerifyX509Certificate` (`libfreerdp/crypto/tls.c:1814`)
- Колбэк получает всю цепочку в PEM: сертификат сервера, затем цепочку пира (`freerdp_certificate_get_pem_ex` с `withCertChain`); на клиенте OpenSSL начинает цепочку пира с того же сертификата сервера, так что он приходит дважды
- Ответ больше нуля принимает сертификат только для этого подключения, ноль и меньше рвут TLS-рукопожатие (`tls.c:1095`); хранилище в этом режиме только вычисляет пути и ничего не пишет
- FreeRDP проверяет сертификат после того, как TLS-рукопожатие завершилось: сервер видит успешное рукопожатие и при отказе, а согласие видно лишь по тому, что клиент пошёл дальше — прислал первые данные RDP
- Отказ даёт `ERRCONNECT_TLS_CONNECT_FAILED` — тот же код, что и сбой самого рукопожатия; различить их может только тот, кто отказал, поэтому ядро помнит свой отказ и сообщает категорию `CertificateRejected`

**Применение:**
- `verifyX509Certificate` в ядре отдаёт цепочку колбэку `verifyCertificate` и ждёт `VRCSessionResolveCertificate` вместе с событием прерывания `freerdp_abort_event`: отмена снимает ожидание за ~1 мс и не считается ошибкой
- Без колбэка `verifyCertificate` сертификат отклоняется без вопросов
- Доверие решает клиент — [macos/certificateTrust.md](../macos/certificateTrust.md)

## Повтор подключения после обрыва транспорта

**Суть:** если `rdp_client_connect` кончается ошибкой `FREERDP_ERROR_CONNECT_TRANSPORT_FAILED`, `freerdp_connect` один раз переподключается сам (`libfreerdp/core/freerdp.c:225`); принятый в этой сессии сертификат на повторе не спрашивается снова.

**Применение:** тест `certificateAccepted` видит, что клиент дважды прошёл поверх TLS, а вопрос о сертификате был один.

## Имя пользователя, безопасность и SIGPIPE

**Суть:**
- `freerdp_parse_username` (`client/common/cmdline.c:1352`) делит `DOMAIN\user`, а `user@domain` оставляет целиком с пустым доменом — не NULL: так его ждут CredSSP и Client Info PDU
- Устаревший слой RDP Security выключается `FreeRDP_RdpSecurity = FALSE`; NLA и TLS остаются: клиент запрашивает `SSL|HYBRID|HYBRID_EX`
- На macOS FreeRDP сам ставит своему сокету `SO_NOSIGPIPE` (`libfreerdp/core/tcp.c:1072`, макрос `__MACOSX__` из `winpr/platform.h`); обработчики сигналов процесса из `freerdp_handle_signals` ядру не нужны

**Применение:** ядро делит имя через `freerdp_parse_username`, только когда домен не задан отдельно; тестовый TLS-сервер ставит `SO_NOSIGPIPE` своему сокету — без этого клиент, ушедший посреди рукопожатия, убивал тестовый процесс сигналом.

## Категории ошибок

**Суть:** коды `FREERDP_ERROR_*` ядро сводит к `VRCErrorKind`: имя не найдено, узел не принимает подключения, обрыв, сбой защиты, сертификат не принят, неверные учётные данные, ограничения учётной записи, смена пароля, прочее; текст для пользователя пишет приложение, английское имя кода остаётся для поддержки.

## Коды ошибок, которые видят тесты

- Порт закрыт: `0x00020006` `ERRCONNECT_CONNECT_FAILED` — «The connection failed.»
- Сервер принял TCP и сразу закрыл: `0x0002000d` `ERRCONNECT_CONNECT_TRANSPORT_FAILED` — «The connection transport layer failed.»
- Канал не загрузился на этапе подготовки: `0x00020001` `ERRCONNECT_PRE_CONNECT_FAILED`
- Сертификат не принят: `0x00020008` `ERRCONNECT_TLS_CONNECT_FAILED`
- Имя в зоне `.invalid` не разрешилось: категория `HostNotFound`

## Swift видит API как задумано

**Суть:**
- Перечисления с `enum_extensibility(closed)` и базовым типом `int32_t` приходят в Swift как нативные `enum`: `VRCSessionState.connecting`, `VRCResult.OK`
- При печати импортированные перечисления показывают только тип (`__C.VRCSessionState`), без имени случая
- `module.modulemap` в `core/include` даёт `import VibeRDPCore`; CMake собирает Swift только генераторами Ninja и Xcode, а `swiftc` не принимает UndefinedBehaviorSanitizer

**Источники:**
- `core/third_party/FreeRDP/client/Sample/tf_freerdp.c`, `client/Mac/mf_client.m`, `client/Mac/MRDPView.m`
- `core/third_party/FreeRDP/client/common/client.c`, `client/common/cmdline.c:6198-6420`
- `core/third_party/FreeRDP/libfreerdp/core/freerdp.c`, `libfreerdp/core/rdp.c`, `libfreerdp/core/tcp.c`, `libfreerdp/crypto/tls.c`
- `core/third_party/FreeRDP/libfreerdp/crypto/tls.c:1757-2090`, `libfreerdp/core/utils.c:230-285`, `libfreerdp/core/tcp.c:1072`
- `core/tests/sessionTests.c`, `core/tests/tlsServer.c`, `core/tests/swift/main.swift`
