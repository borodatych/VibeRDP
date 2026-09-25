# macOS: фреймворк ядра и сборка клиента

Проверено 2026-09-24 сборкой на Xcode 27.0, CMake 4.4.3 и XcodeGen 2.46.0, предел на тест — 2026-09-25.
Сборка — `core/scripts/build-core.sh` и `client-macos/scripts/build-client.sh`, решение о фреймворке — [decisions.md](../../decisions.md), раздел 11.

## CMake не ставит ссылку Modules в корень фреймворка

**Суть:**
- `MACOSX_PACKAGE_LOCATION Modules` кладёт `module.modulemap` в `Versions/A/Modules`, а ссылки в корень бандла CMake делает только для `Headers`, `Resources` и самого бинаря
- Компиляторы ищут модуль фреймворка по пути `<имя>.framework/Modules/module.modulemap`: без ссылки Swift пишет `no such module 'VibeRDPCore'`
- С генератором Ninja компиляция потребителя ждёт объектов библиотеки, но не её линковки и не шагов после неё: в `build.ninja` стоит `cmake_object_order_depends_target_VibeRDPCore`, а не сам фреймворк
- Служебную цель (`add_custom_target`) компиляция потребителя ждёт целиком: строка превращается в `|| VibeRDPCoreModules cmake_object_order_depends_target_VibeRDPCore`

**Применение:** ссылку `Modules` создаёт цель `VibeRDPCoreModules` после сборки фреймворка, Swift-тест зависит от неё явно; `build-core.sh` падает, если в склеенном фреймворке нет модуля.

## Экспорт только API и что тянет фреймворк

**Суть:**
- `-exported_symbols_list` понимает шаблоны: файл из одной строки `_VRC*` оставляет в таблице экспорта ровно четыре функции API
- С `-dead_strip` линковщик выбрасывает неиспользуемый код FreeRDP и OpenSSL: универсальный бинарь фреймворка — 14 МБ при 32 МБ исходных архивов
- Фреймворк сам грузит Carbon, IOKit, Foundation и CoreFoundation — их списки пакеты CMake FreeRDP передали линковке, приложению перечислять их не нужно

**Применение:** `build-core.sh` сверяет экспорт каждого среза с `_VRC*`; новый публичный символ ядра должен начинаться с `VRC`.

## Слабые ссылки, которые ставит тулчейн

**Суть:**
- В бинаре на Swift есть слабые ссылки `__swift_FORCE_LOAD_$_<оверлей>`: это метки автолинковки оверлеев Swift, а динамические библиотеки оверлеев подключены как `LC_LOAD_WEAK_DYLIB`
- Жёстко приложение на Swift 6 грузит только `libswiftCore` и `libswift_Concurrency` из `/usr/lib/swift` — обе есть в macOS 14
- В срезе x86_64 есть слабая ссылка на `___chkstk_darwin` — пробу стека; рядом лежит её приватная копия из compiler-rt (`non-external (was a private external) ___chkstk_darwin`), так что без системной функции код не падает
- Ни то ни другое не вызов API новее минимальной macOS, а проверка по `nm -m` видит их как `(undefined) weak external`

**Применение:** `check_binary` в `core/scripts/common.sh` пропускает именно эти символы — список `TOOLCHAIN_WEAK_SYMBOLS`; любая другая слабая ссылка роняет сборку.

## XcodeGen и xcodebuild

**Суть:**
- XcodeGen подставляет в спеку переменные окружения вида `${VERSION}`: версия, минимальная macOS, архитектуры и путь к фреймворку приходят из `build.env` через `build-client.sh`, и в `project.yml` нет ни одного пути машины
- Сгенерированный проект содержит абсолютный путь к фреймворку ядра — поэтому он в `.gitignore` и генерируется заново при каждой сборке
- Без `-destination` сборка печатает предупреждение о нескольких подходящих назначениях: на Apple Silicon это «My Mac» arm64 и x86_64; сборка приложения идёт с `generic/platform=macOS`
- `-destination "platform=macOS,arch=x86_64"` гоняет тесты внутри приложения под Rosetta
- С `-quiet` xcodebuild не печатает, сколько тестов прошло; число даёт `xcrun xcresulttool get test-results summary --path <бандл>` — JSON с `totalTestCount`, `passedTests` и `skippedTests`, его читает `plutil -extract … raw`
- Тестовый бандл линкует фреймворк ядра без встраивания: внутри приложения он получает копию из `Contents/Frameworks`, и тест `CoreFrameworkTests` это проверяет

**Применение:** `build-client.sh` падает, если тестов ноль или какой-то не прошёл и не пропущен с причиной — например, без GPU; тесты чужой архитектуры идут последними и с таймаутом, как у ядра.

## Предел на каждый тест

**Суть:**
- `-test-timeouts-enabled YES` с `-default-test-execution-time-allowance` и `-maximum-test-execution-time-allowance` дают каждому тесту свой предел; XCTest считает его в целых минутах
- Проверено тестом, который спит 600 с, при пределе 60: через минуту он падает с `Test exceeded execution time allowance of 1 minute`, раннер перезапускается, следующий тест проходит, а xcresult финализирован
- К такому провалу прикладывается спиндамп, но локально в нём только `No samples`: стеков он не даёт
- Без предела повисший тест держит xcodebuild, пока его не убьют снаружи; такой бандл не финализирован — ни сводки, ни архива системного журнала, только журналы в `Staging`
- Процесс теста при снятии убивается: `tearDown` не выполняется, и всё, что тест запустил сам, остаётся жить сиротой

**Применение:**
- `build-client.sh` передаёт предел `TEST_TIME_ALLOWANCE`, а `FOREIGN_RUN_TIMEOUT` у `run_bounded` остаётся последней страховкой — от зависшей Rosetta
- Внешние процессы для тестов запускает и останавливает сам скрипт, по ловушке `EXIT` — [removableVolumePrivacy.md](removableVolumePrivacy.md)

## grep -q в конвейере под pipefail

**Суть:**
- `otool -l <бинарь> | grep -qF <строка>` под `set -o pipefail` падал без видимой причины, как только бинарь приложения вырос
- `grep -q` выходит на первом совпадении и закрывает канал, `otool` получает SIGPIPE на следующей записи, и pipefail считает весь конвейер упавшим
- До этого та же проверка проходила: _видимо, пока вывод помещался в буфер канала, `otool` успевал дописать до выхода `grep`, — предположение, не проверено_

**Применение:** в скриптах вывод сперва сохраняется в переменную, а ищется через `grep -q … <<<"$вывод"`; конвейер с `grep -q` под pipefail не используется.

**Источники:**
- `core/CMakeLists.txt`, `core/tests/CMakeLists.txt`, `build.ninja` в папке сборки ядра
- `client-macos/scripts/build-client.sh`, функция `check_app`
- `nm -m` и `otool -L` по `VibeRDP.app` из `build-client.sh`
- https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
