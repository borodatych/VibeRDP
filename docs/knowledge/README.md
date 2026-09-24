# База знаний

Нетривиальные находки, грабли и проверенные факты — с источниками: URL, путь к исходнику или к заголовку SDK.
Запись без строки в этом индексе не существует: добавили файл — добавьте и строку.

## macos

- [pasteboardPrivacy.md](macos/pasteboardPrivacy.md) — запрос разрешения на программное чтение буфера: `accessBehavior`, методы `detect*`, флаг developer preview; путь Mac → Win под ударом, план проверки на 2.1

## rdp

- [railSession.md](rdp/railSession.md) — RemoteApp заказывается флагом `INFO_RAIL` при подключении: откат RAIL → Seam/Desktop только переподключением, RAIL пробуется лишь при включении в профиле

## windows

- [keyboardLayout.md](windows/keyboardLayout.md) — `ActivateKeyboardLayout` меняет раскладку только своему процессу; чужому окну — `WM_INPUTLANGCHANGEREQUEST` через `DefWindowProc`, приложение вправе отказать
- [windowTracking.md](windows/windowTracking.md) — хуку хелпера нужны `EVENT_OBJECT_CLOAKED` и `EVENT_OBJECT_UNCLOAKED`, иначе скрытые через cloak окна не обновятся у клиента
- [appLocker.md](windows/appLocker.md) — правила AppLocker по умолчанию разрешают exe только из `%windir%` и `%programfiles%`: хелпер из папки пользователя не стартует, страница 8.2 должна это объяснять
