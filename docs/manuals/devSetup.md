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
- **perl, make, curl, shasum, tar, lipo, otool, nm, strings, ditto, plutil** — есть в macOS и Xcode
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

## 3. Зависимости: OpenSSL и FreeRDP

```bash
VIBERDP_CACHE_DIR=<папка кэша> core/scripts/build-freerdp.sh
```

- `VIBERDP_CACHE_DIR` — куда класть скачанное, деревья сборки и результат; по умолчанию `core/build/`, она в `.gitignore`
- `CMAKE` — путь к cmake, если его нет в `PATH`; ctest берётся из той же папки
- Полная сборка с нуля — около двух минут на Apple M4 (10 ядер) и около 350 МБ в папке кэша; повторная — меньше минуты: OpenSSL пропускается по метке, FreeRDP конфигурируется заново и собирается инкрементально
- Сборка с нуля: удалите в папке кэша `build/`, `stage/`, `prefix/` и `src/` — скачанный архив останется в `downloads/`

---

## 4. Ядро: VibeRDPCore

```bash
VIBERDP_CACHE_DIR=<папка кэша> core/scripts/build-core.sh
```

Скрипт берёт префикс из раздела 3 и делает по порядку:
1. Собирает фреймворк ядра и тесты под архитектуру этого Mac и прогоняет тесты
2. Собирает и прогоняет вариант с AddressSanitizer и UndefinedBehaviorSanitizer
3. Собирает остальные архитектуры из `build.env`
4. Склеивает `<папка кэша>/core/VibeRDPCore.framework` — универсальный фреймворк для приложения — и проверяет, что наружу торчит только API `VRC*`
5. Прогоняет тесты остальных архитектур — через Rosetta, поэтому последними

Тесты ядра не требуют RDP-сервера: они подключаются к фейковым TCP-серверам на loopback (`core/tests/support.c`) и проверяют жизненный цикл сессии, отмену, уничтожение во время подключения и импорт модуля фреймворка в Swift.
Заголовок API лежит в `core/include`, модуль и список экспорта фреймворка — в `core/framework`.

---

## 5. Клиент: client-macos

```bash
VIBERDP_CACHE_DIR=<папка кэша> XCODEGEN=<путь к xcodegen> client-macos/scripts/build-client.sh
```

- `XCODEGEN` — путь к xcodegen, если его нет в `PATH`
- Нужен фреймворк из раздела 4: скрипт встраивает его в приложение

Скрипт делает по порядку:
1. Генерирует `client-macos/VibeRDP.xcodeproj` из `client-macos/project.yml` — версия, минимальная macOS, архитектуры и путь к фреймворку приходят из `build.env` и папки кэша
2. Собирает универсальное `VibeRDP.app` в конфигурации Release
3. Проверяет срезы и минимальную macOS приложения и встроенного фреймворка, ссылку на фреймворк и подпись
4. Прогоняет тесты внутри запущенного приложения — на этом Mac, затем остальные архитектуры через Rosetta; падает, если тестов ноль или прошли не все

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
├── downloads/      # архив OpenSSL
├── src/            # распакованный OpenSSL
├── build/          # деревья сборки: openssl-*, freerdp-*, core-* и проверка линковки
├── stage/          # установки через DESTDIR: внутри лежит зашитый префикс opt/viberdp
├── prefix/
│   ├── arm64/      # полная установка зависимостей под одну архитектуру
│   ├── x86_64/
│   └── universal/  # зависимости для ядра: заголовки, пакеты CMake, универсальные библиотеки и объекты каналов
├── core/
│   └── VibeRDPCore.framework   # универсальный фреймворк ядра
└── client/
    ├── DerivedData/  # сборка Xcode: Build/Products/Release/VibeRDP.app
    └── results/      # результаты тестов по архитектурам (.xcresult)
```

Подключение FreeRDP из CMake:
- `CMAKE_PREFIX_PATH=<папка кэша>/prefix/universal`
- `find_package(FreeRDP-Client 3 CONFIG REQUIRED)` и цель `freerdp-client`
- Для прямых вызовов OpenSSL — `find_package(OpenSSL CONFIG REQUIRED)` и цель `OpenSSL::Crypto`

Через pkg-config подключать нельзя: файлы FreeRDP не перечисляют фреймворки Apple.
Префикс ссылается на фреймворки SDK той машины, где шла сборка, поэтому собирается он там же, где используется.

---

## 8. Что проверяют скрипты

- sha256 архива OpenSSL совпадает с `build.env`
- У всех архитектур одинаковый набор объектов и одинаковые заголовки
- В каждой библиотеке, объекте, фреймворке и в приложении есть все срезы, записана минимальная macOS из `build.env` и нет слабых ссылок — то есть API новее этой macOS; служебные слабые ссылки тулчейна перечислены в `TOOLCHAIN_WEAK_SYMBOLS` (`core/scripts/common.sh`)
- В бинари зависимостей не попал ни один путь установки сборочной машины
- `core/scripts/link-check` собирается через пакеты CMake как универсальный бинарь и на запуске проверяет версии, пути под `RUNTIME_PREFIX` и встроенные каналы
- Фреймворк ядра экспортирует только `_VRC*` и несёт модуль для Swift
- Тесты ядра — на каждой архитектуре, которую Mac умеет исполнять, и отдельно под санитайзерами
- Приложение ссылается на фреймворк через `@rpath`, находит его в `Contents/Frameworks` и проходит `codesign --verify --deep --strict`
- xcodegen — ровно версии из `build.env`; тесты приложения — на каждой архитектуре, с подсчётом по xcresult

Любая проверка падает с сообщением `error:` и ненулевым кодом выхода.

---

## 9. CI

`.github/workflows/ci.yml` на каждый push в `main` и `next` и на pull request:
- **macOS** (`macos-26`) — скачивает XcodeGen из `build.env` со сверкой sha256 и прогоняет разделы 3, 4 и 5; приложение уходит артефактом `VibeRDP-app`
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
