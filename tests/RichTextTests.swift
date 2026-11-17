import AppKit

@main struct RichTextTests {
    static func main() {
        // A numbered list becomes <ol>; the sentence before it a paragraph.
        let list = RichText.html("这次要做三件事：\n1. 补齐单测\n2. 修掉内存泄漏\n3. 更新文档")
        precondition(list == "<meta charset=\"utf-8\"><p>这次要做三件事：</p><ol><li>补齐单测</li><li>修掉内存泄漏</li><li>更新文档</li></ol>", list ?? "nil")
        // A list that continues from 4 keeps its numbers; markup in the text is escaped.
        let later = RichText.html("4. 用 <b> & \"引号\"\n5. 收尾")
        precondition(later == "<meta charset=\"utf-8\"><ol start=\"4\"><li>用 &lt;b&gt; &amp; &quot;引号&quot;</li><li>收尾</li></ol>", later ?? "nil")
        // Paragraphs separated by a blank line.
        let paragraphs = RichText.html("第一段。\n\n第二段。")
        precondition(paragraphs == "<meta charset=\"utf-8\"><p>第一段。</p><p>第二段。</p>", paragraphs ?? "nil")
        // Plain dictation, or lines without structure, stays plain text only.
        for plain in ["保存文件。", "第一行\n第二行", "1.5 倍速度"] { precondition(RichText.html(plain) == nil, plain) }
        // A rich editor draws the numbers itself; the check looks for the item text.
        precondition(RichText.visibleLines("要做：\n1. 补齐单测\n\n2. 更新文档") == ["要做：", "补齐单测", "更新文档"])
        precondition(InsertionCheck.showsLines(["要做：", "补齐单测", "更新文档"], in: "旧内容要做：\n补齐单测\n更新文档", before: "旧内容"))
        precondition(!InsertionCheck.showsLines(["要做：", "补齐单测", "更新文档"], in: "旧内容要做：\n更新文档", before: "旧内容"))
        precondition(!InsertionCheck.showsLines(["补齐单测"], in: "补齐单测", before: "补齐单测"))

        // Window text recognition reads Chinese and English from an image.
        let size = NSSize(width: 520, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        ("夏普比率 1.8 最大回撤 12%" as NSString).draw(at: NSPoint(x: 20, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 28)])
        ("freetalk window text" as NSString).draw(at: NSPoint(x: 20, y: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { fatalError("no image") }
        let text = WindowText.read(cgImage)
        precondition(text.contains("夏普比率") && text.contains("freetalk"), text)
        precondition(text.components(separatedBy: "\n").first?.contains("夏普") == true, "top line first: \(text)")
        precondition(!WindowText.allowed(bundle: "com.1password.1password") && WindowText.allowed(bundle: "com.tencent.xinWeChat"))
        // A window is captured at its own pixel scale, capped at 2600 pixels on its long side.
        let external = WindowText.captureSize(CGRect(x: 0, y: 0, width: 673, height: 439), pixelScale: 1)
        let retina = WindowText.captureSize(CGRect(x: 0, y: 0, width: 673, height: 439), pixelScale: 2)
        let wide = WindowText.captureSize(CGRect(x: 0, y: 0, width: 3000, height: 1600), pixelScale: 2)
        precondition(external == (673, 439) && retina == (1346, 878) && wide.width == 2600 && wide.height == 1386, "\(external) \(retina) \(wide)")
        print("Rich text passed: numbered lists, paragraphs, escaping, plain text untouched, tolerant check; window text recognition read Chinese and English")
    }
}
