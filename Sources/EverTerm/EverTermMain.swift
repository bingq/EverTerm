import AppKit

/// App entry point. Marked @MainActor so the (main-actor) AppDelegate can be
/// created here; a top-level main.swift is treated as nonisolated.
@main
@MainActor
enum EverTermMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate            // NSApplication holds its delegate weakly
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
