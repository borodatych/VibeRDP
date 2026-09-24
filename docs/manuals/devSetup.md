# СРЕДА РАЗРАБОТКИ И СБОРКА ЯДРА

Что поставить, как собрать зависимости и ядро `VibeRDPCore` и чем проверить результат.
Параметры сборки — в [`build.env`](../../build.env), обоснования и грабли — в [knowledge/freerdp/buildMacOS.md](../knowledge/freerdp/buildMacOS.md) и [knowledge/freerdp/clientLifecycle.md](../knowledge/freerdp/clientLifecycle.md).

---

## 1. Что нужно

- **Mac** на Apple Silicon или Intel
- **Xcode 27** — если `xcode-select -p` указывает на CommandLineTools, задайте в окружении сборки `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- **CMake** не ниже 3.24 — скрипты пользуются `--fresh` и `CMAKE_IGNORE_PREFIX_PATH`; проверено на 4.4.3
- **ninja** — нужен для теста ядра на Swift: CMake собирает Swift только генераторами Ninja и Xcode; без ninja скрипты берут make, и Swift-тест пропускается
- **perl, make, curl, shasum, tar, lipo, otool, nm, strings** — есть в macOS и Xcode
- **Rosetta** — по желанию: без неё код x86_64 только собирается и линкуется, а не запускается
- **shellcheck** — для проверки скриптов

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
1. Собирает ядро и тесты под архитектуру этого Mac и прогоняет тесты
2. Собирает и прогоняет вариант с AddressSanitizer и UndefinedBehaviorSanitizer
3. Собирает остальные архитектуры из `build.env`
4. Склеивает `<папка кэша>/core/lib/libVibeRDPCore.a` — универсальную библиотеку для приложения
5. Прогоняет тесты остальных архитектур — через Rosetta, поэтому последними

Тесты ядра не требуют RDP-сервера: они подключаются к фейковым TCP-серверам на loopback (`core/tests/support.c`) и проверяют жизненный цикл сессии, отмену, уничтожение во время подключения и импорт API в Swift.
Заголовок API и `module.modulemap` для Swift лежат в `core/include`.

---

## 5. Что получается

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
└── core/lib/       # libVibeRDPCore.a — универсальная библиотека ядра
```

Подключение FreeRDP из CMake:
- `CMAKE_PREFIX_PATH=<папка кэша>/prefix/universal`
- `find_package(FreeRDP-Client 3 CONFIG REQUIRED)` и цель `freerdp-client`
- Для прямых вызовов OpenSSL — `find_package(OpenSSL CONFIG REQUIRED)` и цель `OpenSSL::Crypto`

Через pkg-config подключать нельзя: файлы FreeRDP не перечисляют фреймворки Apple.
Префикс ссылается на фреймворки SDK той машины, где шла сборка, поэтому собирается он там же, где используется.

---

## 6. Что проверяют скрипты

- sha256 архива OpenSSL совпадает с `build.env`
- У всех архитектур одинаковый набор объектов и одинаковые заголовки
- В каждой библиотеке и каждом объекте есть все срезы, записана минимальная macOS из `build.env` и нет слабых ссылок — то есть API новее этой macOS
- В бинари зависимостей не попал ни один путь установки сборочной машины
- `core/scripts/link-check` собирается через пакеты CMake как универсальный бинарь и на запуске проверяет версии, пути под `RUNTIME_PREFIX` и встроенные каналы
- Тесты ядра — на каждой архитектуре, которую Mac умеет исполнять, и отдельно под санитайзерами

Любая проверка падает с сообщением `error:` и ненулевым кодом выхода.

---

## 7. Если что-то зависло

- **Запуск кода x86_64 оборвался по таймауту** — Rosetta перестала переводить новые программы: `sudo launchctl kickstart -k system/com.apple.oahd`, не помогло — перезагрузка; подробности в [knowledge/macos/toolingHangs.md](../knowledge/macos/toolingHangs.md)
- **Тест под санитайзером упал с адресами вместо имён** — так задумано, `atos` не подключается к процессу; имена даёт офлайн `xcrun atos -o <бинарь> -arch arm64 -l 0x100000000 <адреса>`

---

## 8. Обновить FreeRDP

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

## 9. Обновить OpenSSL

1. Скачать `openssl-<версия>.tar.gz` и `openssl-<версия>.tar.gz.asc` из релиза на github.com/openssl/openssl и `pubkeys.asc` с https://openssl-library.org/source/
2. Проверить подпись в отдельной связке ключей, не трогая свою:
   ```bash
   export GNUPGHOME="$(mktemp -d)"; gpg --import pubkeys.asc && gpg --verify openssl-<версия>.tar.gz.asc openssl-<версия>.tar.gz
   ```
3. Сверить основной отпечаток ключа из вывода с опубликованным на https://openssl-library.org/source/
4. Записать в `build.env` новые `OPENSSL_VERSION` и `OPENSSL_SHA256` (`shasum -a 256` архива)
5. Собрать скриптами: метка сборки изменится, и OpenSSL пересоберётся сам
