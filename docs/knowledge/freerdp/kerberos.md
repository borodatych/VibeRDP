# FreeRDP: Kerberos в NLA

Сверено 2026-09-25 на FreeRDP 3.32.0, MIT Kerberos 1.22.2 и macOS 26.6.2, задача 1.10.
Сборка — `build_krb5` в `core/scripts/build-freerdp.sh`, кэш билетов сессии — `core/src/kerberos.c`, тесты — `kerberosTests` и `kerberosLogonTests` в `core/tests`.
Выбор реализации — решение 23 в [decisions.md](../../decisions.md).

## Почему своя MIT Kerberos, а не системная

**Суть:**
- SSP Kerberos во FreeRDP зовёт API krb5 напрямую — `krb5_init_context`, `krb5_get_credentials`, `krb5_mk_req_extended` (`winpr/libwinpr/sspi/Kerberos/kerberos.c`), а не GSSAPI: `GSS.framework` без своего SSP ему не подходит
- `Kerberos.framework` в macOS — прослойка `MITKerberosShim` поверх Heimdal, и FreeRDP отказывается с ней собираться: `Apple MITKerberosShim is deprecated and not supported` (`cmake/FindKRB5.cmake:88-89`)
- Сам Heimdal в macOS — частный `Heimdal.framework` в `/System/Library/PrivateFrameworks` без заголовков
- Kerberos собирается из исходников MIT статически, под обе архитектуры, и уходит внутрь фреймворка ядра; наружу фреймворк по-прежнему экспортирует только `_VRC*`

## Проверка релиза

**Суть:**
- Архив и подпись — `https://kerberos.org/dist/krb5/1.22/krb5-1.22.2.tar.gz` и `.asc`; релизы серии лежат в папке с её номером
- Подпись сделана ключом RSA 4096 `C449 3CB7 39F4 A89F 9852 CBC2 0CBA 0857 5F83 72DF`, Greg Hudson <ghudson@mit.edu>, создан 2014-01-07; ключ скачан с keys.openpgp.org по отпечатку из подписи в отдельную связку `gnupg-verify` в папке кэша
- `gpg --verify` — «Действительная подпись» этим ключом; пути доверия к ключу нет, gpg об этом предупреждает
- sha256 архива — `3243ffbc…eaf13`, он и записан в `build.env`

**Применение:** обновление — та же процедура: подпись, затем новый sha256 в `build.env`; скрипту gpg не нужен.

## Сборка статической библиотеки

**Суть:**
- Опции `configure`: `--enable-static --disable-shared`, встроенная криптография (`--with-crypto-impl=builtin`), без PKINIT, без TLS для прокси KDC, без LDAP, LMDB, libedit и keyutils — библиотеке не нужно ничего сверх системы, OpenSSL в том числе
- `--with-krb5-config=no`: иначе `configure` берёт имена кэша и keytab по умолчанию у `krb5-config` из `PATH` — у той Kerberos, что стоит на машине сборки (`configure.ac:1451-1470`)
- Собираются только `util`, `include`, `lib` и `build-tools`: статически слинкованные утилиты администратора определяют `_master_keyblock` дважды, и линковка `kdb5_util` падает; перед установкой частей нужен `make install-mkdirs` верхнего уровня
- `CC` — `cc -arch <арх>`: проверки `configure` линкуют программы, а clang из тулчейна без корня SDK не находит `libSystem`
- Кэш билетов по умолчанию на macOS — `API:`, он живёт в `Kerberos.framework` (`cc_initialize`); общая сборка вшивает фреймворк в libkrb5, статическая оставляет его каждой программе — поэтому `LIBS="-framework Kerberos"` уже для `configure`
- `mit-krb5.pc` называет приватной только `-lkrb5support`, а статической линковке нужны и системные: `krb5-config` хранит их в `LIBS` и `DL_LIB` и сам говорит в комментарии, что для статики вывел бы `-lkrb5support $LIBS $DL_LIB`; скрипт дописывает их в `Libs.private`
- FreeRDP ищет Kerberos через pkg-config (`FindKRB5.cmake`), и `-DPKG_CONFIG_ARGN=--static` даёт ему приватные библиотеки; экспортированные пакеты FreeRDP несут их дальше, и ни ядру, ни проверке линковки своих списков не нужно
- Фреймворк в pkg-config записан одним флагом `-Wl,-framework,Kerberos`: CMake убирает повторы среди опций линковки по словам, и пара `-framework Kerberos` рядом с другим `-framework` развалилась бы

