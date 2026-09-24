# CLAUDE.md — VibeRDP

Базовые правила — в глобальном `~/.claude/CLAUDE.md`. Здесь — только специфика VibeRDP.

## Что это

Open-source RDP-клиент для macOS на замену Microsoft Windows App: буфер обмена, который работает сразу, и окна Windows-приложений как отдельные окна macOS — режимы RAIL, Seam и Desktop.
Концепт и архитектура — [docs/idea.md](docs/idea.md), план — [docs/roadmap.md](docs/roadmap.md), база знаний — [docs/knowledge/](docs/knowledge/README.md), решения — [docs/decisions.md](docs/decisions.md).

## Правила проекта

Полный список — `.vibe/rules/viberdp.mdc`, подключён сюда целиком:

@.vibe/rules/viberdp.mdc

## Проверки перед завершением задачи

Скрипты — shellcheck:

```bash
shellcheck -x core/scripts/*.sh
```

Зависимости ядра — сборка с проверками срезов, минимальной macOS, зашитых путей и линковки ([docs/manuals/devSetup.md](docs/manuals/devSetup.md)):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VIBERDP_CACHE_DIR=/Volumes/Storage/Caches/VibeRDP CMAKE=/Volumes/Storage/Caches/VibeRDP/tools/cmake-4.4.3-macos-universal/CMake.app/Contents/bin/cmake core/scripts/build-freerdp.sh
```

Ядро — сборка под все архитектуры, тесты, санитайзеры и универсальная библиотека:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VIBERDP_CACHE_DIR=/Volumes/Storage/Caches/VibeRDP CMAKE=/Volumes/Storage/Caches/VibeRDP/tools/cmake-4.4.3-macos-universal/CMake.app/Contents/bin/cmake core/scripts/build-core.sh
```

Проверки клиента (0.4) и хелпера (0.5) появятся вместе с их кодом.
Перед коммитом — отсутствие атрибуции ассистента в истории, вывод должен быть пустым:

```bash
git log --all --format='%B' | grep -niE "co-authored-by|generated with|anthropic\.com|claude-code"
```

## Окружение

- Xcode 27.0 стоит в `/Applications/Xcode.app`, но `xcode-select` указывает на CommandLineTools: сборку вести с `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, системную настройку не менять
- CMake 4.4.3 лежит в `/Volumes/Storage/Caches/VibeRDP/tools/` и не стоит в `PATH` — скрипту его передаёт переменная `CMAKE`
- Не скачан компонент Metal Toolchain (нужен на 1.2), нет `xcodegen` (0.4) — установка по согласованию с владельцем
- Rust 1.97.1 через rustup, установлен только target `aarch64-apple-darwin`
- Сборочные кэши и скачанные зависимости — в `/Volumes/Storage/Caches/VibeRDP/` (`VIBERDP_CACHE_DIR`), не в репозиторий и не в `~`
- start0 не используется — [docs/decisions.md](docs/decisions.md), раздел 2
