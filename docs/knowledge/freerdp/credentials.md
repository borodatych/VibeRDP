# FreeRDP: вопрос об учётных данных

Сверено по исходникам FreeRDP 3.32.0 — 2026-09-25, задача 1.5.
Реализация — `authenticate` в `core/src/session.c`, сторона приложения — `ConnectionViewController` и `CredentialsPrompt`.

## Когда движок спрашивает

**Суть:**
- Спрашивает `utils_authenticate` (`libfreerdp/core/utils.c:191-296`) через `instance->AuthenticateEx(instance, &username, &password, &domain, reason)`
- Для NLA (`AUTH_NLA`, из `nla_client_setup_identity`, `libfreerdp/core/nla.c:374-389`) — только если нет имени пользователя или пароля
- Для TLS и RDP (`AUTH_TLS` из `transport_connect_tls`, `AUTH_RDP` из `transport_connect_rdp`, `libfreerdp/core/transport.c:270-320`) — если нет хотя бы одного из двух: `utils_auth_skip` пропускает вопрос, только когда есть оба (`utils.c:70-93`)
- Над TLS вопрос приходит до рукопожатия, то есть раньше вопроса о сертификате; над NLA — после сертификата
- Шлюз спрашивает `utils_authenticate_gateway` с причинами `GW_AUTH_HTTP`, `GW_AUTH_RDG`, `GW_AUTH_RPC` и слотами `Gateway*` (`utils.c:95-189`)
- Ответ FALSE — `AUTH_CANCELLED`, и подключение кончается с `FREERDP_ERROR_CONNECT_CANCELLED`; ответ TRUE с пустыми строками — `AUTH_NO_CREDENTIALS`, и движок идёт дальше без них (`utils.c:275-277`, `nla.c:382-386`)
- Слоты — строки настроек движка: старое значение освобождается, новое выделяется `malloc`; после ответа `utils_authenticate` копирует их и в исходные настройки, так что повтор соединения внутри `freerdp_connect` второй раз не спрашивает
- Без `AuthenticateEx` движок не спрашивает никого: NLA без пароля идёт с пустой идентичностью и получает отказ сервера
- После отказа сервера из-за неверного пароля FreeRDP подключение не повторяет: `freerdp_connect` возвращает FALSE с `FREERDP_ERROR_AUTHENTICATION_FAILED` или `CONNECT_LOGON_FAILURE`

**Применение:**
- Ядро спрашивает приложение колбэком `credentialsNeeded` и ждёт ответа или прерывания, как с сертификатом; ответ и его состояние живут под мьютексом, копии пароля перед освобождением затираются `memset_s`
- Имя в вопросе склеивается в `ДОМЕН\пользователь`, ответ разбирается по тому же правилу, что и имя при подключении, — `splitUsername`
- Причины смарт-карты и FIDO ядро отклоняет: клиент входит только паролем
- Повтор после неверного пароля делает приложение — новой сессией; тесты — `credentialsProvided`, `credentialsShowTheUserName`, `credentialsCancelled`, `disconnectWhileCredentialsPending`, живой — `LiveServerTests`: sample-сервер говорит по TLS, и вопрос приходит ровно один раз
