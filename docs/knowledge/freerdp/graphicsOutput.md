# FreeRDP: вывод рабочего стола в VibeRDPCore

Сверено по исходникам FreeRDP 3.32.0 и тестам — 2026-09-25, задача 1.2.
Реализация — `core/src/session.c` и `core/src/frame.c`, показ на экране — [macos/metalRendering.md](../macos/metalRendering.md).

## Формат пикселей: BGRX32, а не XRGB32

**Суть:**
- 32-битный цвет FreeRDP пишет в память старшим байтом вперёд (`FreeRDPWriteColor_int`, `libfreerdp/codec/color.h:44-48`): первая буква имени формата — первый байт в памяти
- `PIXEL_FORMAT_XRGB32` из `client/Sample` кладёт байты X, R, G, B, а IOSurface формата `'BGRA'` и `MTLPixelFormatBGRA8Unorm` ждут B, G, R, A — каналы съезжают на байт
- `PIXEL_FORMAT_BGRX32` кладёт B, G, R, X — ровно порядок IOSurface и Metal; четвёртый байт ничего не несёт

**Применение:**
- Ядро поднимает GDI через `gdi_init_ex(instance, PIXEL_FORMAT_BGRX32, <шаг строки>, <память поверхности>, NULL)`: движок рисует прямо в IOSurface, приложение показывает её без копии
- Функции освобождения нет: памятью владеет поверхность, а `gdi_free` её не трогает
- Живой тест клиента сверяет цвет записанного рабочего стола после всего пути — от декодера до Metal: [sampleServer.md](sampleServer.md)

## Кто и под какой блокировкой рисует

**Суть:**
- Без графического конвейера обновления приходят fastpath-пакетами и рисуются в потоке сессии: каждое оборачивается в `update_begin_paint` и `update_end_paint` (`libfreerdp/core/fastpath.c:346-357`)
- С RDPGFX пакеты разбирает поток канала drdynvc (`drdynvc_virtual_channel_client_thread`, `channels/drdynvc/client/drdynvc_main.c:1823-1861`), и конец кадра выводит поверхности в GDI там же (`gdi_OutputUpdate`, `libfreerdp/gdi/gfx.c:214-244`)
- `update_begin_paint` берёт блокировку обновлений до колбэка `BeginPaint`, `update_end_paint` отпускает её после `EndPaint` (`libfreerdp/core/update.c:3631-3678`): отрисовки из двух потоков не пересекаются

**Применение:**
- `beginPaint` блокирует IOSurface на запись процессором, `endPaint` отпускает её и отдаёт изменённый прямоугольник колбэком `frameUpdated`
- Поэтому `frameUpdated` приходит и из потока сессии, и из потока канала — так и записано в заголовке API; колбэк клиента только кладёт событие в очередь

## Смена размера рабочего стола

**Суть:**
- `DesktopResize` зовут два места: повторная активация с новым размером — в потоке сессии (`libfreerdp/core/connection.c:2262-2280`) — и сброс графики RDPGFX — в потоке канала, под `context->mux` конвейера (`libfreerdp/gdi/gfx.c:113-129`)
- Отрисовка RDPGFX берёт тот же `context->mux` раньше блокировки обновлений (`gdi_UpdateSurfaces`, `gfx.c:269`): порядок блокировок в обоих путях один, взаимной блокировки нет

**Применение:**
- `desktopResize` создаёт новую поверхность и под `rdp_update_lock` вызывает `gdi_resize_ex` с её памятью: ни одна отрисовка не видит замену наполовину
- Старая поверхность освобождается ядром, но у приложения остаётся своя ссылка из `VRCSessionCopyFrameSurface`, пока оно не возьмёт новую по `frameResized`
- `frameResized` приходит один раз до `Connected` и затем при каждой смене размера сервером

## Кодеки: конвейер и RemoteFX включаются явно

**Суть:**
- В настройках клиента `SupportGraphicsPipeline` по умолчанию выключен — его значение равно `ServerMode` (`libfreerdp/core/settings.c:1339-1347`), а `RemoteFxCodec` не включает никто, кроме разбора командной строки (`client/common/cmdline.c`); ядро этот разбор не использует
- Сервер может отказать клиенту без кодека: sample-сервер FreeRDP рисует только RemoteFX или NSCodec (`server/Sample/sfreerdp.c:249-251`)
- H.264 (AVC420 и AVC444) идёт только внутри RDPGFX и требует декодера: VibeRDP добавляет во FreeRDP свой, на VideoToolbox — [h264.md](h264.md), решение 24 в [decisions.md](../../decisions.md)
- `GfxH264` по умолчанию выключен (`libfreerdp/core/settings.c:1234`), и тогда клиент ставит в возможностях RDPGFX флаг `RDPGFX_CAPS_FLAG_AVC_DISABLED` (`channels/rdpgfx/client/rdpgfx_main.c:377-389`): сервер не шлёт кадров H.264; ядро включает `GfxH264` и `GfxAVC444`

**Применение:** `applyGraphics` в ядре включает оба: RDPGFX несёт современные кодеки, RemoteFX — для серверов без конвейера.

## Ошибка разбора поверхностной команды не рвёт сессию

**Суть:**
- `update_recv_surfcmds` возвращает `FALSE` на неизвестном типе команды (`libfreerdp/core/surface.c:224-269`, сообщение — строка 254)
- Вызов в `fastpath_recv_update` проверяет результат как число: `rc = (status >= 0)` над значением `BOOL`, а `FALSE` — это ноль (`libfreerdp/core/fastpath.c:412-414`)
- Итог: пакет с испорченной поверхностной командой пишет в журнал `unknown cmdType` и пропускается, сессия идёт дальше

**Применение:** поток ошибок `unknown cmdType` в журнале движка — повод смотреть на сервер, а не на обрыв связи; так и нашёлся дефект записи у sample-сервера — [sampleServer.md](sampleServer.md).

**Источники:**
- `core/third_party/FreeRDP/libfreerdp/codec/color.h`, `include/freerdp/codec/color.h:76-80`, `include/freerdp/gdi/gdi.h:545-552`
- `core/third_party/FreeRDP/libfreerdp/core/fastpath.c`, `update.c`, `surface.c`, `connection.c`, `settings.c`
- `core/third_party/FreeRDP/libfreerdp/gdi/gfx.c`, `channels/drdynvc/client/drdynvc_main.c`
- `core/tests/frameTests.c`, `client-macos/Tests/LiveServerTests.swift`
