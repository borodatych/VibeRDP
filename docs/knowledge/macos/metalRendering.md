# macOS: рабочий стол через Metal без своих шейдеров

Проверено 2026-09-25 на Xcode 27.0 и macOS 26.6.2, Apple M4, задача 1.2.
Реализация — `client-macos/Session/FrameRenderer.swift`, `DesktopView.swift`, `FrameGeometry.swift`; решение — раздел 15 [decisions.md](../../decisions.md).

## Обходимся без Metal Toolchain

**Суть:**
- В Xcode 27 компилятор шейдеров Metal — отдельный скачиваемый компонент: без него `xcrun metal` отвечает `missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain`, а проект с файлами `.metal` не собрать
- Вывод рабочего стола укладывается в готовые операции: копия blit-энкодером при равных размерах и ядро `MPSImageBilinearScale` из Metal Performance Shaders для масштаба
- Поля по краям закрашивает проход рендера без единого вызова отрисовки: его `loadAction = .clear` сам заливает цель чёрным

**Применение:** своих шейдеров в клиенте нет, компонент Metal Toolchain для сборки не нужен; он понадобится, только когда появится свой `.metal`.

## Текстура поверх IOSurface и drawable слоя

**Суть:**
- `makeTexture(descriptor:iosurface:plane:)` даёт текстуру прямо на памяти поверхности движка: GPU читает то, что пишет движок, без копии
- Текстура поверхности — `storageMode = .managed`: _по коду рассчитано и на дискретные GPU Intel-Маков, на них не проверено_
- Drawable слоя `CAMetalLayer` с `framebufferOnly = true` годится только как цель рендера; `false` разрешает в него копировать и писать из вычислительного ядра (`QuartzCore.framework/Headers/CAMetalLayer.h:79-87`) — а ядро MPS и blit пишут именно так
- Чтобы прочитать `.managed`-текстуру процессором после работы GPU, нужен `synchronize(resource:)` в том же буфере команд — так тесты читают пиксели назад

**Применение:** `DesktopView` ставит слою `framebufferOnly = false`, формат `bgra8Unorm` и цветовое пространство sRGB: пиксели сервера — sRGB, а слой без метки показывался бы в пространстве дисплея, на широком охвате — слишком насыщенно.

## Семантика clipRect у MPSImageBilinearScale

**Суть:**
- С заданным `clipRect` ядро кладёт изображение от начала этого прямоугольника: сдвиг задаётся клипом, а в `MPSScaleTransform` он остаётся нулевым
- Пиксели назначения вне `clipRect` ядро не трогает: там остаётся чёрный от прохода очистки
- Копия blit-энкодером требует одинаковых размеров: назначение даже на пиксель больше уже масштабируется, иначе копия недопустима

**Применение:** `FrameRenderer.encode` копирует при равных размерах, а иначе очищает цель и масштабирует в клип `FrameGeometry.fit`; `FrameRendererTests` сверяет пиксели квадрантов, чёрные поля по бокам и назначение, выше источника на один пиксель.

## Поддержка устройства и перерисовка

**Суть:**
- `MPSSupportsMTLDevice` отвечает, работает ли Metal Performance Shaders с устройством (`MetalPerformanceShaders.framework/Headers/MetalPerformanceShaders.h:26-34`)
- Виртуальная GPU раннера GitHub `macos-26` MPS поддерживает: там тесты рендера не пропускаются — [ci/githubActions.md](../ci/githubActions.md); про другие виртуальные машины _не проверено_
- **Вид, чей слой — `CAMetalLayer` из `makeBackingLayer`, AppKit сам не рисует:** `needsDisplay` не доводит его до `updateLayer`, даже с `wantsUpdateLayer = true` и `layerContentsRedrawPolicy = .onSetNeedsDisplay`; в задаче 1.2 так считалось, и тест это «подтверждал», потому что звал отрисовку напрямую, а на настоящем Windows окно сессии осталось пустым при идущих кадрах (живая проверка владельца, 2026-09-25, решение 33)
- Рисовать такой слой должен сам вид — по своему таймеру экрана: `NSView.displayLink(target:selector:)` (macOS 14) даёт `CADisplayLink`, который следует за экраном окна, зовёт на главном потоке и ставится на паузу через `isPaused`
- Ссылку экрана создают, когда вид попал в окно (`viewDidMoveToWindow`), и снимают, когда ушёл: она держит вид

**Применение:**
- `FrameRenderer` возвращает `nil` без GPU или без поддержки MPS: приложение пишет «нет доступа к Metal», тесты рендера пропускаются с причиной
- `DesktopView.frameChanged` ставит флаг и снимает ссылку экрана с паузы; шаг ссылки рисует один кадр и засыпает, если нового изменения нет: поток кадров стоит одной отрисовки за обновление экрана, неподвижный стол — ни одной
- `DesktopViewTests.testChangedFramesReachTheScreen` считает кадры, выведенные на экран через ссылку экрана, а не вызов отрисовки напрямую — так дефект 1.2 ловится тестом

## Полноэкранный режим

**Суть:**
- Пункту меню с действием `toggleFullScreen(_:)` AppKit сам назначает системное сочетание — fn-F — и заменяет любое заданное: _наблюдение задачи 1.2, автоматическим тестом не закреплено_
- `collectionBehavior` с `.fullScreenPrimary` явно разрешает окну свой полноэкранный стол

**Применение:** пункт «Во весь экран» в меню «Окно» создаётся без сочетания, тест проверяет только его наличие и поведение окна.

**Источники:**
- `QuartzCore.framework/Headers/CAMetalLayer.h`, `Metal.framework/Headers/MTLDevice.h:709-717`, `MetalPerformanceShaders.framework/Headers/MetalPerformanceShaders.h` из SDK macOS 27.0
- `client-macos/Tests/FrameRendererTests.swift`, `FrameGeometryTests.swift`, `LiveServerTests.swift`, `MainWindowTests.swift`, `DesktopViewTests.swift`
- `AppKit.framework/Headers/NSView.h:662` — `displayLinkWithTarget:selector:`, SDK macOS 27.0
