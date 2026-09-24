/// Keys of the interface strings: flat and dotted, the same in every language
enum TextKey: String, CaseIterable {
    case menuAppAbout = "menu.app.about"
    case menuAppHide = "menu.app.hide"
    case menuAppHideOthers = "menu.app.hideOthers"
    case menuAppShowAll = "menu.app.showAll"
    case menuAppQuit = "menu.app.quit"
    case menuFile = "menu.file"
    case menuFileClose = "menu.file.close"
    case menuWindow = "menu.window"
    case menuWindowMinimize = "menu.window.minimize"
}

extension TextKey {
    /// Base language, compiled in: the app speaks even without language files
    /// The switch is exhaustive, so a key without its base string does not compile
    var baseText: String {
        switch self {
        case .menuAppAbout: "О программе {app}"
        case .menuAppHide: "Скрыть {app}"
        case .menuAppHideOthers: "Скрыть остальные"
        case .menuAppShowAll: "Показать все"
        case .menuAppQuit: "Завершить {app}"
        case .menuFile: "Файл"
        case .menuFileClose: "Закрыть окно"
        case .menuWindow: "Окно"
        case .menuWindowMinimize: "Свернуть"
        }
    }
}

enum Localization {
    /// The string of a key with its named placeholders filled in
    /// A placeholder without a value stays visible as {name}: a missing value shows up instead of vanishing
    static func text(_ key: TextKey, _ values: [String: String] = [:]) -> String {
        values.reduce(key.baseText) { text, value in
            text.replacingOccurrences(of: "{\(value.key)}", with: value.value)
        }
    }
}
