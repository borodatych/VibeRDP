# СРЕДА РАЗРАБОТКИ И СБОРКА

Что поставить, как собрать зависимости, ядро `VibeRDPCore`, клиент для macOS и хелпер и чем проверить результат.
Параметры сборки — в [`build.env`](../../build.env), обоснования и грабли — в [knowledge/freerdp/buildMacOS.md](../knowledge/freerdp/buildMacOS.md), [knowledge/freerdp/clientLifecycle.md](../knowledge/freerdp/clientLifecycle.md) и [knowledge/macos/xcodeClient.md](../knowledge/macos/xcodeClient.md).

---

## 1. Что нужно

- **Mac** на Apple Silicon или Intel
- **Xcode 27** — проверено на 27.0; CI собирает на Xcode 26.6 — если `xcode-select -p` указывает на CommandLineTools, задайте в окружении сборки `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- **CMake** не ниже 3.24 — скрипты пользуются `--fresh` и `CMAKE_IGNORE_PREFIX_PATH`; проверено на 4.4.3
- **ninja** — нужен для теста ядра на Swift: CMake собирает Swift только генераторами Ninja и Xcode; без ninja скрипты берут make, и Swift-тест пропускается
- **XcodeGen** ровно той версии, что в `build.env` (`XCODEGEN_VERSION`) — `xcodegen.zip` из релиза на github.com/yonaskolb/XcodeGen, sha256 архива сверьте с `XCODEGEN_SHA256`; другую версию скрипт клиента не примет
- **perl, make, curl, shasum, tar, lipo, otool, nm, strings, ditto, plutil, rsync, patch, lsof** — есть в macOS и Xcode
- **pkg-config** — через него FreeRDP находит собранную MIT Kerberos: `brew install pkgconf`; в образе CI — pkgconf 3.0.7
- **python3** — скрипт ядра ищет им свободные порты для тестового Kerberos, скрипт клиента проверяет строки интерфейса; есть в Command Line Tools
- **Rosetta** — по желанию: без неё код x86_64 только собирается и линкуется, а не запускается
- **shellcheck** и **actionlint** — для проверки скриптов и workflow; в CI — shellcheck 0.11.0 и actionlint 1.7.12
- **Rust** через rustup — для хелпера; тулчейн скрипты берут из `helper-win/rust-toolchain.toml`

---

## 2. Исходники

FreeRDP подключён подмодулем `core/third_party/FreeRDP` с `shallow = true`: история апстрима не скачивается.

Новый клон:

```bash
git clone --recurse-submodules <адрес репозитория>
```

Уже склонированный репозиторий:

```bash
git submodule update --init
```

---

## 3. Зависимости: OpenSSL, MIT Kerberos и FreeRDP

```bash
VIBERDP_CACHE_DIR=<папка кэша> core/scripts/build-freerdp.sh
```

- `VIBERDP_CACHE_DIR` — куда класть скачанное, деревья сборки и результат; по умолчанию `core/build/`, она в `.gitignore`
- `CMAKE` — путь к cmake, если его нет в `PATH`; ctest берётся из той же папки
- Полная сборка с нуля — около двух с половиной минут на Apple M4 (10 ядер) и около 630 МБ в папке кэша; повторная — меньше минуты: OpenSSL и Kerberos пропускаются по метке, копия FreeRDP обновляется, FreeRDP конфигурируется заново и собирается инкрементально
- Сборка с нуля: удалите в папке кэша `build/`, `stage/`, `prefix/` и `src/` — скачанные архивы останутся в `downloads/`
- Kerberos собирается статически и без своих утилит: только библиотеки для NLA — [knowledge/freerdp/kerberos.md](../knowledge/freerdp/kerberos.md)
- FreeRDP собирается из копии подмодуля в `<папка кэша>/src/freerdp`: поверх копии ложатся файлы `core/freerdp/src`, затем накладываются патчи `core/freerdp/patches` — декодер H.264 на VideoToolbox и исправление FreeRDP; сам подмодуль остаётся как в релизе — [knowledge/freerdp/h264.md](../knowledge/freerdp/h264.md)

---

## 4. Ядро: VibeRDPCore

Тестовые собеседники ядра и клиента — sample-сервер FreeRDP и KDC тестового Kerberos — собираются один раз, после зависимостей из раздела 3; `CMAKE` — как там же:

```bash
VIBERDP_CACHE_DIR=<папка кэша> core/scripts/build-test-server.sh
```

- Сервер собирается из копии исходников подмодуля с патчами `core/scripts/test-server/*.patch`, только под архитектуру этого Mac: это инструмент тестов, в приложение он не попадает
- KDC — общая сборка того же релиза MIT Kerberos с сервером и утилитами базы, тоже под этот Mac; пересобирается, только когда `build.env` назовёт другой релиз
- Каждая сборка делает новый одноразовый сертификат для TLS сервера
- Без собеседников тесты, которым они нужны, пропускаются с причиной, остальные идут как обычно
- Как устроены сервер, запись и живые тесты клиента — [knowledge/freerdp/sampleServer.md](../knowledge/freerdp/sampleServer.md), тестовый Kerberos — [knowledge/freerdp/kerberos.md](../knowledge/freerdp/kerberos.md)

Само ядро:

```bash
VIBERDP_CACHE_DIR=<папка кэша> core/scripts/build-core.sh
```

Скрипт берёт префикс из раздела 3 и делает по порядку:
1. Поднимает тестовых собеседников, если они собраны: Kerberos — область на этот прогон во временной папке, KDC и сервер, который пускает только по Kerberos, на свободных портах loopback; сервер-эхо буфера обмена — на Unix-сокете; журналы — в `<папка кэша>/core-tests/`, при выходе всё останавливается — и при выходе с ошибкой тоже
2. Собирает фреймворк ядра и тесты под архитектуру этого Mac и прогоняет тесты
3. Собирает и прогоняет вариант с AddressSanitizer и UndefinedBehaviorSanitizer
4. Собирает остальные архитектуры из `build.env`
5. Склеивает `<папка кэша>/core/VibeRDPCore.framework` — универсальный фреймворк для приложения — и проверяет, что наружу торчит только API `VRC*`
6. Прогоняет тесты остальных архитектур — через Rosetta, поэтому последними

Тесты ядра подключаются к фейковым серверам на loopback и проверяют жизненный цикл сессии, отмену, уничтожение во время подключения, категории ошибок, поверхность кадра, очередь ввода и кодирование событий мыши, картинку курсора из масок сервера, кэш билетов Kerberos и импорт модуля фреймворка в Swift.
Тесты `h264Tests` кодируют кадры кодером VideoToolbox и декодируют их через API FreeRDP: AVC420, в том числе 1920×1080 с обрезкой, AVC444 v1 и v2, смена размера и испорченные потоки.
Фейковый TLS-сервер (`core/tests/tlsServer.c`) отвечает на согласование X.224, выбирает TLS и предъявляет самоподписанный сертификат, созданный при старте теста: на нём проверяются вопрос о сертификате, отказ, согласие и отмена во время вопроса.
Тесты `kerberosLogonTests` входят через NLA на Kerberos-сервер тестовой области: имя в виде `user@REALM` и `realm\user`, неверный пароль и кэш билетов, который уходит вместе с сессией.
Тесты `clipboardTests` гоняют протокол буфера обмена на поддельном канале, `cliptextTests`, `cliphtmlTests`, `clipimageTests` и `clipfilesTests` — преобразования текста, HTML, картинок и списков файлов, а `clipboardEchoTests` отправляют текст, HTML, RTF, картинку и файлы через sample-сервер, который возвращает их.
Живое подключение к Windows проверяет оператор — [liveChecks.md](liveChecks.md).
Заголовок API лежит в `core/include`, модуль и список экспорта фреймворка — в `core/framework`.

---

## 5. Клиент: client-macos

Живые тесты клиента подключаются к sample-серверу FreeRDP из раздела 4: один экземпляр проигрывает запись рабочего стола Windows, другой рисует иконку там, куда пришло событие мыши, третий возвращает текст буфера обмена с приставкой.

Сам клиент:

```bash
VIBERDP_CACHE_DIR=<папка кэша> XCODEGEN=<путь к xcodegen> client-macos/scripts/build-client.sh
```

- `XCODEGEN` — путь к xcodegen, если его нет в `PATH`
- Нужен фреймворк из раздела 4: скрипт встраивает его в приложение

Скрипт делает по порядку:
1. Генерирует `client-macos/VibeRDP.xcodeproj` из `client-macos/project.yml` — версия, минимальная macOS, архитектуры и путь к фреймворку приходят из `build.env` и папки кэша
2. Собирает универсальное `VibeRDP.app` в конфигурации Release
3. Проверяет срезы и минимальную macOS приложения и встроенного фреймворка, ссылку на фреймворк и подпись
4. Прогоняет тесты внутри запущенного приложения — на этом Mac, затем остальные архитектуры через Rosetta; падает, если тестов ноль или какой-то не прошёл и не пропущен с причиной
   Перед каждым прогоном скрипт запускает три тестовых сервера, если они собраны, и останавливает их после — и при выходе с ошибкой тоже
   У каждого теста предел в минуту: повисший падает один, а остальные идут дальше

Серверы запускает скрипт, а не тест внутри приложения: иначе macOS после каждой пересборки спрашивает, можно ли приложению читать съёмный том, где может лежать кэш, и держит запуск до ответа — [knowledge/macos/removableVolumePrivacy.md](../knowledge/macos/removableVolumePrivacy.md).

Проект генерируется при каждой сборке и в git не хранится.
Открыть его в Xcode можно после первого прогона скрипта; правки проекта вносятся в `project.yml`, а не в Xcode.

---

## 6. Хелпер: helper-win

Тулчейн закреплён в `helper-win/rust-toolchain.toml` (Rust 1.97.1 с таргетом `x86_64-pc-windows-msvc`); сборочный кэш — через `CARGO_TARGET_DIR`.

```bash
cd helper-win && cargo fmt --check && cargo clippy -- -D warnings && cargo clippy --target x86_64-pc-windows-msvc -- -D warnings
```

- clippy под Windows-таргет проверяет код так, как его увидит Windows, и не требует линкера
- Сам exe линкуется только на Windows — `link.exe` есть лишь там; на Маке `cargo build --target x86_64-pc-windows-msvc` падает, так и должно быть
- На Windows с Visual Studio C++ build tools:
  ```powershell
  cargo build --locked --release --target x86_64-pc-windows-msvc
  ```
  ```powershell
  ./scripts/check-exe.ps1 target/x86_64-pc-windows-msvc/release/vibe-seam-helper.exe
  ```
  Проверка требует x64, GUI-подсистему (без окна консоли) и отсутствие DLL C-рантайма

---

## 7. Что получается

```
<папка кэша>/
├── downloads/      # архивы OpenSSL и MIT Kerberos
├── src/            # распакованные OpenSSL и MIT Kerberos, freerdp/ — копия FreeRDP с дополнениями VibeRDP
├── build/          # деревья сборки: openssl-*, krb5-*, freerdp-*, core-* и проверка линковки
├── stage/          # установки через DESTDIR: внутри лежит зашитый префикс opt/viberdp
├── prefix/
│   ├── arm64/      # полная установка зависимостей под одну архитектуру
│   ├── x86_64/
│   └── universal/  # зависимости для ядра: заголовки, пакеты CMake, универсальные библиотеки и объекты каналов
├── core/
│   └── VibeRDPCore.framework   # универсальный фреймворк ядра
├── test-server/    # тестовые собеседники: src/ — копия FreeRDP с патчами, build/, kdc/ — тестовый KDC, server.crt и server.key
├── core-tests/     # журналы тестового KDC и Kerberos-сервера последнего прогона ядра
└── client/
    ├── DerivedData/  # сборка Xcode: Build/Products/Release/VibeRDP.app
    └── results/      # результаты тестов по архитектурам (.xcresult) и журналы тестовых серверов
```

Подключение FreeRDP из CMake:
- `CMAKE_PREFIX_PATH=<папка кэша>/prefix/universal`
- `find_package(FreeRDP-Client 3 CONFIG REQUIRED)` и цель `freerdp-client`
- Для прямых вызовов OpenSSL — `find_package(OpenSSL CONFIG REQUIRED)` и цель `OpenSSL::Crypto`
- Для прямых вызовов Kerberos — заголовок `krb5/krb5.h` из `include/` префикса: пакета CMake у неё нет, ядро находит его `find_path`, а библиотеки приходят с целью `freerdp-client`

Через pkg-config подключать нельзя: файлы FreeRDP не перечисляют фреймворки Apple.
Префикс ссылается на фреймворки SDK той машины, где шла сборка, поэтому собирается он там же, где используется.

---

## 8. Что проверяют скрипты

- sha256 архивов OpenSSL и MIT Kerberos совпадают с `build.env`
- Приватные библиотеки в `mit-krb5.pc` — ровно `-lkrb5support`, как в выпуске, для которого скрипт дописывает системные; другой набор роняет сборку
- У всех архитектур одинаковый набор объектов и одинаковые заголовки
- В каждой библиотеке, объекте, фреймворке и в приложении есть все срезы, записана минимальная macOS из `build.env` и нет слабых ссылок — то есть API новее этой macOS; служебные слабые ссылки тулчейна перечислены в `TOOLCHAIN_WEAK_SYMBOLS` (`core/scripts/common.sh`)
- В бинари зависимостей не попал ни один путь установки сборочной машины
- `core/scripts/link-check` собирается через пакеты CMake как универсальный бинарь и на запуске проверяет версии, пути под `RUNTIME_PREFIX` и встроенные каналы
- Фреймворк ядра экспортирует только `_VRC*` и несёт модуль для Swift
- Тесты ядра — на каждой архитектуре, которую Mac умеет исполнять, и отдельно под санитайзерами
- Приложение ссылается на фреймворк через `@rpath`, находит его в `Contents/Frameworks` и проходит `codesign --verify --deep --strict`
- xcodegen — ровно версии из `build.env`; тесты приложения — на каждой архитектуре, с подсчётом по xcresult и пределом в минуту на каждый тест
- Патчи FreeRDP (`core/freerdp/patches`) и тестового сервера накладываются на подмодуль: не наложился — сборка падает с именем патча

Любая проверка падает с сообщением `error:` и ненулевым кодом выхода.

---

## 9. CI

`.github/workflows/ci.yml` на каждый push в `main` и `next` и на pull request:
- **macOS** (`macos-26`) — скачивает XcodeGen из `build.env` со сверкой sha256 и прогоняет разделы 3, 4 и 5 вместе с тестовыми собеседниками; приложение уходит артефактом `VibeRDP-app`, а результаты упавшего прогона с журналами ядра и клиента — артефактом `client-test-results`
- **Windows** (`windows-2025`) — rustfmt, clippy, сборка exe хелпера и его проверка из раздела 6; exe уходит артефактом `vibe-seam-helper`
- **Линт** (`ubuntu-24.04`) — shellcheck и actionlint закреплённых версий со сверкой sha256

Локально workflow проверяется так:

```bash
actionlint -color
```

---

## 10. Если что-то зависло

- **Запуск кода x86_64 оборвался по таймауту** — Rosetta перестала переводить новые программы; сперва проверьте её пробной программой с таймаутом: бывает, что отпускает само; нет — `sudo launchctl kickstart -k system/com.apple.oahd`, не помогло — перезагрузка; подробности в [knowledge/macos/toolingHangs.md](../knowledge/macos/toolingHangs.md)
- **Тест под санитайзером упал с адресами вместо имён** — так задумано, `atos` не подключается к процессу; имена даёт офлайн `xcrun atos -o <бинарь> -arch arm64 -l 0x100000000 <адреса>`
- **Тест клиента упал с «exceeded execution time allowance»** — он повис и снят через минуту; причину ищите в архиве системного журнала из результатов: `xcrun xcresulttool export diagnostics --path <бандл> --output-path <папка>`, затем `/usr/bin/log show <архив>` — именно с полным путём, в zsh `log` встроенная команда; разбор такого случая — [knowledge/macos/removableVolumePrivacy.md](../knowledge/macos/removableVolumePrivacy.md)

---

## 11. Обновить FreeRDP

```bash
git -C core/third_party/FreeRDP fetch --depth 1 origin tag <версия>
```

```bash
git -C core/third_party/FreeRDP checkout <версия>
```

Подпись тега смотрится через GitHub: `object.sha` тега берётся из `gh api repos/FreeRDP/FreeRDP/git/ref/tags/<версия>`, затем:

```bash
gh api repos/FreeRDP/FreeRDP/git/tags/<sha объекта тега> --jq .verification
```

Нужны `verified: true` и `reason: valid`.
Дальше — обе сборки скриптами, запись в базе знаний о том, что изменилось в опциях, и коммит нового указателя подмодуля.

---

## 12. Обновить OpenSSL

1. Скачать `openssl-<версия>.tar.gz` и `openssl-<версия>.tar.gz.asc` из релиза на github.com/openssl/openssl и `pubkeys.asc` с https://openssl-library.org/source/
2. Проверить подпись в отдельной связке ключей, не трогая свою:
   ```bash
   export GNUPGHOME="$(mktemp -d)"; gpg --import pubkeys.asc && gpg --verify openssl-<версия>.tar.gz.asc openssl-<версия>.tar.gz
   ```
3. Сверить основной отпечаток ключа из вывода с опубликованным на https://openssl-library.org/source/
4. Записать в `build.env` новые `OPENSSL_VERSION` и `OPENSSL_SHA256` (`shasum -a 256` архива)
5. Собрать скриптами: метка сборки изменится, и OpenSSL пересоберётся сам

---

## 13. Обновить XcodeGen

1. Взять дайджест `xcodegen.zip` нового релиза:
   ```bash
   gh api repos/yonaskolb/XcodeGen/releases/tags/<версия> --jq '.assets[] | .name + " " + .digest'
   ```
2. Записать в `build.env` новые `XCODEGEN_VERSION` и `XCODEGEN_SHA256`
3. Поставить эту версию локально и прогнать раздел 5; CI скачает её сам
