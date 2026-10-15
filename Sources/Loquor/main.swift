import AppKit

// Menu-bar only app (LSUIElement in Info.plist): no Dock icon, no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
