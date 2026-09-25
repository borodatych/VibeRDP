# Roadmap VibeRDP

Один чекбокс — одна итерация: сделал, проверил, отметил `[x]`, коротко отчитался, остановился.
Выполненный пункт — `[x]` с датой, веткой и сутью сделанного.
Задачи — дословно из раздела 5 [idea.md](idea.md); «см.» ведёт на уточнение из [базы знаний](knowledge/README.md), найденное при сверке спецификации с документацией.
Решения на развилках — [decisions.md](decisions.md).

## Этап 0 — Каркас
- [x] **0.1 Монорепо по структуре выше, `.gitignore`, лицензия Apache-2.0, README-заглушка** — ✅ (2026-09-24, `next`) дерево по §2 [idea.md](idea.md), документы — по стандарту семейства ([карта путей](README.md)); `.vibe/` из эталона VibeBrains `c1f9476` (95 файлов, sha256 сверены), правила проекта — `.vibe/rules/viberdp.mdc` и `CLAUDE.md`; лицензия — эталон apache.org; ветки `main` и `next`; пять уточнений к спецификации — в [базе знаний](knowledge/README.md)
- [x] **0.2 FreeRDP 3.x как submodule в `core/third_party`, скрипт сборки universal static libs (arm64+x86_64) с нужными каналами (cliprdr, rail, disp, rdpgfx, drdynvc)** — ✅ (2026-09-24, `next`) FreeRDP 3.32.0 — подписанный тег, неглубокий подмодуль; OpenSSL 3.5.8 LTS — подпись проверена, sha256 в `build.env`; `core/scripts/build-freerdp.sh` собирает каждую архитектуру отдельно и склеивает `lipo`; зашитый префикс `/opt/viberdp`, OpenSSL без подгрузки модулей; скрипт проверяет срезы, macOS 14.0, пути в бинарях и линковку через пакеты CMake на arm64 и x86_64 — [devSetup.md](manuals/devSetup.md), [buildMacOS.md](knowledge/freerdp/buildMacOS.md)
- [x] **Исправление 0.2: FreeRDP падал на macOS младше 27** — ✅ (2026-09-24, `next`) проверка FreeRDP приняла `pipe2` из SDK Xcode 27, и каждое создание контекста падало на macOS 26; `WINPR_HAVE_PIPE2=OFF`, API новее минимальной macOS — ошибка компиляции, слабые ссылки ловит проверка скрипта — [buildMacOS.md](knowledge/freerdp/buildMacOS.md); срез x86_64 проверки линковки прогнан после исправления
- [x] **0.3 `VibeRDPCore`: плоский C API (create/connect/disconnect/callbacks), CMake-таргет** — ✅ (2026-09-24, `next`) `core/include/VibeRDPCore/VibeRDPCore.h` и `core/src/session.c`; `core/scripts/build-core.sh` собирает arm64, x86_64 и сборку с санитайзерами и склеивает универсальную `libVibeRDPCore.a` (с 0.4 — `VibeRDPCore.framework`); тесты на фейковых TCP-серверах и импорт в Swift: arm64 7/7, санитайзеры 6/6, x86_64 под Rosetta 7/7 — см. [toolingHangs.md](knowledge/macos/toolingHangs.md)
- [x] **0.4 `client-macos` через XcodeGen, пустое окно приложения, линковка с `VibeRDPCore`** — ✅ (2026-09-24, `next`) ядро стало динамическим `VibeRDPCore.framework` с экспортом только API `VRC*` — [решение 11](decisions.md); `client-macos/project.yml` для XcodeGen 2.46.0 (закреплён в `build.env`), AppKit без storyboard, главное окно и меню, строки меню — из базового каталога на русском; `client-macos/scripts/build-client.sh` генерирует проект, собирает универсальное приложение, проверяет срезы, macOS 14, встроенный фреймворк и подпись; тесты внутри приложения: arm64 8/8, x86_64 8/8 — [devSetup.md](manuals/devSetup.md), [xcodeClient.md](knowledge/macos/xcodeClient.md)
- [x] **0.5 `helper-win` — cargo-проект, пустой exe, сборка в CI** — ✅ (2026-09-24, `next`) exe без консоли, C-рантайм внутри (`+crt-static`), тулчейн 1.97.1 закреплён; задача CI `helper` на `windows-2025` собирает exe, `helper-win/scripts/check-exe.ps1` подтверждает x64, GUI-подсистему и зависимости только от системных `KERNEL32.dll`, `ntdll.dll` и `api-ms-win-core-synch`; exe — артефакт `vibe-seam-helper` — [helperBuild.md](knowledge/windows/helperBuild.md)
- [x] **0.6 GitHub Actions: сборка клиента (macOS) и хелпера (Windows) на каждый push** — ✅ (2026-09-24, `next`) `.github/workflows/ci.yml` в публичном `borodatych/VibeRDP`: `macos-26` с Xcode 26.6 собирает зависимости, ядро и клиент, тесты идут и под x86_64 через Rosetta раннера; Windows — exe хелпера; линт — shellcheck и actionlint закреплённых версий; приложение — артефакт `VibeRDP-app` — [решение 13](decisions.md), [githubActions.md](knowledge/ci/githubActions.md)

