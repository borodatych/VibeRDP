# Windows: сборка хелпера

Сверено 2026-09-24 на Mac с тулчейном Rust 1.97.1.

## Один exe без зависимостей

**Суть:** MSVC-таргеты Rust по умолчанию линкуют C-рантайм динамически, так что exe требует Visual C++ Redistributable на хосте; `-C target-feature=+crt-static` линкует рантайм внутрь.

**Применение:** `helper-win/.cargo/config.toml` включает `+crt-static` для `x86_64-pc-windows-msvc` — хелпер ставится копированием одного файла, как требует спецификация.

**Источники:**
- https://doc.rust-lang.org/reference/linkage.html

## Что можно проверить на Маке

**Суть:**
- У тулчейна `1.97.1` на машине разработки уже установлен `rust-std-x86_64-pc-windows-msvc`; `helper-win/rust-toolchain.toml` закрепляет именно этот тулчейн, поэтому проверки ничего не скачивают
- `cargo check` и `cargo clippy` с `--target x86_64-pc-windows-msvc` работают без линкера и проверяют код так, как его увидит Windows
- `cargo build` под этот таргет падает на `linker link.exe not found`: exe собирается только на Windows, то есть в CI

**Применение:** локальные проверки хелпера — rustfmt, clippy под хост и под Windows-таргет; сборку exe и его проверку делает CI (задача 0.6).
