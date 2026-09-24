# Правила проекта для агента

Базовые правила — в `CLAUDE.md` в корне (указатель на глобальные) и в `.vibe/rules/viberdp.mdc`.

- **Стек:** ядро `core/` — C поверх FreeRDP 3.x (CMake, universal arm64 + x86_64); клиент `client-macos/` — Swift, AppKit + Metal, SwiftUI для настроек и списка подключений, проект генерирует XcodeGen; хелпер `helper-win/` — Rust + `windows-rs`, target `x86_64-pc-windows-msvc`
- **Проверки:** см. `CLAUDE.md`, раздел «Проверки перед завершением задачи»
- **Комментарии в коде — на английском**, документация и коммиты — на русском