## Этап 1 — Базовый RDP (Desktop-режим)
- [x] **1.1 Подключение с NLA, диалог сертификата с запоминанием отпечатка** — ✅ (2026-09-24, `next`) ядро отдаёт цепочку приложению (`ExternalCertificateManagement`) и ждёт ответа вместе с отменой; RDP Security выключен, консольные колбэки FreeRDP обнулены, ошибки сведены к категориям `VRCErrorKind`; клиент: форма подключения, SecTrust, диалог с отпечатком SHA-256, запомненные отпечатки в `UserDefaults`, предупреждение о сменившемся сертификате — [решение 14](decisions.md), [clientLifecycle.md](knowledge/freerdp/clientLifecycle.md), [certificateTrust.md](knowledge/macos/certificateTrust.md); тесты: ядро на фейковом TLS-сервере — arm64 14/14, санитайзеры 13/13, x86_64 14/14; клиент — 27/27 на arm64 и x86_64, CI зелёный на Xcode 26.6; приложение объявляет доступ к локальной сети (`NSLocalNetworkUsageDescription`) — [localNetworkPrivacy.md](knowledge/macos/localNetworkPrivacy.md); **живое подключение требует проверки оператором** — [liveChecks.md](manuals/liveChecks.md), раздел 1
- [x] **1.2 Рендер фреймбуфера в Metal (RDPGFX, H.264 при наличии), окно и полноэкранный режим** — ✅ (2026-09-25, `next`) ядро рисует прямо в IOSurface формата BGRA (`gdi_init_ex` с `PIXEL_FORMAT_BGRX32`), колбэки `frameResized` и `frameUpdated`, `VRCSessionCopyFrameSurface`; RDPGFX и RemoteFX включены, смена размера сервером даёт новую поверхность; клиент: `DesktopView` на `CAMetalLayer`, `FrameRenderer` — копия или масштаб `MPSImageBilinearScale` с полями, без своих шейдеров и без Metal Toolchain; рабочий стол закрывает форму вместе с кнопкой, и сессию завершает пункт «Отключиться» в меню «Файл»; имя хоста — в подзаголовке окна; пункт «Во весь экран» с системным fn-F — [решение 15](decisions.md), [graphicsOutput.md](knowledge/freerdp/graphicsOutput.md), [metalRendering.md](knowledge/macos/metalRendering.md); H.264 — задача 1.11; тесты: ядро — arm64 16/16, санитайзеры 15/15, x86_64 16/16; клиент — 39/39 на arm64 и x86_64, в том числе живой тест с sample-сервером FreeRDP, который проигрывает запись RemoteFX; CI зелёный, в нём ни один тест Metal не пропущен — [sampleServer.md](knowledge/freerdp/sampleServer.md); сервер запускает скрипт сборки — иначе macOS держит запуск вопросом о съёмном томе, [removableVolumePrivacy.md](knowledge/macos/removableVolumePrivacy.md); у каждого теста предел в минуту; **картинку с настоящего Windows проверяет оператор** — [liveChecks.md](manuals/liveChecks.md), раздел 2
- [x] **1.3 Мышь и колесо, включая трекпад-скролл с инерцией** — ✅ (2026-09-25, `next`) очередь ввода в ядре: главный поток не ждёт сети, отправляет поток сессии, до ACTIVE события ждут в своём порядке, перемещения сливаются; кнопки, в том числе «назад» и «вперёд», и колесо в единицах Windows, поделённое на 9-битные шаги; горизонтальное колесо и боковые кнопки — по возможностям сервера; курсор сервера — `NSCursor` в масштабе картинки, просьба сервера передвинуть курсор отбрасывается; клиент: `DesktopView` принимает мышь и первый щелчок, точка вида переводится в пиксель обратным `FrameGeometry`, `WheelAccumulator` — строки колеса и точки трекпада с накоплением дробей, инерция идёт как есть — [решение 16](decisions.md), [pointerInput.md](knowledge/freerdp/pointerInput.md), [mouseInput.md](knowledge/macos/mouseInput.md); тесты: ядро — arm64 27/27, санитайзеры 26/26, x86_64 27/27; клиент — 57/57 на arm64 и x86_64, в том числе живой тест ввода на интерактивном sample-сервере — [sampleServer.md](knowledge/freerdp/sampleServer.md); **мышь, прокрутку и курсор на настоящем Windows проверяет оператор** — [liveChecks.md](manuals/liveChecks.md), раздел 3
- [x] **1.4 Клавиатура: скан-коды, маппинг Cmd/Option, настраиваемые сочетания — и сочетание для «Отключиться»: с 1.2 у пункта его нет, чтобы ⌘-комбинации доставались удалённому рабочему столу** — ✅ (2026-09-25, `next`) ядро: клавиши, фокус и отпускание нажатых идут той же очередью, что мышь, — `VRCSessionSendKey`, `VRCSessionSendFocusIn` с Caps Lock и всегда включённым Num Lock, `VRCSessionReleaseKeys`; поток сессии помнит нажатые на сервере клавиши, Pause — последовательностью mstsc; клиент: своя таблица «клавиша Мака → скан-код» вместо таблицы winpr, модификаторы по сторонам — по умолчанию левая ⌘ — Ctrl, правая — Win, набор «Как на PC»; клавиши берёт локальный монитор AppKit до меню, сочетания Мака (⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘ запятая, fn-F, ⌃⌘F) уходят AppKit целиком; «Отключиться» — ⌥⌘W; окно «Настройки…» с вкладкой «Клавиатура» на SwiftUI, галочка для клавиатур ISO — [решение 17](decisions.md), [freerdp/keyboardInput.md](knowledge/freerdp/keyboardInput.md), [macos/keyboardInput.md](knowledge/macos/keyboardInput.md); гейт слабых ссылок пропускает охраняемые символы Swift — [xcodeClient.md](knowledge/macos/xcodeClient.md); тесты: ядро — arm64 31/31, санитайзеры 30/30, x86_64 31/31; клиент — 89/89 на arm64 и x86_64, в том числе живой тест клавиши на интерактивном sample-сервере; **клавиатуру на настоящем Windows проверяет оператор** — [liveChecks.md](manuals/liveChecks.md), раздел 4
- [ ] 1.5 Профили подключений, пароли в Keychain, список подключений на SwiftUI — и запрос пароля во время подключения (`AuthenticateEx`) с повтором после неверного — _добавлено 2026-09-24, решение 14_
- [ ] 1.6 Импорт `.rdp`-файлов
- [ ] 1.7 RD Gateway
- [ ] 1.8 Переподключение при обрыве сети и при сне/пробуждении Мака
- [ ] 1.9 Локализация: языки файлами в папке, которую видит пользователь, выбор языка, откат пропавшего языка, гейт каталога — по правилу семейства; база с 0.4 — русский в бинаре (`client-macos/App/Localization.swift`); строки Info.plist (запрос доступа к локальной сети) живут вне каталога — им нужен свой путь через `InfoPlist.strings` — _добавлено вне спецификации, 2026-09-24_
- [ ] 1.10 Kerberos в NLA: разбор системного GSS.framework против MIT krb5, выбор, сборка и проверка в домене — сейчас NLA идёт через NTLM, а в доменах политика бывает его запрещает — _добавлено вне спецификации, 2026-09-24, решение 14_
- [ ] 1.11 H.264 в RDPGFX (AVC420 и AVC444): выбор декодера — FFmpeg с аппаратным ускорением VideoToolbox против своего модуля на VideoToolbox, разбор лицензий, сборка и проверка на живом хосте; до него клиент объявляет серверу, что H.264 не принимает — _добавлено 2026-09-25, решение 15_

