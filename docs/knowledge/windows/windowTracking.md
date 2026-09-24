# Windows: трекинг окон хелпером

## Хуку нужны cloak-события

**Контекст:** фильтр и список событий хелпера в [idea.md](../../idea.md) §3.3; задача 4.3.

**Суть:**
- `EVENT_OBJECT_CLOAKED` (0x8017) приходит, когда окно скрыто через cloak, `EVENT_OBJECT_UNCLOAKED` (0x8018) — когда возвращено; cloaked-окно продолжает существовать, но пользователю невидимо
- `DwmGetWindowAttribute(DWMWA_CLOAKED)` отдаёт причину: `DWM_CLOAKED_APP` — скрыло само приложение, `DWM_CLOAKED_SHELL` — оболочка, `DWM_CLOAKED_INHERITED` — унаследовано от окна-владельца
- `DWMWA_EXTENDED_FRAME_BOUNDS` отдаёт прямоугольник расширенной рамки окна в экранных координатах

**Применение:**
- Фильтр §3.3 отсекает cloaked-окна по `DWMWA_CLOAKED`, но в списке событий `SetWinEventHook` из §3.3 нет `EVENT_OBJECT_CLOAKED` и `EVENT_OBJECT_UNCLOAKED`
- Без них окно, которое скрыли или вернули через cloak, не обновится у клиента: на Маке останется лишнее окно или не появится нужное
- На 4.3 добавить оба события в хук и перепроверять фильтр по каждому из них

**Источники:**
- https://learn.microsoft.com/en-us/windows/win32/winauto/event-constants
- https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
