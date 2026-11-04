import AppKit

/// Shared native surfaces for the settings cards and the recording panel.
enum VoiceAppearance {
    static func card() -> NSBox {
        let box = NSBox(); box.boxType = .custom; box.titlePosition = .noTitle
        box.cornerRadius = 12; box.borderColor = .separatorColor; box.borderWidth = 0.5
        box.fillColor = .controlBackgroundColor
        return box
    }
}