## Этап 2 — Буфер обмена (MVP, релиз v0.1)
- [ ] 2.1 Текст в обе стороны с опросом `changeCount` и защитой от эха — см. [pasteboardPrivacy.md](knowledge/macos/pasteboardPrivacy.md)
- [ ] 2.2 HTML и RTF
- [ ] 2.3 Изображения
- [ ] 2.4 Файлы (FileGroupDescriptorW ⇄ file promises), прогресс для больших файлов
- [ ] 2.5 Чек-лист ручной проверки для оператора, сравнение поведения с Windows App
- [ ] 2.6 Сборка `.dmg`, Sparkle, релиз v0.1

## Этап 3 — Удобство Desktop-режима
- [ ] 3.1 Динамическое разрешение при ресайзе окна (Display Control)
- [ ] 3.2 Мультимонитор и Retina scale factor
- [ ] 3.3 Синхронизация раскладки RU/EN: замер вариантов А и Б, выбор, реализация — см. [keyboardLayout.md](knowledge/windows/keyboardLayout.md)
- [ ] 3.4 Звук (rdpsnd)
- [ ] 3.5 Проброс папки Мака (drive redirection), опционально в профиле

## Этап 4 — Протокол Seam и хелпер
- [ ] 4.1 `protocol/seam-protocol.md`: фрейминг, сообщения, версии, capability-флаги
- [ ] 4.2 Хелпер: открытие DVC, `HELLO`, ping/pong, переподключение, single-instance
- [ ] 4.3 Хелпер: перечисление и трекинг окон, фильтрация, extended frame bounds — см. [windowTracking.md](knowledge/windows/windowTracking.md)
- [ ] 4.4 Хелпер: иконки, заголовки, z-order, foreground
- [ ] 4.5 Хелпер: исполнение команд (activate/move/resize/min/max/restore/close)
- [ ] 4.6 Хелпер: установка в `shell:startup` без админа, флаг `--uninstall`
- [ ] 4.7 Клиент: DVC-аддин FreeRDP «VibeSeam», handshake с таймаутом и автоматическим fallback в Desktop
- [ ] 4.8 Unit-тесты протокола на обеих сторонах с мок-каналом

