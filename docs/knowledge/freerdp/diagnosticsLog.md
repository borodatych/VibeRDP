# FreeRDP: журнал WLog в файл

Сверено по исходникам WinPR из FreeRDP 3.32.0 — 2026-09-26, журнал диагностики (решение 34).
Реализация — `core/src/log.c` (`VRCLogToFile`, `VRCLog`), `client-macos/App/Diagnostics.swift`; тесты — `core/tests/logTests.c`, `client-macos/Tests/DiagnosticsTests.swift`.

## Файл вместо консоли

**Суть:**
- Корневой логгер переводится в файл `WLog_SetLogAppenderType(WLog_GetRoot(), WLOG_APPENDER_FILE)`, затем `WLog_ConfigureAppender` с ключами `outputfilepath` — папка — и `outputfilename` — имя, затем `WLog_OpenAppender` (`winpr/include/winpr/wlog.h:362-374`, `winpr/libwinpr/utils/wlog/FileAppender.c:181-184`)
- Уровень — `WLog_SetLogLevel` у корня; дочерние логгеры с тегами движка и свои теги приложения его наследуют
- Файл дописывается, а не перезаписывается; строки всех потоков идут через один приёмник корня, так что порядок сохраняется
- Консольный приёмник по умолчанию пишет TRACE, DEBUG и INFO в stdout, а WARN и выше — в stderr (`ConsoleAppender.c:109-129`): у приложения, запущенного из Finder, оба потока уходят в никуда, и журнал движка терялся целиком

**Применение:**
- Приложение открывает журнал при старте, до первой сессии: одно открытие на процесс, поэтому включение и выключение журнала действуют со следующего запуска
- Строки приложения идут через тот же WLog под тегами `com.vibebrains.viberdp.<категория>` — в файле они стоят среди строк движка по времени, и обрыв виден рядом с тем, что ему предшествовало
- Ядро пишет свои строки буфера обмена напрямую через `WLog_INFO` с тегом `com.vibebrains.viberdp.clipboard`: только форматы, размеры и порядок сообщений, без данных
- Процесс, внутри которого XCTest гоняет тесты приложения, журнал не открывает — [xcodeClient.md](../macos/xcodeClient.md)

**Источники:**
- `core/third_party/FreeRDP/winpr/include/winpr/wlog.h`, `winpr/libwinpr/utils/wlog/FileAppender.c`, `ConsoleAppender.c`
