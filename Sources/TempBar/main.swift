import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Без иконки в Dock — только значок в статусбаре.
app.setActivationPolicy(.accessory)
app.run()