## Этап 5 — Seamless-окна
- [ ] 5.1 Менеджер окон клиента: модель удалённых окон из потока событий
- [ ] 5.2 Отдельный `NSWindow` на каждое удалённое окно, вывод субрегиона текстуры
- [ ] 5.3 Ввод в окна с трансляцией координат
- [ ] 5.4 Двусторонняя синхронизация: перемещение/ресайз на Маке ⇄ `SetWindowPos` на хосте
- [ ] 5.5 Фокус и z-order в обе стороны, смягчение артефактов перекрытий
- [ ] 5.6 Попапы, меню и тултипы (owned windows) как дочерние окна владельца
- [ ] 5.7 Переключатель режима на лету: Desktop ⇄ Seam без переподключения

## Этап 6 — Интеграция с macOS
- [ ] 6.1 Иконки удалённых приложений в Dock и в Cmd+Tab (группировка по exe)
- [ ] 6.2 Mission Control, полноэкранный режим отдельного окна
- [ ] 6.3 Лаунчер: список ярлыков «Пуск» от хелпера и запуск приложения с Мака
- [ ] 6.4 Минимизация и восстановление в обе стороны

## Этап 7 — RAIL
- [ ] 7.1 Попытка RAIL при подключении и fallback-цепочка RAIL → Seam → Desktop — см. [railSession.md](knowledge/rdp/railSession.md)
- [ ] 7.2 Вывод RAIL-окон через тот же менеджер окон, что в этапе 5
- [ ] 7.3 Документация по включению RemoteApp для тех, у кого есть админ

## Этап 8 — Релиз v1.0
- [ ] 8.1 Настройки: режимы, маппинг клавиш, интервал опроса буфера, логи — и скорость прокрутки трекпада, сейчас константа `WheelAccumulator.unitsPerPoint` — _добавлено 2026-09-25, решение 16_
- [ ] 8.2 Диагностика: экспорт логов, страница «почему не включился Seam» — см. [appLocker.md](knowledge/windows/appLocker.md)
- [ ] 8.3 README с гифками, `docs/` для хелпера
- [ ] 8.4 Подпись и нотаризация (при наличии Apple Developer ID; иначе инструкция по снятию карантина)
- [ ] 8.5 Релиз v1.0

## Предложения (без команды оператора не трогать)
- Linux-клиент на той же схеме (FreeRDP SDL + свой Seam-аддин)
- Windows-клиент с seamless-режимом
- Мульти-сессии: окна с двух хостов одновременно
- Прозрачный проброс уведомлений Windows в Notification Center
- Синхронизация тёмной темы Мака с хостом
- Drag-and-drop файлов между Mac-окнами и seamless-окнами
- Интеграционные тесты ядра против локального RDP-сервера FreeRDP (sample или shadow server): состояние Connected, каналы и NLA без Windows-машины
- Захват системных сочетаний (⌘Tab, ⌘Space и других) для Windows через `CGEventTap` — отдельной галочкой с запросом разрешения на универсальный доступ — _добавлено 2026-09-25, задача 1.4_
- Пункт меню «Отправить Ctrl+Alt+Del»: отправляет Ctrl+Alt+End, чтобы не набирать ⌘⌥ + fn + → — _добавлено 2026-09-25, задача 1.4_
