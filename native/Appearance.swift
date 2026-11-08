import AppKit

/// Shared native surfaces for the settings cards and the recording panel.
enum VoiceAppearance {
    static func card() -> NSBox {
        let box = NSBox(); box.boxType = .custom; box.titlePosition = .noTitle
        box.cornerRadius = 10; box.borderColor = .separatorColor; box.borderWidth = 0.5
        box.fillColor = .controlBackgroundColor
        return box
    }
    static func form(_ entries: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views:entries.map { [NSTextField(labelWithString:$0.0),$0.1] })
        grid.rowSpacing = 12; grid.columnSpacing = 14
        grid.column(at:0).width = 78; grid.column(at:0).xPlacement = .trailing
        grid.column(at:1).xPlacement = .fill
        for index in entries.indices { grid.row(at:index).yPlacement = .center }
        return grid
    }
}

final class SidebarButton: NSButton {
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:7,yRadius:7).fill()
        }
        super.draw(dirtyRect)
    }
}
