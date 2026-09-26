# КОПИЯ ПРИЛОЖЕНИЯ, СОБРАННАЯ НА ЛЕТУ

## 1. Подпись

Подпись бандла запечатывает его `Info.plist`: копия шаблона с новым идентификатором и именем уже не проходит `codesign --verify`
Копия подписывается заново ad hoc: `codesign --force --sign - --timestamp=none <бандл>` — утилита есть в любой macOS, Xcode не нужен
Копия без атрибута карантина запускается без вопросов Gatekeeper: она сделана на этом Маке, а не скачана

## 2. Запуск

`NSWorkspace.openApplication` с `createsNewApplicationInstance` и `activates = false`: копия встаёт в Dock, но не забирает фокус
Аргументы доходят до копии через `OpenConfiguration.arguments`; процесс родителя копия ждёт `DispatchSource.makeProcessSource(.exit)`
Проверено вживую 26.09.2026: копия из `SharedSupport` собранного приложения запускается и выходит вместе с родителем
Ответ `openApplication` приходит в очереди LaunchServices, не в главном потоке: `MainActor.assumeIsolated` в нём останавливает приложение — переход в главный поток через `Task { @MainActor … }`
«Запущено» приходит раньше, чем копия выполнит `applicationDidFinishLaunching`: распределённое уведомление «завершись», посланное сразу, теряется; завершать копию надёжнее `NSRunningApplication(processIdentifier:)?.terminate()`

## 3. Связь

Распределённые уведомления с `deliverImmediately: true` доходят до фонового процесса сразу; объект — строка, у нас идентификатор бандла копии
Любой процесс того же пользователя может отправить такое уведомление: худшее, что он сделает, — поднимет или закроет окна Windows этого пользователя

Код — `client-macos/App/DockProxies.swift`, `client-macos/Proxy/main.swift`, решение 50