**Применение:** фреймворк ядра теперь ссылается на `/usr/lib/libresolv.9.dylib` и `/System/Library/Frameworks/Kerberos.framework` — оба есть в каждой macOS, начиная с 14.

## Слабая ссылка `_voucher_mach_msg_set`

**Суть:**
- Её дают заглушки Mach RPC, которые `mig` генерирует для кэша KCM: `kcmrpc.h` объявляет функцию с `__attribute__((weak_import))`, а `kcmrpc.c` зовёт её только после проверки `voucher_mach_msg_set != NULL`
- В `mach/mach.h` SDK функция объявлена без атрибутов доступности; libSystem даёт её во всех поддерживаемых macOS
- В статической библиотеке строка `nm -m` кончается именем символа, в слинкованном бинаре за ним идёт `(from libSystem)`

**Применение:** символ — в `TOOLCHAIN_WEAK_SYMBOLS` (`core/scripts/common.sh`) с шаблоном `( |$)` на конце.

## x86_64: упаковка по 2 байта

**Суть:**
- `krb5.h` и `CredentialsCache.h` на x86_64 включают `#pragma pack(push,2)` — так же, как заголовки `Kerberos.framework` в SDK: это ABI Apple, по которому структуры CCAPI ходят в системный фреймворк; на arm64 упаковки нет ни там, ни там
- Линковщик на срезе x86_64 предупреждает `alignment (2) of atom … is too small`, `pointer not aligned` и `disabling chained fixups because of unaligned pointers`: срез x86_64 получает старые записи fixups, arm64 — цепочки
- Тесты входа по Kerberos проходят и на x86_64 под Rosetta

**Применение:** предупреждения ожидаемы и не лечатся: смена упаковки сломала бы обмен с `Kerberos.framework`.

## Как себя ведёт MIT Kerberos на macOS

**Суть:**
- Настройки читаются из `~/Library/Preferences/edu.mit.Kerberos`, `/Library/Preferences/edu.mit.Kerberos`, `/etc/krb5.conf` и `/opt/viberdp/etc/krb5.conf` (`include/osconf.hin:47-48`) и из файла в `KRB5_CONFIG`
- Без настроек область берётся из домена в имени пользователя: FreeRDP ставит домен заглавными буквами областью по умолчанию (`kerberos.c:410-423`); KDC ищется в DNS — запись URI, затем SRV `_kerberos._udp` и `_kerberos._tcp`
- Для несуществующей области поиск занял 1,7 с на сети этого Мака: URI — 0,63 с, SRV по UDP — 0,46 с, по TCP — 0,61 с; дальше FreeRDP уходит на NTLM
- Модули поиска KDC грузятся и из `/System/Library/KerberosPlugins/KerberosFrameworkPlugins` (`lib/krb5/os/locate_kdc.c:401-404`): `AppSSOLocatePlugin`, `AppSSOConfigPlugin`, `heimdalodpac`, `Reachability`, `SCKerberosConfig`, с ними — `Heimdal.framework`, `GSS.framework` и `AppSSOKerberos.framework`; без настроенных областей сбоев нет, с областями расширения Kerberos SSO — _не проверено_
- Модули предаутентификации `pkinit` и `spake` MIT ищет динамическими в `/opt/viberdp/lib/krb5/plugins/preauth/`, не находит и пишет это в трассировку; Active Directory пользуется зашифрованной меткой времени, она встроена
- Коллекция кэшей `API:` читается: курсор по кэшам через `Kerberos.framework` работает

**Применение:** для входа в домен не нужно ничего настраивать, если DNS домена отдаёт записи SRV, а пользователь пишет имя с DNS-доменом — `ivanov@corp.example.com` или `corp.example.com\ivanov`; с NetBIOS-именем `CORP\ivanov` область `CORP` не найдётся, и вход пойдёт через NTLM.

## Что делает FreeRDP и что ядро меняет

