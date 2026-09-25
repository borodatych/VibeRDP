# FreeRDP: переподключение

Сверено по исходникам FreeRDP 3.32.0 — 2026-09-25, задача 1.8.
Реализация — `serveConnection`, `restoreConnection`, `reconnectAttempt` и `stillWanted` в `core/src/session.c`; живой тест — `testDroppedConnectionIsRestored`.

## Какой обрыв восстанавливается

**Суть:**
- `client_auto_reconnect_ex(instance, window_events)` восстанавливает только обрыв сети: код `freerdp_error_info` должен быть `ERRINFO_SUCCESS` или `ERRINFO_GRAPHICS_SUBSYSTEM_FAILED`, иначе конец выбрал сервер (`client/common/client.c:1465-1481`)
- Не восстанавливаются и обрывы из-за учётных данных — `CONNECT_LOGON_FAILURE`, `WRONG_PASSWORD`, `ACCESS_DENIED`, `ACCOUNT_*`, `NO_OR_MISSING_CREDENTIALS` — и отмена пользователем (`client.c:1490-1509`)
- Без `AutoReconnectionEnabled` цикл сразу выходит; по умолчанию настройка выключена, попыток — 20 (`libfreerdp/core/settings.c:1227-1228`)
- Перед каждой попыткой цикл спрашивает `RetryDialog(instance, "connection", n, NULL)`: ответ — пауза в миллисекундах после неудачной попытки, отрицательный — конец; без колбэка пауза 5000 мс (`client.c:1522-1552`)
- Во время паузы цикл каждые 10 мс зовёт `window_events`; FALSE — конец
- `freerdp_reconnect` → `rdp_client_reconnect`: разрыв транспорта, сброс последней ошибки и события прерывания (`rdp_client_disconnect_and_clear`, `libfreerdp/core/connection.c:537-556`), новое подключение с `SessionHasBeenReconnected`; `PostConnect` второй раз не зовётся, так что GDI и поверхность клиента переживают переподключение (`connection.c:559-593`, `727-740`)
- Сервер, который закрывает сессию «по правилам» (`freerdp_peer_close`), шлёт Deactivate All и Error Info — sample-сервер по клавише X шлёт `ERRINFO_LOGOFF_BY_USER`, — и такой конец не восстанавливается

**Применение:**
- Ядро включает `AutoReconnectionEnabled`: клиент сообщает серверу, что умеет переподключаться, и возвращается в тот же сеанс Windows
- Событие прерывания FreeRDP сбрасывает перед каждой попыткой, поэтому отключение пользователя живёт в своём флаге `ending`; его проверяют `RetryDialog` и `window_events`
- Ввод из очереди обрыва выбрасывается, учёт нажатых клавиш обнуляется

## Сон Мака и TCP keepalive

**Суть:**
- FreeRDP ставит TCP keepalive: 5 секунд тишины, затем 3 пробы через 2 секунды (`settings.c:1279-1284`); на Unix-сокете sample-сервера `setsockopt` с этими TCP-опциями пишет WARN — к локальному сокету они не применимы
- _Не проверено:_ насколько быстро keepalive замечает умершее соединение на TCP-сокете macOS после сна
- Refresh Rect PDU — просьба к серверу прислать область заново — отправляется через `context->update->RefreshRect`

**Применение:** после пробуждения Мака приложение зовёт `VRCSessionRefresh`: запись в умершее соединение проваливается сразу, и переподключение начинается без ожидания keepalive.

## Живой тест: обрыв без причины

**Суть:** `freerdp_peer_close` у sample-сервера — «вежливый» конец с Error Info, а `freerdp_peer_disconnect` просто закрывает транспорт (`libfreerdp/core/peer.c:1208-1253`).

**Применение:** патч `core/scripts/test-server/network-drop.patch` вешает на клавишу D `client->Disconnect`: для клиента это обрыв сети, и тест ждёт состояния Connecting, Connected, Reconnecting, Connected — [sampleServer.md](sampleServer.md).
