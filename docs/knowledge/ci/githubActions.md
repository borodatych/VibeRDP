# GitHub Actions: раннеры и версии

Сверено 2026-09-24 по README и релизам на GitHub. Workflow — `.github/workflows/ci.yml`, решение о раннерах — [decisions.md](../../decisions.md), раздел 13.

## Образы раннеров

**Суть:**
- `macos-26` и `macos-latest` — macOS 26.6.2 на arm64, Xcode по умолчанию — 26.6; в образе есть CMake 4.4.3, Ninja 1.13.2 и rustup
- Xcode 27 доступен только в отдельном образе `xcode-27`, со статусом preview: GitHub предупреждает о нестабильном софте и очередях; с 2026-09-16 его база — macOS 27
- Образы macOS 14 устарели и перестают поддерживаться 2026-11-02
- `windows-2025` и `windows-latest` — Windows Server 2025 с Visual Studio 2026

**Не проверено:** есть ли Rosetta в образе `macos-26` — README её не упоминает; шаг `Toolchain` печатает это в каждом прогоне, а скрипты без Rosetta собирают x86_64, но не запускают.

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
