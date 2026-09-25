# FreeRDP: сборка под macOS

Сверено по исходникам FreeRDP 3.32.0 (подмодуль `core/third_party/FreeRDP`) и OpenSSL 3.5.8 — 2026-09-24.
Скрипт сборки — `core/scripts/build-freerdp.sh`, параметры — `build.env`, порядок работы — [devSetup.md](../../manuals/devSetup.md).

## OpenSSL обязателен; версия и проверка подлинности

**Суть:**
- `OPENSSL_FEATURE_TYPE` равен `REQUIRED` (`CMakeLists.txt:302`); Mbed-TLS и LibreSSL помечены экспериментальными, а апстрим пишет, что на каждом релизе тестирует только OpenSSL
- Сам апстрим собирает свои пакеты с OpenSSL новых веток: `cmake/DepVersions.cmake` закрепляет `openssl-4.0.1` (сборки iOS и Android), `scripts/bundle-mac-os.sh` берёт `openssl-3.6.0`
- VibeRDP берёт 3.5.8: ветка 3.5 — LTS с поддержкой до 2030-04-08, у 4.0 поддержка до 2027-05-14
- Подлинность архива проверена подписью: `pubkeys.asc` с openssl-library.org импортирован в отдельную связку ключей (`gnupg-verify` в папке кэша), `gpg --verify` дал `VALIDSIG` с основным отпечатком `B146 647E 45A7 B339 47AB 226B 2A2C 87D1 6169 2D40` — тем, что опубликован на странице исходников OpenSSL
- sha256 архива `a8f84a39…5b2` совпал с файлом `.sha256` релиза и закреплён в `build.env`; скрипт сверяет его при каждой сборке

**Применение:** обновление OpenSSL — та же процедура: подпись, затем новый sha256 в `build.env`; скрипту gpg не нужен.

**Источники:**
- `core/third_party/FreeRDP/CMakeLists.txt:302`, `:371-376`, `:447-451`
- `core/third_party/FreeRDP/cmake/DepVersions.cmake`, `scripts/bundle-mac-os.sh:136`
- https://openssl-library.org/policies/releasestrat/
- https://openssl-library.org/source/

## MD4 и RC4 для NTLM — встроенные, а не из legacy-провайдера

**Суть:**
- С OpenSSL WinPR по умолчанию берёт RC4, MD4 и MD5 у него (`WITH_INTERNAL_*` выключены, `winpr/CMakeLists.txt:99-106`)
- В OpenSSL 3 MD4 и RC4 живут в legacy-провайдере; WinPR загружает его сам с пометкой, что он нужен для MD4 (`winpr/libwinpr/utils/ssl.c:329-334`)
- Апстримный `scripts/bundle-mac-os.sh` включает встроенные реализации: `WITH_INTERNAL_RC4`, `WITH_INTERNAL_MD4`, `WITH_INTERNAL_MD5`
- OpenSSL собран с `no-dso`: по каскаду Configure это выключает `module`, и объекты legacy-провайдера уходят внутрь `libcrypto` (`providers/build.info`, ветка `$disabled{module}`)

**Применение:** NTLM в NLA не зависит от файла провайдера на диске; `WITH_INTERNAL_*` включены в скрипте.

**Не проверено:** что предупреждение WinPR о legacy-провайдере при старте исчезает — увидим на 1.1 при первом подключении.

**Источники:**
- `core/third_party/FreeRDP/winpr/CMakeLists.txt:99-120`
- `core/third_party/FreeRDP/winpr/libwinpr/utils/ssl.c:329-334`
- `openssl-3.5.8/Configure`, строки каскадов `"dso"` и `"module"`

## Каждая архитектура собирается отдельно

**Суть:**
- `scripts/bundle-mac-os.sh` собирает всё одним проходом с `CMAKE_OSX_ARCHITECTURES` на обе архитектуры, а OpenSSL — с `no-asm`, то есть без ассемблерной криптографии
- `cmake/DetectIntrinsicSupport.cmake` на Apple включает флаги SSE, если в `CMAKE_OSX_ARCHITECTURES` есть x86_64, — при одном проходе они уходят и в срез arm64
- В `NEON_LIST` нет `arm64`, поэтому на Apple arm64 флаги NEON не добавляются; на arm64 NEON есть без флагов

**Применение:** скрипт собирает OpenSSL (с ассемблером) и FreeRDP отдельно под каждую архитектуру и склеивает архивы через `lipo`.

**Источники:**
- `core/third_party/FreeRDP/scripts/bundle-mac-os.sh:105-121`, `:204`
- `core/third_party/FreeRDP/cmake/DetectIntrinsicSupport.cmake`

## Что приходится выключать явно

