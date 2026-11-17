import Foundation

/// The kind of app the user dictates into, from its bundle ID or, in a
/// browser, the page's domain. Cleanup uses it as a style hint, applies the
/// tone the user chose for this kind of app, and keeps learned habits per kind.
///
/// Bundle IDs come from the apps on a test Mac, Homebrew cask metadata (the
/// IDs each cask quits or cleans up) and VoiceInk's trigger catalog; nothing
/// in the table was guessed. Unknown apps fall back to name patterns, then to
/// `other`.
enum AppCategory: String, CaseIterable {
    case chat, work_chat, email, document, notes, code_editor, terminal, ai_chat, social, meeting, task, spreadsheet, presentation, design, browser, other

    var title: String {
        switch self {
        case .chat: return "聊天"
        case .work_chat: return "工作沟通"
        case .email: return "邮件"
        case .document: return "文档"
        case .notes: return "笔记"
        case .code_editor: return "代码编辑器"
        case .terminal: return "终端"
        case .ai_chat: return "AI 助手"
        case .social: return "社交与评论"
        case .meeting: return "会议"
        case .task: return "任务与项目"
        case .spreadsheet: return "表格"
        case .presentation: return "演示文稿"
        case .design: return "设计"
        case .browser: return "浏览器（其他网页）"
        case .other: return "其他应用"
        }
    }

    /// The older, coarser scene the cleanup rules use: chats keep tone
    /// particles, code and terminals keep symbols.
    var scene: String {
        switch self {
        case .chat, .work_chat, .social, .meeting: return "conversation"
        case .code_editor, .ai_chat: return "development"
        case .terminal: return "terminal"
        default: return "general"
        }
    }

    /// Plain text only: a terminal, an editor or a prompt box would show HTML list markup as text.
    var plainTextOnly: Bool { [.terminal, .code_editor, .ai_chat].contains(self) }

    /// The categories listed in Settings for choosing a tone.
    static let toneChoices: [AppCategory] = [.chat, .work_chat, .email, .document, .notes, .ai_chat, .social, .task, .browser, .other]

