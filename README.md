# VibeRDP

Open-source RDP-клиент для macOS на замену Microsoft Windows App.

> **Версия 1.0:** рабочий стол Windows в окне, во весь экран и на всех мониторах, буфер обмена без фокусов.
> Что умеет — [docs/functional.md](docs/functional.md), сборка — [docs/manuals/devSetup.md](docs/manuals/devSetup.md), план — [docs/roadmap.md](docs/roadmap.md).
> Окна Windows отдельными окнами Мака — в версии 2.0, работа идёт в ветке `feature/windows`.

## Что решает

- **Буфер обмена, который работает.** Скопированное на Маке сразу доступно в Windows — без переключения фокуса туда-обратно: текст, оформление, картинки, файлы и папки
- **Снимок экрана не вешает сессию.** Данные буфера уходят на сервер сжатыми и порциями, мышь и клавиатура не ждут, пока уйдут мегабайты
- **Чёткость на Retina.** Рабочий стол в пикселях экрана Мака с масштабом Windows 200%, или вдвое легче — для медленного канала
- **Все мониторы.** Рабочий стол по окну, развёрнутым окном, во весь экран на одном или всех мониторах, фиксированного размера
- **Всё для работы в домене.** Kerberos, RD Gateway, пароли в связке ключей, импорт `.rdp` и подключений из Windows App
- **Звук, микрофон и папка Мака** в сессии Windows
- **Клавиатура Мака.** ⌘C, ⌘V и привычные сочетания работают в Windows, клавиши настраиваются

## Установка

1. Скачайте `VibeRDP-<версия>.dmg` из [релизов](https://github.com/borodatych/VibeRDP/releases) — одна сборка для Apple Silicon и Intel, macOS 14 и новее
2. Откройте образ и перетащите VibeRDP в «Программы»
3. Первый запуск: сборка подписана без учётной записи Apple Developer, поэтому macOS её не пустит с первого раза
   Откройте «Системные настройки → Конфиденциальность и безопасность» и нажмите «Всё равно открыть» у строки про VibeRDP

## Устройство

| Папка | Что внутри |
|---|---|
| `core/` | `VibeRDPCore` — тонкая C-обёртка над FreeRDP 3.x; в `core/freerdp` — что VibeRDP добавляет к FreeRDP: декодер H.264 на VideoToolbox, сжатие и порционная отправка данных каналов, исправления |
| `client-macos/` | Приложение на Swift: AppKit + Metal, SwiftUI для настроек |
| `helper-win/` | `vibe-seam-helper` на Rust — хелпер режима «Окна Windows», версия 2.0 |
| `protocol/` | Спецификация канала Seam |
| `docs/` | Концепт, план и база знаний — [docs/README.md](docs/README.md) |

## Поддержать проект

Если VibeRDP оказался полезным — буду рад благодарности 🙏

<a href="https://raw.githubusercontent.com/borodatych/VibeRDP/main/media/donate.jpg" target="_blank" rel="noopener noreferrer">
  <img src="https://raw.githubusercontent.com/borodatych/VibeRDP/main/media/donate.jpg" width="120" alt="QR-код для поддержки проекта" />
</a>

## Лицензия

[Apache-2.0](LICENSE)
