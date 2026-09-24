# База знаний

Нетривиальные находки, грабли и проверенные факты — с источниками: URL, путь к исходнику или к заголовку SDK.
Запись без строки в этом индексе не существует: добавили файл — добавьте и строку.

## ci

- [githubActions.md](ci/githubActions.md) — образы раннеров: `macos-26` с Xcode 26.6, Xcode 27 только в preview-образе `xcode-27`; мажорные версии actions, закреплённые shellcheck, actionlint и XcodeGen с sha256 из дайджестов релизов

## freerdp

- [buildMacOS.md](freerdp/buildMacOS.md) — сборка под macOS: OpenSSL 3.5 LTS с проверкой подписи, встроенные MD4 и RC4 для NTLM, раздельная сборка архитектур, опции, которые надо выключать явно, зашитые пути под `/opt/viberdp`, подключение через пакеты CMake, а не pkg-config; `pipe2` из SDK 27 ронял FreeRDP на macOS 26 — ловится запретом API новее цели и поиском слабых ссылок
- [clientLifecycle.md](freerdp/clientLifecycle.md) — жизненный цикл клиента в ядре: поток сессии по образцу Mac-клиента, прерывание на любом этапе, отмена отличима от сбоя, RDP8-функции тянут rdpdr и rdpsnd, сертификаты без колбэка отклоняются, наблюдаемые коды ошибок

## macos

- [pasteboardPrivacy.md](macos/pasteboardPrivacy.md) — запрос разрешения на программное чтение буфера: `accessBehavior`, методы `detect*`, флаг developer preview; путь Mac → Win под ударом, план проверки на 2.1
- [xcodeClient.md](macos/xcodeClient.md) — фреймворк ядра: CMake не ставит ссылку `Modules`, экспорт только `_VRC*` и `-dead_strip`; слабые ссылки тулчейна Swift и `___chkstk_darwin` — не API новее цели; XcodeGen с переменными окружения, тесты внутри приложения под обе архитектуры и счёт тестов по xcresult
- [toolingHangs.md](macos/toolingHangs.md) — lldb и atos висят без разрешения на отладку (санитайзер — с `symbolize=0`, адреса офлайн через `atos -o`); Rosetta может перестать переводить новые программы — сперва пробный запуск с таймаутом; бывает, отпускает само, иначе перезапуск `oahd` или перезагрузка

## rdp

- [railSession.md](rdp/railSession.md) — RemoteApp заказывается флагом `INFO_RAIL` при подключении: откат RAIL → Seam/Desktop только переподключением, RAIL пробуется лишь при включении в профиле

## windows

- [keyboardLayout.md](windows/keyboardLayout.md) — `ActivateKeyboardLayout` меняет раскладку только своему процессу; чужому окну — `WM_INPUTLANGCHANGEREQUEST` через `DefWindowProc`, приложение вправе отказать
- [windowTracking.md](windows/windowTracking.md) — хуку хелпера нужны `EVENT_OBJECT_CLOAKED` и `EVENT_OBJECT_UNCLOAKED`, иначе скрытые через cloak окна не обновятся у клиента
- [helperBuild.md](windows/helperBuild.md) — хелпер одним exe через `+crt-static`; на Маке проверяются rustfmt и clippy под `x86_64-pc-windows-msvc`, а exe линкуется только на Windows
- [appLocker.md](windows/appLocker.md) — правила AppLocker по умолчанию разрешают exe только из `%windir%` и `%programfiles%`: хелпер из папки пользователя не стартует, страница 8.2 должна это объяснять
