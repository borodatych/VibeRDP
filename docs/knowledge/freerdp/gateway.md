# FreeRDP: RD Gateway

Сверено по исходникам FreeRDP 3.32.0 — 2026-09-25, задача 1.7.
Реализация — `applyGateway` и `presentGatewayMessage` в `core/src/session.c`, сторона приложения — `ConnectionViewController`.

## Включение и транспорты

**Суть:**
- Шлюз включает `freerdp_set_gateway_usage_method`: `TSC_PROXY_MODE_DIRECT` (1) — всегда, `TSC_PROXY_MODE_DETECT` (2) — всегда, кроме локальной сети (`GatewayBypassLocal`), `NONE_DIRECT` (0), `DEFAULT` (3) и `NONE_DETECT` (4) — напрямую (`libfreerdp/common/settings.c:1099-1135`, константы — `include/freerdp/settings_types.h:280-284`)
- Порт шлюза по умолчанию — 443; по умолчанию включены транспорты HTTP (RDG с websocket) и RPC (`libfreerdp/core/settings.c:998`, `1211-1218`)
- Со шлюзом первым идёт TLS к шлюзу, и первый вопрос о сертификате — о сертификате шлюза, с его именем и портом; тест `gatewayComesFirst` подтверждает это на фейковом TLS-сервере без согласования RDP

## Учётные данные

**Суть:**
- Шлюз спрашивает `utils_authenticate_gateway` с причинами `GW_AUTH_HTTP`, `GW_AUTH_RDG`, `GW_AUTH_RPC` и слотами `Gateway*`, если нет имени или пароля шлюза (`libfreerdp/core/utils.c:98-189`)
- `GatewayUseSameCredentials` копирует учётные данные между компьютером и шлюзом в `utils_sync_credentials`: после вопроса шлюза — шлюз → компьютер, после вопроса компьютера — компьютер → шлюз (`utils.c:301-326`)
- Сам движок пароль компьютера шлюзу заранее не отдаёт: без пароля шлюза вопрос шлюза придёт, даже если пароль компьютера известен
- Отказ шлюза HTTP 401 превращается в `FREERDP_ERROR_CONNECT_ACCESS_DENIED` (`libfreerdp/core/gateway/rdg.c:1551-1552`, также `wst.c:506`, `rpc_client.c:668`)

**Применение:**
- С «теми же учётными данными» ядро кладёт имя и пароль компьютера и в слоты шлюза: вопросов нет, если пароль известен, и один, если нет
- Приложение объясняет «доступ запрещён» при шлюзе как отказ шлюза и спрашивает пароль снова

## Сообщения шлюза

**Суть:**
- Шлюз присылает согласие (`GATEWAY_MESSAGE_CONSENT`, обычно с обязательным согласием) и служебные сообщения (`GATEWAY_MESSAGE_SERVICE`); движок зовёт `PresentGatewayMessage(instance, type, isDisplayMandatory, isConsentMandatory, length, message)`, где `message` — UTF-16, а `length` — в байтах (`rdg.c:890-904`, `1855-1867`, `tsg.c:1555-1575`)
- Без колбэка `IFCALLRESULT(TRUE, …)` возвращает TRUE — то есть согласие принимается молча
- FALSE из колбэка обрывает подключение

**Применение:** ядро переводит текст в UTF-8 и отдаёт приложению; обязательное согласие ждёт `VRCSessionResolveGatewayMessage` или прерывания, а без колбэка приложения отклоняется.

**Не проверено:** настоящий шлюз — у агента его нет; раздел 7 [чек-листа оператора](../../manuals/liveChecks.md).
