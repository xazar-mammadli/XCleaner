import AppKit

/// macOS has no Azerbaijani, so the menus AppKit and SwiftUI build stay in English when XCleaner speaks it. This puts
/// Azerbaijani titles on them, and keeps them there as the menus change. macOS translates its own menus into the other
/// languages XCleaner speaks, so it only runs in Azerbaijani.
final class MenuTranslator: NSObject {
    static let shared = MenuTranslator()

    /// Azerbaijani titles for the items macOS puts in the menu bar, by their English titles.
    private static let azerbaijani: [String: String] = [
        // The app menu
        "About XCleaner": "XCleaner haqqında",
        "Settings…": "Ayarlar…",
        "Services": "Xidmətlər",
        "Hide XCleaner": "XCleaner-i gizlət",
        "Hide Others": "Digərlərini gizlət",
        "Show All": "Hamısını göstər",
        "Quit XCleaner": "XCleaner-dən çıx",
        "Quit and Keep Windows": "Çıx və pəncərələri saxla",
        // Edit
        "Edit": "Redaktə",
        "Undo": "Geri al",
        "Redo": "Təkrar et",
        "Cut": "Kəs",
        "Copy": "Kopyala",
        "Paste": "Yapışdır",
        "Paste and Match Style": "Yapışdır və üslubu uyğunlaşdır",
        "Delete": "Sil",
        "Select All": "Hamısını seç",
        "Find": "Axtar",
        "Writing Tools": "Yazı alətləri",
        "Show Writing Tools": "Yazı alətlərini göstər",
        "Proofread": "Səhvləri yoxla",
        "Rewrite": "Yenidən yaz",
        "Make Friendly": "Səmimi et",
        "Make Professional": "Peşəkar et",
        "Make Concise": "Qısalt",
        "Summarize": "Xülasə et",
        "Create Key Points": "Əsas məqamları çıxar",
        "Make List": "Siyahıya çevir",
        "Make Table": "Cədvələ çevir",
        "Compose…": "Mətn yaz…",
        "AutoFill": "Avtomatik doldurma",
        "Contact…": "Kontakt…",
        "Passwords…": "Parollar…",
        "Credit Card…": "Kredit kartı…",
        "Start Dictation…": "Diktəyə başla…",
        "Emoji & Symbols": "Emoji və simvollar",
        // View
        "View": "Görünüş",
        "Enter Full Screen": "Tam ekrana keç",
        "Exit Full Screen": "Tam ekrandan çıx",
        // Window
        "Window": "Pəncərə",
        "Close": "Bağla",
        "Close All": "Hamısını bağla",
        "Minimize": "Kiçilt",
        "Minimize All": "Hamısını kiçilt",
        "Zoom": "Böyüt",
        "Zoom All": "Hamısını böyüt",
        "Fill": "Ekranı doldur",
        "Center": "Mərkəzə gətir",
        "Move & Resize": "Yerini və ölçüsünü dəyiş",
        "Halves": "Yarılar",
        "Left": "Sol",
        "Right": "Sağ",
        "Top": "Yuxarı",
        "Bottom": "Aşağı",
        "Quarters": "Dörddəbirlər",
        "Top Left": "Yuxarı sol",
        "Top Right": "Yuxarı sağ",
        "Bottom Left": "Aşağı sol",
        "Bottom Right": "Aşağı sağ",
        "Arrange": "Düz",
        "Left & Right": "Sol və sağ",
        "Left & Quarters": "Sol və dörddəbirlər",
        "Right & Left": "Sağ və sol",
        "Right & Quarters": "Sağ və dörddəbirlər",
        "Top & Bottom": "Yuxarı və aşağı",
        "Top & Quarters": "Yuxarı və dörddəbirlər",
        "Bottom & Top": "Aşağı və yuxarı",
        "Bottom & Quarters": "Aşağı və dörddəbirlər",
        "Return to Previous Size": "Əvvəlki ölçüyə qaytar",
        "Full Screen Tile": "Tam ekranda yan-yana",
        "Left of Screen": "Ekranın solunda",
        "Right of Screen": "Ekranın sağında",
        "Remove Window from Set": "Pəncərəni dəstdən çıxar",
        "Bring All to Front": "Hamısını önə gətir",
        "Arrange in Front": "Önə düz",
        // Help
        "Help": "Kömək",
    ]

    /// Set while titles are being changed here, so the notifications that causes are let through.
    private var isTranslating = false
    private var isCheckScheduled = false

    func start() {
        guard Bundle.main.preferredLocalizations.first == "az" else { return }
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged(_:)), name: name, object: nil)
        }
        translateMenuBar()
    }

    @objc private func menuChanged(_ notification: Notification) {
        guard !isTranslating, let menu = notification.object as? NSMenu else { return }
        // SwiftUI sets its items' titles again each time a menu opens, and AppKit retitles some, such as Enter Full
        // Screen. Each is translated right away, before the menu shows.
        if let index = notification.userInfo?["NSMenuItemIndex"] as? Int, index < menu.numberOfItems, isInMenuBar(menu) {
            translate(menu.items[index])
        }
        // A menu SwiftUI builds anew only reaches the menu bar afterwards, so the whole bar is checked once it has.
        guard !isCheckScheduled else { return }
        isCheckScheduled = true
        Task { @MainActor in
            isCheckScheduled = false
            translateMenuBar()
        }
    }

    private func translateMenuBar() {
        guard let menuBar = NSApp.mainMenu else { return }
        menuBar.items.forEach(translate)
        hideEmptyViewMenu(in: menuBar)
    }

    /// Once its title is translated, AppKit no longer finds the View menu and puts Enter Full Screen in the Window menu,
    /// which leaves View empty. It is hidden rather than opening onto nothing.
    private func hideEmptyViewMenu(in menuBar: NSMenu) {
        guard let view = menuBar.items.first(where: { $0.submenu?.title == Self.azerbaijani["View"] }),
              let isEmpty = view.submenu?.items.allSatisfy(\.isHidden), view.isHidden != isEmpty
        else { return }
        let wasTranslating = isTranslating
        isTranslating = true
        defer { isTranslating = wasTranslating }
        view.isHidden = isEmpty
    }

    private func translate(_ item: NSMenuItem) {
        let wasTranslating = isTranslating
        isTranslating = true
        defer { isTranslating = wasTranslating }
        if let title = Self.azerbaijani[item.title] {
            item.title = title
        }
        if let submenu = item.submenu {
            if let title = Self.azerbaijani[submenu.title] {
                submenu.title = title
            }
            submenu.items.forEach(translate)
        }
    }

    private func isInMenuBar(_ menu: NSMenu) -> Bool {
        var current: NSMenu? = menu
        while let menu = current {
            if menu === NSApp.mainMenu { return true }
            current = menu.supermenu
        }
        return false
    }
}
