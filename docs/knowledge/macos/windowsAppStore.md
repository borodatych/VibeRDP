# macOS: где Windows App хранит подключения

Проверено 2026-09-25 на Windows App 11.4.1, macOS 26.6.2, задача 1.13.
Реализация — `client-macos/Connections/WindowsAppStore.swift`, решение 30 в [decisions.md](../../decisions.md).

## Хранилище

**Суть:**
- Идентификатор приложения — `com.microsoft.rdc.macos`, тот же, что у прежнего Microsoft Remote Desktop
- Подключения — в базе Core Data SQLite: `~/Library/Containers/com.microsoft.rdc.macos/Data/Library/Application Support/com.microsoft.rdc.macos/com.microsoft.rdc.application-data.sqlite`
- База пишется с журналом WAL: свежие изменения лежат в `-wal`, пока Windows App не сольёт их в базу; без `-wal` и `-shm` копия теряет недавние правки
- Общий контейнер `~/Library/Group Containers/UBF8T346G9.com.microsoft.rdc` держит только данные для Spotlight

**Применение:** VibeRDP копирует базу вместе с `-wal` и `-shm` во временную папку, открывает копию и удаляет её после чтения; живую базу он не открывает.

## Таблицы

**Суть:**
- `ZBOOKMARKENTITY` — подключение к компьютеру: `ZFRIENDLYNAME`, `ZHOSTNAME`, `ZRDPSTRING` — целый `.rdp` со строками через CR, ссылки `ZCREDENTIAL` и `ZGATEWAY` на `Z_PK` других таблиц
- `ZCREDENTIALENTITY` — учётная запись: `ZUSERNAME`, `ZFRIENDLYNAME`; пароля в базе нет, он в связке ключей Windows App
- `ZGATEWAYENTITY` — шлюз: `ZHOSTNAME` и своя ссылка `ZCREDENTIAL`
- `ZWORKSPACEENTITY` и `ZREMOTERESOURCEENTITY` — рабочие области Azure Virtual Desktop, подписки на ленты, а не подключения
- Пустое имя в базе — `NULL`

**Применение:**
- Профиль строится из `.rdp` закладки тем же `RdpFile`, что при импорте файла; сверху — имя, пользователь и шлюз из таблиц
- Шлюз, чья учётная запись совпадает с учётной записью компьютера или не задана, получает те же имя и пароль
- Таблицы и колонки проверяются перед запросом: новая схема даёт отказ с объяснением, а не пустой список

## Доступ к данным другого приложения

**Не проверено:** macOS 14 и новее может спросить, разрешить ли VibeRDP доступ к данным других приложений; терминал агента прочитал базу без вопроса, а сам VibeRDP — проверяет оператор, [liveChecks.md](../../manuals/liveChecks.md), раздел 6.

**Применение:** базу читает только команда пользователя, а наличие Windows App проверяется через Launch Services, не касаясь её данных: вопрос, если будет, приходит в ответ на действие.