**Суть:**
- Макрос `find_feature` (`cmake/FindFeature.cmake`): фича `OPTIONAL` ищется только при явном `ON`, `RECOMMENDED` — только если `WITH_<ИМЯ>` задан, `REQUIRED` — всегда
- Включены по умолчанию: `WITH_FFMPEG` и `WITH_SWSCALE` (`cmake/ConfigOptions.cmake:145`, `:161`), `WITH_MACAUDIO` на Apple (`:66`), `WITH_SAMPLE`, `WITH_SERVER`, `WITH_CLIENT` с SDL-клиентом, `WITH_WINPR_TOOLS` (`winpr/CMakeLists.txt:109`), `WITH_SMARTCARD_EMULATE` (`CMakeLists.txt:139`)
- LTO в Release включается по умолчанию, если компилятор умеет (`cmake/CommonConfigOptions.cmake:32`); в статических архивах это биткод LLVM, поэтому выключаем
- По найденному включаются: `WITH_OPUS` (`libfreerdp/CMakeLists.txt:156`), `WITH_URIPARSER` (`winpr/libwinpr/CMakeLists.txt:129`), JSON (`cmake/JsonDetect.cmake`)
- `WITH_KRB5` на Apple выключен по умолчанию (`winpr/libwinpr/sspi/CMakeLists.txt`); скрипт включает его со своей MIT Kerberos — [kerberos.md](kerberos.md)
- Библиотеки Homebrew собраны под одну архитектуру: префиксы `/opt/homebrew`, `/usr/local`, `/opt/local` скрыты через `CMAKE_IGNORE_PREFIX_PATH`, как в апстримном скрипте, а pkg-config видит только собранную Kerberos своей архитектуры

**Применение:** все эти опции заданы в скрипте явно; ничего из найденного на машине в сборку не попадает.

## Пути, которые зашиваются в бинарь

**Суть:**
- FreeRDP записывает в `build-config.h` префикс установки и путь плагинов; на macOS без `MAC_BUNDLE` пути плагинов абсолютные, `<префикс>/lib/freerdp3` (`CMakeLists.txt:458-489`), по ним грузятся динамические каналы (`libfreerdp/common/addin.c`, `channels/client/addin.c`)
- WinPR записывает `WINPR_INSTALL_PREFIX` и `WINPR_INSTALL_SYSCONFDIR` (`winpr/include/config/build-config.h.in`); для префикса в `/opt` GNUInstallDirs уводит папку настроек в `/etc/opt/<имя>` — в бинаре строка `/etc//opt/viberdp`
- OpenSSL записывает `OPENSSLDIR` — папку конфига и хранилища доверенных сертификатов, по умолчанию `/usr/local/ssl`, — а также папки модулей и движков
- FreeRDP проверяет сертификаты через `X509_STORE_set_default_paths` (`libfreerdp/crypto/x509_utils.c:1038`), то есть доверяет корням из `OPENSSLDIR`, и не отключает загрузку конфига OpenSSL
- Если зашитый путь доступен пользователю на запись — например `/Volumes/<имя>` смонтированного образа или `/usr/local` на части машин, — туда можно подложить свой корневой сертификат (тихий MITM) или плагин канала (исполнение кода)

**Применение:**
- Зашитый префикс — `RUNTIME_PREFIX=/opt/viberdp` из `build.env`: создать его может только root
- OpenSSL: `--prefix=/opt/viberdp --openssldir=/opt/viberdp/ssl` и `no-dso`; FreeRDP: `CMAKE_INSTALL_PREFIX=/opt/viberdp`; файлы ставятся через `DESTDIR` и переносятся в папку кэша
- Скрипт падает, если в библиотеках встретится путь установки сборочной машины; `link-check` проверяет пути OpenSSL и путь плагинов FreeRDP на запуске
- Вывод для 1.1 и 1.7: хранилище OpenSSL на машине пользователя пусто, поэтому доверие к сертификату сервера и шлюза решает клиент через проверку macOS (SecTrust), где лежат системные и корпоративные корни — _механику колбэка FreeRDP проверить на 1.1_

**Источники:**
- `core/third_party/FreeRDP/CMakeLists.txt:458-489`
- `core/third_party/FreeRDP/include/config/build-config.h.in`, `winpr/include/config/build-config.h.in`
- `core/third_party/FreeRDP/libfreerdp/crypto/x509_utils.c:1038`
- `openssl-3.5.8/INSTALL.md`, раздел `openssldir`

## Встроенные каналы

**Суть:**
- Опции каналов — `CHANNEL_<ИМЯ>` и `CHANNEL_<ИМЯ>_CLIENT` (макрос `define_channel_options` в `channels/CMakeLists.txt`); динамические каналы зависят от `CHANNEL_DRDYNVC`
- В 3.32.0 имя канала совпадает с именем его папки в `channels/` — скрипт берёт список оттуда, так что новый канал апстрима по умолчанию выключен
- `freerdp_channels_load_static_addin_entry(имя, NULL, NULL, 0)` ищет встроенную запись по имени без фильтра по типу (`channels/client/addin.c:441`) — на этом построен `link-check`

**Источники:**
- `core/third_party/FreeRDP/channels/CMakeLists.txt:21-63`
- `core/third_party/FreeRDP/channels/client/addin.c:441-505`

