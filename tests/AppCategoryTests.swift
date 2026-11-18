import Foundation
@main struct AppCategoryTests {
    static func main() {
        // The apps this Mac dictates into most, and the scene each had before the table.
        let cases: [(String, String, String, AppCategory, String)] = [
            ("com.openai.codex", "ChatGPT", "", .ai_chat, "development"),
            ("com.baidu.comate.x", "iDev", "", .code_editor, "development"),
            ("com.baidu.hi.mac", "如流", "", .work_chat, "conversation"),
            ("com.tencent.xinWeChat", "微信", "", .chat, "conversation"),
            ("com.apple.Terminal", "Terminal", "", .terminal, "terminal"),
            ("com.apple.mail", "Mail", "", .email, "general"),
            ("com.jetbrains.fleet", "Fleet", "", .code_editor, "development"),
            ("com.example.SomeChat", "", "", .chat, "conversation"),
            ("com.example.notes", "我的笔记", "", .notes, "general"),
            ("com.example.unknown", "Unknown", "", .other, "general"),
        ]
        for (bundle, name, url, category, scene) in cases {
            let found = AppCategory.of(bundle: bundle, name: name, url: url)
            precondition(found == category && found.scene == scene, "\(bundle): \(found) \(found.scene)")
        }
        // A browser takes the page's kind; a path picks among a host's apps.
        let pages: [(String, AppCategory)] = [
            ("https://mail.google.com/mail/u/0/#inbox", .email), ("https://docs.google.com/spreadsheets/d/1", .spreadsheet),
            ("https://docs.google.com/document/d/1/edit", .document), ("https://chatgpt.com/c/1", .ai_chat),
            ("https://app.slack.com/client/T1", .work_chat), ("https://www.zhihu.com/question/1", .social),
            ("https://www.icloud.com/mail/", .email), ("https://www.icloud.com/photos/", .browser),
            ("https://example.com/", .browser), ("about:blank", .browser), ("", .browser),
            ("https://notslack.com/", .browser),
        ]
        for (url, category) in pages {
            let found = AppCategory.of(bundle: "com.google.Chrome", url: url)
            precondition(found == category, "\(url): \(found)")
        }
        precondition(AppCategory.of(bundle: "com.apple.Safari", url: "https://mail.qq.com/") == .email)
        precondition(AppCategory.apps.count >= 150 && AppCategory.pages.count >= 90)
        // Every kind in the table has a title.
        precondition(AppCategory.allCases.allSatisfy { !$0.title.isEmpty })

        let suite = "freetalk-tone-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(DictationTone.chosen(for: .email, in: defaults) == .natural)
        DictationTone.save(.formal, for: .email, in: defaults); DictationTone.save(.casual, for: .chat, in: defaults)
        precondition(DictationTone.chosen(for: .email, in: defaults) == .formal && DictationTone.chosen(for: .chat, in: defaults) == .casual)
        DictationTone.save(.natural, for: .email, in: defaults)
        precondition(DictationTone.chosen(for: .email, in: defaults) == .natural)
        precondition((defaults.dictionary(forKey: "toneByCategory") as? [String: String]) == ["chat": "casual"])
        print("AppCategoryTests passed")
    }
}
