# FreeRDP: мышь и курсор в VibeRDPCore

Сверено по исходникам FreeRDP 3.32.0 и тестам — 2026-09-25, задача 1.3.
Реализация — `core/src/input.c`, `core/src/pointer.c` и `core/src/session.c`, сторона macOS — [macos/mouseInput.md](../macos/mouseInput.md).

## Когда ввод можно отправлять

**Суть:**
- `freerdp_connect` возвращается, как только клиент дошёл до финализации: `rdp_client_wait_for_activation` ждёт `rdp_is_active_state`, а он истинен уже с `CONNECTION_STATE_FINALIZATION_SYNC` (`libfreerdp/core/connection.c:239-289`, `1995-2008`); `CONNECTION_STATE_ACTIVE` наступает позже, в цикле событий
- Общий помощник клиента `freerdp_client_send_wheel_event` вне ACTIVE молча выбрасывает событие (`client/common/client.c:1812-1814`)
- После начала разрыва любая функция ввода пишет `[APPLICATION BUG] input functions called after the session terminated` и возвращает FALSE (`libfreerdp/core/input.c:133-142`)
- Запись в транспорт идёт под `WriteLock` (`libfreerdp/core/transport.c:1225-1319`); upstream Mac-клиент шлёт мышь прямо из главного потока (`client/Mac/MRDPView.m`), так что на медленном канале ждёт сети сам интерфейс
- Асинхронной очереди ввода в FreeRDP 3 нет: настройки `AsyncInput` в исходниках больше не найти

**Применение:**
- У ядра своя очередь: главный поток кладёт событие и сразу возвращается, отправляет только поток сессии — её событие WinPR стоит последним в наборе ожидания `runEventLoop`
- До ACTIVE события ждут в очереди в своём порядке, в том числе при повторной активации; подряд идущие перемещения сливаются в одно
- Очередь открывается после `freerdp_connect` и закрывается до `freerdp_disconnect`: ввод до Connected и после конца сессии получает `InvalidState`, а гонки с разрывом нет
- Решение 16 в [decisions.md](../../decisions.md); тесты — `inputTests` и `inputNeedsAConnection`

## Кодирование событий

**Суть:**
- Колесо — `PTR_FLAGS_WHEEL` или `PTR_FLAGS_HWHEEL` и 9-битное число со знаком в `WheelRotationMask` (0x01FF), знаковый бит — `PTR_FLAGS_WHEEL_NEGATIVE` (`include/freerdp/input.h:39-47`): одно событие несёт от −256 до 255 единиц, щелчок колеса — 120
- Горизонтальное колесо FreeRDP отправляет, только если сервер объявил `HasHorizontalWheel`; иначе пропускает его с WARN на каждое событие (`libfreerdp/core/input.c:252-261`)
- Боковые кнопки идут extended mouse event с `PTR_XFLAGS_BUTTON1`, `PTR_XFLAGS_BUTTON2` и `PTR_XFLAGS_DOWN` (`input.h:50-52`), если сервер объявил `HasExtendedMouseEvent`
- Обе возможности клиент объявляет по умолчанию (`libfreerdp/core/settings.c:947-948`), а после обмена возможностями остаются серверные (`libfreerdp/core/capabilities.c:1400-1419`)
- Upstream Mac-клиент умножает `deltaY` события на 120 и режет до 255 (`client/Mac/MRDPView.m:362-409`): точная прокрутка трекпада огрубляется, а быстрая обрезается

**Применение:** ядро делит поворот на шаги до 255 единиц (`vrcWheelFlags`) и само проверяет возможности сервера перед горизонтальным колесом и боковыми кнопками: неподдержанное событие не отправляется и не засоряет журнал.

## Курсор сервера

**Суть:**
- Курсоры приходят fastpath-пакетами в поток сессии; кэш FreeRDP выделяет объект размером прототипа через `calloc` и копирует прототип поверх начала (`libfreerdp/core/graphics.c:86-100`): добавочные поля своего типа приходят обнулёнными
- Неудача `Pointer_New` роняет весь пакет обновления (`libfreerdp/cache/pointer.c:186-256`)
- `freerdp_image_copy_from_pointer_data` рисует маски XOR и AND любой глубины и оставляет альфу прямой, не предумноженной; 1-битные строки идут сверху вниз с выравниванием на два байта, остальные — снизу вверх (`libfreerdp/codec/color.c:533-760`)
- Пиксели, которые в Windows инвертируют экран, FreeRDP рисует шахматкой из чёрного и белого (`color.c:353-366`)
- 8-битному курсору нужна палитра сессии, без неё FreeRDP пишет ERR и отказывает (`color.c:646-651`); upstream Mac-клиент передаёт NULL
- Просьбу сервера передвинуть курсор (`Pointer_SetPosition`) upstream Mac-клиент тоже не выполняет

**Применение:**
- Ядро регистрирует свой `rdpPointer` после `gdi_init_ex`, переводит картинку один раз в `pointerNew` — BGRA с прямой альфой — и отдаёт её колбэком `pointerChanged` при каждом `Set`
- `pointerNew` всегда успешен: не переведённая картинка даёт системную стрелку, пустой курсор — скрытый
- Палитра берётся из `rdpGdi.palette`; просьбу передвинуть курсор ядро принимает и отбрасывает
- Тесты `pointerTests`: монохромный курсор с четырьмя видами пикселей и 32-битный с полупрозрачным пикселем и переворотом строк
- Sample-сервер курсоров не шлёт: живой проверки нет, она у оператора — [liveChecks.md](../../manuals/liveChecks.md), раздел 3

**Источники:**
- `core/third_party/FreeRDP/include/freerdp/input.h`, `libfreerdp/core/input.c`, `connection.c`, `capabilities.c`, `settings.c`, `transport.c`
- `core/third_party/FreeRDP/libfreerdp/core/graphics.c`, `libfreerdp/cache/pointer.c`, `libfreerdp/codec/color.c`
- `core/third_party/FreeRDP/client/common/client.c`, `client/Mac/MRDPView.m`
- `core/tests/inputTests.c`, `core/tests/pointerTests.c`, `core/tests/sessionTests.c`