## Подключать через пакеты CMake, а не через pkg-config

**Суть:**
- Файлы pkg-config FreeRDP 3.32.0 на macOS не перечисляют фреймворки Apple: линковка по `pkg-config --static --libs freerdp-client3` падает на символах CoreFoundation (`CFLocale*`, `CFString*`), IOKit (`IOPS*` из `winpr/sysinfo`) и Foundation (`objc_*`, `NSString` из `unicode_apple.m`)
- Пакеты CMake (`lib/cmake/FreeRDP-Client3`, `FreeRDP3`, `WinPR3`) несут полный интерфейс: OpenSSL, фреймворки CoreFoundation, IOKit, Foundation и Carbon, библиотеку `m`
- Каналы в пакете `FreeRDP-Client` — цели `OBJECT IMPORTED` (`cliprdr-client` и другие), их объектные файлы ставятся в `lib/freerdp3/objects-Release/`; те же символы лежат и в `libfreerdp-client3.a`
- Пакет называется `FreeRDP-Client` (папка `FreeRDP-Client3`), цели — `freerdp-client`, `freerdp`, `winpr`; зависимости он находит сам через `find_dependency`
- Во фреймворки пакеты ссылаются абсолютными путями в SDK той машины, где шла сборка: префикс годится для сборки на ней же, переносить его на другую машину нельзя

**Применение:**
- `lipo` и все проверки скрипта идут по всем объектам Mach-O префикса — и `.a`, и `.o`: без этого объекты каналов остались бы только arm64
- `core/scripts/link-check` собирается через `find_package(FreeRDP-Client 3 CONFIG)` — так же ядро будет подключать FreeRDP на 0.3

## Сборка без масштабирования изображений

**Суть:** при выключенных `WITH_SWSCALE` и `WITH_CAIRO` CMake предупреждает, что FreeRDP собирается без масштабирования изображений (`libfreerdp/CMakeLists.txt:209`).

**Не проверено:** какие пути FreeRDP упираются в масштабирование — решить на 1.2 вместе с H.264: SWScale входит в FFmpeg, и выбор между FFmpeg и VideoToolbox затрагивает и его.

## Результат сборки 2026-09-24

**Суть:**
- Сборка с нуля обеих архитектур — 120 с на Apple M4 (10 ядер), повторная — около 10 с
- Универсальные архивы: `libcrypto.a` 17 МБ, `libfreerdp3.a` 7,5 МБ, `libwinpr3.a` 3,4 МБ, `libssl.a` 3 МБ, `libfreerdp-client3.a` 1,2 МБ; объектов каналов — 13
- Префикс `universal` — 38 МБ, вся папка кэша со сборками — около 350 МБ
- Минимальная macOS 14.0 записана во всех объектах: в `libcrypto` 1035 объектов arm64 и 1044 x86_64, в `libfreerdp3` по 185
- Строки бинарей не содержат путей сборочной машины; зашитые пути — только под `/opt/viberdp` и `/etc/opt/viberdp`


## API новее минимальной macOS: pipe2

**Суть:**
- В SDK Xcode 27 у `pipe2` и `dup3` стоит `__API_AVAILABLE(macos(27.0))` (`usr/include/sys/unistd.h:216-219`)
- `check_symbol_exists(pipe2 unistd.h WINPR_HAVE_PIPE2)` (`winpr/CMakeLists.txt:232`) лишь берёт адрес функции — такое использование компилятор не проверяет на доступность, и проверка проходит
- С `WINPR_HAVE_PIPE2` WinPR зовёт `pipe2` в `winpr_event_init` (`winpr/libwinpr/synch/event.c:120`) и в семафорах (`synch/semaphore.c:147`); при цели macOS 14 ссылка на неё становится слабой
- На macOS 26.6 `dlsym(RTLD_DEFAULT, "pipe2")` возвращает NULL: каждое создание контекста FreeRDP падало вызовом по нулевому адресу в `CreateEventA`
- Проверка линковки 0.2 этого не увидела — она не создаёт событий; поймали тесты ядра 0.3

**Применение:**
- `-DWINPR_HAVE_PIPE2=OFF` задаёт результат проверки заранее, и WinPR берёт `pipe()`
- `-Werror=unguarded-availability-new` делает любое использование API новее цели ошибкой компиляции FreeRDP
- Скрипт падает, если в любом объекте есть слабая внешняя ссылка (`nm -m`: `(undefined) weak external`) — это и есть API новее минимальной macOS

**Источники:**
- Заголовок `usr/include/sys/unistd.h` из SDK Xcode 27.0
- `core/third_party/FreeRDP/winpr/CMakeLists.txt:232`, `winpr/libwinpr/synch/event.c:96-138`

## Повторы OpenSSL в интерфейсе WinPR

**Суть:** пакет CMake `WinPR3` перечисляет `libssl.a` и `libcrypto.a` в своём интерфейсе дважды, поэтому каждая линковка через него печатает `ld: warning: ignoring duplicate libraries` — это безвредно.
