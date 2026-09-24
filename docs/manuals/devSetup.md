# СРЕДА РАЗРАБОТКИ И СБОРКА ЯДРА

Что поставить, как собрать зависимости ядра и чем проверить результат.
Параметры сборки — в [`build.env`](../../build.env), обоснования и грабли — в [knowledge/freerdp/buildMacOS.md](../knowledge/freerdp/buildMacOS.md).

---

## 1. Что нужно

- **Mac** на Apple Silicon или Intel
- **Xcode 27** — если `xcode-select -p` указывает на CommandLineTools, задайте в окружении сборки `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- **CMake** не ниже 3.23 — скрипт пользуется `CMAKE_IGNORE_PREFIX_PATH`; проверено на 4.4.3
- **perl, make, curl, shasum, tar, lipo, otool, strings** — есть в macOS и Xcode
- **ninja** — по желанию: с ним сборка быстрее, без него скрипт берёт make
- **Rosetta** — по желанию: без неё срез x86_64 только линкуется, а не запускается
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

## 3. Сборка

```bash
VIBERDP_CACHE_DIR=<папка кэша> core/scripts/build-freerdp.sh
```

- `VIBERDP_CACHE_DIR` — куда класть скачанное, деревья сборки и результат; по умолчанию `core/build/`, она в `.gitignore`
- `CMAKE` — путь к cmake, если его нет в `PATH`
- Полная сборка с нуля — около двух минут на Apple M4 (10 ядер) и около 350 МБ в папке кэша; повторная — секунды: OpenSSL пропускается по метке, FreeRDP собирается инкрементально
- Сборка с нуля: удалите в папке кэша `build/`, `stage/`, `prefix/` и `src/` — скачанный архив останется в `downloads/`

---

## 4. Что получается

```
<папка кэша>/
├── downloads/      # архив OpenSSL
├── src/            # распакованный OpenSSL
├── build/          # деревья сборки по архитектурам и проверка линковки
├── stage/          # установки через DESTDIR: внутри лежит зашитый префикс opt/viberdp
└── prefix/
    ├── arm64/      # полная установка под одну архитектуру
    ├── x86_64/
    └── universal/  # результат: заголовки, пакеты CMake, универсальные библиотеки и объекты каналов
```

Подключение из CMake:
- `CMAKE_PREFIX_PATH=<папка кэша>/prefix/universal`
- `find_package(FreeRDP-Client 3 CONFIG REQUIRED)` и цель `freerdp-client`
- Для прямых вызовов OpenSSL — `find_package(OpenSSL CONFIG REQUIRED)` и цель `OpenSSL::Crypto`

Через pkg-config подключать нельзя: файлы FreeRDP не перечисляют фреймворки Apple.
Префикс ссылается на фреймворки SDK той машины, где шла сборка, поэтому собирается он там же, где используется.

---

## 5. Что проверяет скрипт

- sha256 архива OpenSSL совпадает с `build.env`
- У всех архитектур одинаковый набор объектов и одинаковые заголовки
- В каждой библиотеке и каждом объекте есть все срезы, а минимальная macOS совпадает с `build.env`
- В бинари не попал ни один путь установки сборочной машины
- `core/scripts/link-check` собирается через пакеты CMake как универсальный бинарь и на запуске проверяет:
  - версии FreeRDP и OpenSSL
  - что пути плагинов, конфига и модулей лежат под `RUNTIME_PREFIX`
  - что каналы из `build.env` встроены, а остальные отсутствуют

Любая проверка падает с сообщением `error:` и ненулевым кодом выхода.

---

## 6. Обновить FreeRDP

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
Дальше — сборка скриптом, запись в базе знаний о том, что изменилось в опциях, и коммит нового указателя подмодуля.

---

## 7. Обновить OpenSSL

1. Скачать `openssl-<версия>.tar.gz` и `openssl-<версия>.tar.gz.asc` из релиза на github.com/openssl/openssl и `pubkeys.asc` с https://openssl-library.org/source/
2. Проверить подпись в отдельной связке ключей, не трогая свою:
   ```bash
   export GNUPGHOME="$(mktemp -d)"; gpg --import pubkeys.asc && gpg --verify openssl-<версия>.tar.gz.asc openssl-<версия>.tar.gz
   ```
3. Сверить основной отпечаток ключа из вывода с опубликованным на https://openssl-library.org/source/
4. Записать в `build.env` новые `OPENSSL_VERSION` и `OPENSSL_SHA256` (`shasum -a 256` архива)
5. Собрать скриптом: метка сборки изменится, и OpenSSL пересоберётся сам