    static let apps: [String: AppCategory] = {
        var table: [String: AppCategory] = [:]
        let groups: [(AppCategory, [String])] = [
            (.chat, ["com.tencent.xinWeChat", "com.tencent.qq", "net.whatsapp.WhatsApp", "org.telegram.desktop", "ru.keepcoder.Telegram",
                     "com.tdesktop.Telegram", "org.whispersystems.signal-desktop", "com.facebook.archon", "com.apple.MobileSMS", "com.viber.osx",
                     "jp.naver.line.mac", "im.riot.app", "com.automattic.beeper.desktop", "com.hnc.Discord", "com.skype.skype",
                     "com.teamspeak.TeamSpeak3"]),
            (.work_chat, ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.alibaba.DingTalkMac",
                          "com.electron.lark", "com.baidu.hi.mac", "com.tencent.WeWorkMac", "Mattermost.Desktop", "chat.rocket",
                          "org.zulip.zulip-electron"]),
            (.email, ["com.apple.mail", "com.microsoft.Outlook", "com.mimestream.Mimestream", "com.readdle.smartemail-Mac",
                      "com.readdle.SparkDesktop", "io.canarymail.mac", "com.emclient.mailclient", "ch.protonmail.protonmail",
                      "com.spikenow.spike", "com.freron.MailMate", "it.bloop.airmail2", "org.mozilla.thunderbird",
                      "com.getmailspring.mailspring", "com.mailspring.mailspring", "com.superhuman.mail", "com.superhuman.electron",
                      "com.missiveapp.desktop", "com.missiveapp.osx", "com.edisonmail.desktop", "com.polymail.mac", "com.tencent.Foxmail",
                      "com.netease.macmail"]),
            (.document, ["com.microsoft.Word", "com.apple.iWork.Pages", "com.kingsoft.wpsoffice.mac", "com.kingsoft.wpsoffice.mac.global",
                         "org.libreoffice.script", "asc.onlyoffice.ONLYOFFICE", "com.apple.TextEdit", "com.literatureandlatte.scrivener3",
                         "com.soulmen.ulysses3", "pro.writer.mac", "abnerworks.Typora", "com.tencent.mac.tdappdesktop", "com.yuque.app",
                         "com.seriflabs.affinitypublisher2"]),
            (.notes, ["com.apple.Notes", "notion.id", "md.obsidian", "net.shinyfrog.bear", "com.lukilabs.lukiapp", "com.lukilabs.lukiapp.Craft",
                      "com.agiletortoise.Drafts-OSX", "com.getupnote.desktop", "com.electron.logseq", "net.cozic.joplin-desktop",
                      "com.evernote.Evernote", "com.yinxiang.Mac", "com.microsoft.onenote.mac", "com.automattic.simplenote", "com.apple.Stickies",
                      "com.apple.journal", "com.youdao.note.YoudaoNoteMac", "QReader.MarginStudy.easy"]),
            (.code_editor, ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium.VSCodiumInsiders", "com.todesktop.230313mzl4w4u92",
                            "com.exafunction.windsurf", "dev.kiro.desktop", "dev.zed.Zed", "com.sublimetext.4", "com.sublimetext.3",
                            "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
                            "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.rider", "com.jetbrains.PhpStorm",
                            "com.jetbrains.rubymine", "com.jetbrains.datagrip", "com.google.android.studio", "com.panic.Nova", "com.barebones.bbedit",
                            "com.macromates.TextMate", "com.coteditor.CotEditor", "com.trae.app", "com.apple.dt.Xcode", "com.baidu.comate.x",
                            "com.github.githubapp"]),
            (.terminal, ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
                         "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby", "com.termius-dmg.mac"]),
            (.ai_chat, ["com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.reclaude.launcher.claude-app",
                        "ai.perplexity.mac", "ai.perplexity.macv3", "ai.elementlabs.lmstudio", "ai.lmstudio.LMStudio", "com.ollama.ollama",
                        "jan.ai.app", "ai.jan", "app.msty.app", "com.msty.app", "com.kangfenmao.CherryStudio", "xyz.chatboxapp.app",
                        "com.bot.pc.doubao", "com.moonshot.kimichat", "com.google.GeminiMacOS", "com.quora.poe.electron", "com.anysphere.sand",
                        "com.microsoft.m365copilot"]),
            (.meeting, ["us.zoom.xos", "com.tencent.meeting", "com.tencent.tencentmeeting", "com.cisco.webex", "com.cisco.webexmeetingsapp",
                        "com.apple.FaceTime", "org.jitsi.jitsi-meet"]),
            (.task, ["com.electron.asana", "com.clickup.desktop-app", "com.omnigroup.OmniFocus4", "com.omnigroup.OmniFocus", "com.TickTick.task.mac",
                     "com.apple.reminders", "com.linear", "com.todoist.mac.Todoist"]),
            (.spreadsheet, ["com.microsoft.Excel", "com.apple.iWork.Numbers"]),
            (.presentation, ["com.microsoft.Powerpoint", "com.apple.iWork.Keynote"]),
            (.design, ["com.figma.Desktop", "com.bohemiancoding.sketch3", "com.canva.CanvaDesktop", "com.framer.electron", "com.electron.realtimeboard",
                       "com.apple.freeform", "net.xmind.vana.app", "org.xmind.cathy.application", "com.seriflabs.affinitydesigner2", "com.canva.affinity"]),
            (.browser, ["com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
                        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.apple.Safari", "com.kagi.kagimacOS", "app.zen-browser.zen"]),
        ]
        for (category, ids) in groups { for id in ids { table[id] = category } }
        return table
    }()

    /// Web pages, by host suffix; a path prefix when the host serves several kinds.
    static let pages: [(host: String, path: String, category: AppCategory)] = [
        ("mail.google.com", "", .email), ("outlook.live.com", "", .email), ("outlook.office.com", "", .email), ("outlook.office365.com", "", .email),
        ("mail.qq.com", "", .email), ("exmail.qq.com", "", .email), ("mail.163.com", "", .email), ("mail.126.com", "", .email),
        ("mail.proton.me", "", .email), ("icloud.com", "/mail", .email), ("app.superhuman.com", "", .email), ("hey.com", "", .email),
        ("fastmail.com", "", .email), ("mail.yahoo.com", "", .email), ("mail.aliyun.com", "", .email), ("qiye.aliyun.com", "", .email),
        ("docs.google.com", "/document", .document), ("docs.google.com", "/spreadsheets", .spreadsheet), ("docs.google.com", "/presentation", .presentation),
        ("docs.google.com", "/forms", .document), ("docs.qq.com", "/sheet", .spreadsheet), ("docs.qq.com", "/slide", .presentation), ("docs.qq.com", "", .document),
        ("feishu.cn", "/sheets", .spreadsheet), ("feishu.cn", "/base", .spreadsheet), ("feishu.cn", "/slides", .presentation), ("feishu.cn", "/wiki", .document),
        ("feishu.cn", "/docx", .document), ("feishu.cn", "/docs", .document), ("larksuite.com", "/docx", .document), ("larksuite.com", "/wiki", .document),
        ("larksuite.com", "/sheets", .spreadsheet), ("yuque.com", "", .document), ("shimo.im", "", .document), ("kdocs.cn", "", .document),
        ("office.com", "", .document), ("onedrive.live.com", "", .document), ("sharepoint.com", "", .document), ("dropbox.com", "/paper", .document),
        ("notion.so", "", .notes), ("notion.site", "", .notes), ("craft.do", "", .notes), ("evernote.com", "", .notes), ("flowus.cn", "", .notes),
        ("chatgpt.com", "", .ai_chat), ("chat.openai.com", "", .ai_chat), ("claude.ai", "", .ai_chat), ("gemini.google.com", "", .ai_chat),
        ("perplexity.ai", "", .ai_chat), ("copilot.microsoft.com", "", .ai_chat), ("grok.com", "", .ai_chat), ("kimi.moonshot.cn", "", .ai_chat),
        ("kimi.com", "", .ai_chat), ("doubao.com", "", .ai_chat), ("chat.deepseek.com", "", .ai_chat), ("yiyan.baidu.com", "", .ai_chat),
        ("tongyi.aliyun.com", "", .ai_chat), ("chatglm.cn", "", .ai_chat), ("yuanbao.tencent.com", "", .ai_chat), ("poe.com", "", .ai_chat),
        ("aistudio.google.com", "", .ai_chat),
        ("slack.com", "", .work_chat), ("teams.microsoft.com", "", .work_chat), ("teams.live.com", "", .work_chat), ("chat.google.com", "", .work_chat),
        ("discord.com", "", .chat), ("web.whatsapp.com", "", .chat), ("web.telegram.org", "", .chat), ("messenger.com", "", .chat),
        ("messages.google.com", "", .chat), ("app.element.io", "", .chat), ("web.wechat.com", "", .chat), ("wx.qq.com", "", .chat),
        ("x.com", "", .social), ("twitter.com", "", .social), ("weibo.com", "", .social), ("zhihu.com", "", .social), ("xiaohongshu.com", "", .social),
        ("douban.com", "", .social), ("linkedin.com", "", .social), ("reddit.com", "", .social), ("facebook.com", "", .social),
        ("instagram.com", "", .social), ("threads.net", "", .social), ("bilibili.com", "", .social), ("youtube.com", "", .social),
        ("v2ex.com", "", .social), ("juejin.cn", "", .social), ("news.ycombinator.com", "", .social),
        ("github.com", "", .task), ("gitlab.com", "", .task), ("atlassian.net", "", .task), ("linear.app", "", .task), ("trello.com", "", .task),
        ("asana.com", "", .task), ("app.clickup.com", "", .task), ("teambition.com", "", .task), ("tapd.cn", "", .task), ("coding.net", "", .task),
        ("figma.com", "", .design), ("canva.com", "", .design), ("miro.com", "", .design),
        ("meet.google.com", "", .meeting), ("zoom.us", "", .meeting), ("meeting.tencent.com", "", .meeting),
    ]

    /// The category for an app, given its bundle ID, its name and, for a browser, the page URL.
    static func of(bundle: String, name: String = "", url: String = "") -> AppCategory {
        if let known = apps[bundle] {
            guard known == .browser else { return known }
            return page(url) ?? .browser
        }
        // Unknown apps: a family that shares a prefix, then words in the ID or the name.
        let id = bundle.lowercased()
        if id.hasPrefix("com.jetbrains.") { return .code_editor }
        if ["terminal", "iterm"].contains(where: id.contains) { return .terminal }
        if ["vscode", "xcode", "cursor", "comate", "codex"].contains(where: id.contains) { return .code_editor }
        if ["gpt", "doubao", "kimi"].contains(where: id.contains) { return .ai_chat }
        if ["chat", "wechat", "hi.mac", "telegram", "whatsapp", "messenger"].contains(where: id.contains) { return .chat }
        if id.contains("mail") { return .email }
        let lower = name.lowercased()
        if ["邮件", "邮箱", "mail"].contains(where: lower.contains) { return .email }
        if ["笔记", "note"].contains(where: lower.contains) { return .notes }
        return .other
    }

    static func page(_ url: String) -> AppCategory? {
        guard let parts = URLComponents(string: url), let host = parts.host?.lowercased() else { return nil }
        let path = parts.path
        for row in pages where host == row.host || host.hasSuffix("." + row.host) {
            if row.path.isEmpty || path.hasPrefix(row.path) { return row.category }
        }
        return nil
    }
}

/// How cleanup writes for a kind of app. 自然 changes nothing; 正式 drops chatty
/// particles (呀、啦、哈、呗) and makes sure the text ends with a full stop; 口语
/// keeps the particles and drops the full stop that ends a one-line message.
enum DictationTone: String, CaseIterable {
    case natural, formal, casual
    var title: String {
        switch self {
        case .natural: return "自然（默认）"
        case .formal: return "正式"
        case .casual: return "口语"
        }
    }
    static func chosen(for category: AppCategory, in defaults: UserDefaults = .standard) -> DictationTone {
        let saved = (defaults.dictionary(forKey: "toneByCategory") as? [String: String])?[category.rawValue]
        return saved.flatMap(DictationTone.init(rawValue:)) ?? .natural
    }
    static func save(_ tone: DictationTone, for category: AppCategory, in defaults: UserDefaults = .standard) {
        var saved = (defaults.dictionary(forKey: "toneByCategory") as? [String: String]) ?? [:]
        saved[category.rawValue] = tone == .natural ? nil : tone.rawValue
        defaults.set(saved, forKey: "toneByCategory")
    }
}