**Суть:**
- Negotiate пробует Kerberos первым и уходит на NTLM, если Kerberos не дал учётных данных (`negotiate.c:319-340`); сборка без `WITH_KRB5_NO_NTLM_FALLBACK` этот откат сохраняет
- К адресу IP Kerberos не применяется (`kerberos.c:1099-1102`): имя службы — `TERMSRV/<хост, как его ввели>` через `krb5_sname_to_principal` (`kerberos.c:1183`)
- Дефект кэша: если в коллекции есть кэш этого пользователя, FreeRDP берёт не его, а кэш по умолчанию (`kerberos.c:455-476`) и получает билеты с паролем в него; когда кэш по умолчанию принадлежит другому пользователю, новые билеты его затирают
- Прокси KDC (`kdcproxyname` в `.rdp`, `KerberosKdcUrl`) FreeRDP применяет только к первичному запросу билета — временный профиль в `krb5glue_get_init_creds` (`krb5glue_mit.c:178-230`), а билет службы просит через контекст без прокси (`kerberos.c:1194`)
- `GetProcAddress: could not find procedure krb5_get_etype_info` в журнале: FreeRDP ищет функцию через `dlsym` по процессу, а фреймворк её не экспортирует — это только отказ от отладочного вывода; `QueryContextAttributes implement ulAttribute=0x00000456` — заглушка FreeRDP
- Неверный пароль — `ERRCONNECT_LOGON_FAILURE`, в ядре — `VRCErrorKindAuthentication`

**Применение:**
- Ядро даёт каждой сессии свой кэш `MEMORY:VibeRDP.<номер>` через `FreeRDP_KerberosCache` и уничтожает его в `ClientFree`: билеты получает пароль подключения, кэши пользователя не пишутся; трассировка теста показывает, что билет службы лёг в этот кэш и кэш уничтожен
- Прокси KDC через шлюз — отдельная задача: нужны свой патч FreeRDP, TLS в Kerberos и проверка сертификата прокси системой, а не пустым хранилищем OpenSSL (решение 8)

## Тестовый Kerberos

**Суть:**
- `build-test-server.sh` собирает KDC — общую сборку того же релиза MIT с сервером и утилитами базы — и sample-сервер FreeRDP с Kerberos; патч `kerberos-nla.patch` добавляет серверу `--kerberos-keytab`: только NLA, только Kerberos (`!ntlm`), TCP на `localhost`
- Kerberos называет службу по имени хоста, путь Unix-сокета им не является — поэтому этот сервер слушает TCP, и только loopback
- `build-core.sh` делает область `VIBERDP.TEST` на каждый прогон во временной папке: пользователь `tester` со случайным паролем и обязательной предаутентификацией, как в Active Directory, ключ `TERMSRV/localhost` в keytab; KDC и сервер — на свободных портах loopback
- Готовность ждётся по слушающему сокету (`lsof -sTCP:LISTEN`): sample-сервер пишет «Listening on» уровнем INFO в stdout, а stdout в файл буферизуется
- Тесты входа — в ядре, консольной программой: приложение в CI висело на `connect` к `127.0.0.1` — [macos/localNetworkPrivacy.md](../macos/localNetworkPrivacy.md)

**Применение:** `logonWithPrincipalName`, `logonWithDomainPrefix`, `wrongPasswordFailsTheLogon`, `ticketsLeaveWithTheSession` проходят на arm64, под санитайзерами и на x86_64; журналы KDC и сервера — `<папка кэша>/core-tests/`.

**Источники:**
- `core/third_party/FreeRDP/winpr/libwinpr/sspi/Kerberos/kerberos.c`, `krb5glue_mit.c`, `winpr/libwinpr/sspi/Negotiate/negotiate.c`, `cmake/FindKRB5.cmake`
- Исходники MIT krb5 1.22.2: `src/configure.ac`, `src/include/osconf.hin`, `src/lib/krb5/os/locate_kdc.c`, `src/lib/krb5/ccache/cc_memory.c`
- https://kerberos.org/dist/index.html — страница релизов MIT

## «Cannot find KDC for realm» у владельца

**Суть:**
- Журнал каждого подключения к Windows владельца (домен `RTMIS.RU`): `krb5_init_creds_get (Cannot find KDC for realm "RTMIS.RU")`, затем вход по NTLM проходит
- MIT Kerberos ищет KDC записями DNS SRV `_kerberos._udp` и `_kerberos._tcp` домена; с Мака владельца 2026-09-26 все они пусты, как и `_ldap._tcp` и `_kerberos._tcp.dc._msdcs`
- Мак владельца спрашивает DNS Tailscale (`100.100.100.100`) и домашнего роутера, корпоративного DNS у него нет — `dig +short SRV _kerberos._tcp.rtmis.ru` пуст
- Это окружение, а не дефект: без DNS домена KDC не найти, и откат на NTLM — правильное поведение

**Применение:** пункт закрыт; поле «адрес KDC» у подключения — если встретится домен с запретом NTLM и без корпоративного DNS; с RD Gateway — прокси KDC, задача 1.12.

