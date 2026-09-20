import AppKit

// A menu-bar utility: no Dock icon, no app menu bar. `LSUIElement` in
// Info.plist says the same for the bundled app; setting the policy here also
// covers `swift run` during development.
// A pipe to a helper process that exited early must produce an error, not
// kill the app.
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
