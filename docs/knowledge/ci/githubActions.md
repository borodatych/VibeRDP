# GitHub Actions: раннеры и версии

Сверено 2026-09-24 по README и релизам на GitHub. Workflow — `.github/workflows/ci.yml`, решение о раннерах — [decisions.md](../../decisions.md), раздел 13.

## Образы раннеров

**Суть:**
- `macos-26` и `macos-latest` — macOS 26.6.2 на arm64, Xcode по умолчанию — 26.6; в образе есть CMake 4.4.3, Ninja 1.13.2 и rustup
- Xcode 27 доступен только в отдельном образе `xcode-27`, со статусом preview: GitHub предупреждает о нестабильном софте и очередях; с 2026-09-16 его база — macOS 27
- Образы macOS 14 устарели и перестают поддерживаться 2026-11-02
- `windows-2025` и `windows-latest` — Windows Server 2025 с Visual Studio 2026
- В образе `macos-26` есть Rosetta, хотя README её не упоминает: первый прогон 2026-09-24 гонял тесты ядра и клиента под x86_64; шаг `Toolchain` печатает это в каждом прогоне, а без Rosetta скрипты собирают x86_64, но не запускают
- Первый прогон задачи macOS со сборкой OpenSSL и FreeRDP с нуля — 7 минут
- Виртуальная GPU раннера `macos-26` тянет Metal и Metal Performance Shaders: в прогоне 36101460663 (2026-09-25) тесты рендера и живой тест с sample-сервером прошли на arm64 и x86_64, пропущенных ноль; сборка тестового сервера — 38 с
- Кэш сборки в CI — `$RUNNER_TEMP` на системном диске: вопроса macOS о доступе к съёмному тому там не бывает — [macos/removableVolumePrivacy.md](../macos/removableVolumePrivacy.md)

## PowerShell: двоеточие после переменной в строке

**Суть:** в строке в двойных кавычках `"$Exe: …"` PowerShell читает `$Exe:` как переменную с областью видимости и падает при разборе всего скрипта: `Variable reference is not valid. ':' was not followed by a valid variable name character`.

**Применение:** перед двоеточием имя берётся в фигурные скобки — `"${Exe}: …"`; локально PowerShell не стоит, скрипты `*.ps1` проверяет только задача Windows.

## Версии actions и инструментов

**Суть:**
- `actions/checkout` — v7.0.1, `actions/upload-artifact` — v7.0.1: берутся по мажорному тегу `@v7`
- shellcheck 0.11.0: sha256 архива `linux.x86_64.tar.xz` — `8c3be12b…7198`; в образе Ubuntu стоит более старый 0.9, который спорит с 0.11 о номерах проверок
- actionlint 1.7.12: sha256 архива `linux_amd64.tar.gz` — `8aca8db9…a3d8`; actionlint прогоняет блоки `run:` через shellcheck из `PATH`
- XcodeGen 2.46.0: sha256 `xcodegen.zip` — `4d9e34b6…6806`, закреплён в `build.env`
- Контрольные суммы — дайджесты, которые GitHub публикует у ассетов релиза: `gh api repos/<владелец>/<репо>/releases/tags/<тег> --jq '.assets[] | .name + " " + .digest'`

**Применение:** инструменты скачиваются по закреплённой версии и сверяются по sha256 до запуска; локально те же версии — shellcheck 0.11.0 и actionlint 1.7.12.

**Источники:**
- https://github.com/actions/runner-images — таблица образов и `images/macos/macos-26-arm64-Readme.md`
- https://github.com/actions/runner-images/issues/14404 — образ `xcode-27`
- https://github.com/actions/runner-images/issues/13518 — вывод macOS 14
- https://github.com/actions/checkout/releases , https://github.com/actions/upload-artifact/releases
- https://github.com/koalaman/shellcheck/releases/tag/v0.11.0 , https://github.com/rhysd/actionlint/releases/tag/v1.7.12
- https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0
