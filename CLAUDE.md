# CLAUDE.md — VibeRDP

Базовые правила — в глобальном `~/.claude/CLAUDE.md`. Здесь — только специфика VibeRDP.

## Что это

Open-source RDP-клиент для macOS на замену Microsoft Windows App: буфер обмена, который работает сразу, и окна Windows-приложений как отдельные окна macOS — режимы RAIL, Seam и Desktop.
Концепт и архитектура — [docs/idea.md](docs/idea.md), план — [docs/roadmap.md](docs/roadmap.md), база знаний — [docs/knowledge/](docs/knowledge/README.md), решения — [docs/decisions.md](docs/decisions.md).

## Правила проекта

Полный список — `.vibe/rules/viberdp.mdc`, подключён сюда целиком:

@.vibe/rules/viberdp.mdc

## Проверки перед завершением задачи

Скрипты — shellcheck; workflow CI — actionlint:

```bash
shellcheck -x core/scripts/*.sh client-macos/scripts/*.sh
```

```bash
/Volumes/Storage/Caches/VibeRDP/tools/actionlint-1.7.12/actionlint -color
```

Зависимости ядра — сборка с проверками срезов, минимальной macOS, зашитых путей и линковки ([docs/manuals/devSetup.md](docs/manuals/devSetup.md)):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VIBERDP_CACHE_DIR=/Volumes/Storage/Caches/VibeRDP CMAKE=/Volumes/Storage/Caches/VibeRDP/tools/cmake-4.4.3-macos-universal/CMake.app/Contents/bin/cmake core/scripts/build-freerdp.sh
```

Ядро — сборка под все архитектуры, тесты, санитайзеры и универсальный фреймворк:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VIBERDP_CACHE_DIR=/Volumes/Storage/Caches/VibeRDP CMAKE=/Volumes/Storage/Caches/VibeRDP/tools/cmake-4.4.3-macos-universal/CMake.app/Contents/bin/cmake core/scripts/build-core.sh
```

Хелпер — форматирование и clippy под хост и под Windows; сам exe собирается только на Windows:

```bash
cd helper-win && CARGO_TARGET_DIR=/Volumes/Storage/Caches/VibeRDP/cargo cargo fmt --check && CARGO_TARGET_DIR=/Volumes/Storage/Caches/VibeRDP/cargo cargo clippy -- -D warnings && CARGO_TARGET_DIR=/Volumes/Storage/Caches/VibeRDP/cargo cargo clippy --target x86_64-pc-windows-msvc -- -D warnings
```

Клиент — генерация проекта, универсальное приложение, проверки бандла и тесты под обе архитектуры:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VIBERDP_CACHE_DIR=/Volumes/Storage/Caches/VibeRDP XCODEGEN=/Volumes/Storage/Caches/VibeRDP/tools/xcodegen-2.46.0/xcodegen/bin/xcodegen client-macos/scripts/build-client.sh
```

Exe хелпера и его проверку `helper-win/scripts/check-exe.ps1` гоняет только CI на Windows.
Перед коммитом — отсутствие атрибуции ассистента в истории, вывод должен быть пустым:

```bash
git log --all --format='%B' | grep -niE "co-authored-by|generated with|anthropic\.com|claude-code"
```

## Окружение

- Xcode 27.0 стоит в `/Applications/Xcode.app`, но `xcode-select` указывает на CommandLineTools: сборку вести с `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, системную настройку не менять
- CMake 4.4.3 лежит в `/Volumes/Storage/Caches/VibeRDP/tools/` и не стоит в `PATH` — скрипту его передаёт переменная `CMAKE`
- XcodeGen 2.46.0 и actionlint 1.7.12 лежат в `/Volumes/Storage/Caches/VibeRDP/tools/` и не стоят в `PATH`: XcodeGen скрипту клиента передаёт переменная `XCODEGEN`
- Не скачан компонент Metal Toolchain (нужен на 1.2) — установка по согласованию с владельцем
- Репозиторий — публичный https://github.com/borodatych/VibeRDP, CI — GitHub Actions на каждый push в `main` и `next`
- Rust 1.97.1 через rustup; у тулчейна `1.97.1` уже есть `x86_64-pc-windows-msvc`, у `stable` — только `aarch64-apple-darwin`; хелпер закрепляет `1.97.1`
- Сборочные кэши и скачанные зависимости — в `/Volumes/Storage/Caches/VibeRDP/` (`VIBERDP_CACHE_DIR`), не в репозиторий и не в `~`
- start0 не используется — [docs/decisions.md](docs/decisions.md), раздел 2
