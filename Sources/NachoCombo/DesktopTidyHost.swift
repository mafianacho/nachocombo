import AppKit
import ApplicationServices
import NachoComboCore

/// The window side of the desktop tools (NACHO-38): which apps have open windows, and the arrangement itself through the
/// existing Window Snap tool `window_arrange_apps` (checks that gadget's switch and the Accessibility permission, keeps
/// its undo stack). Window titles are never read. Not run on a real Mac.
final class AppDesktopTidyHost: DesktopTidyHost {
    func windowApps(done: @escaping ([String]?) -> Void) {
        DispatchQueue.main.async {
            guard WindowSnapModule.isTrusted(prompt: false) else { return done(nil) }
            var names: [String] = []
            for app in WindowLayoutKeeper.apps() where !WindowLayoutKeeper.windows(of: app).isEmpty {
                if let name = app.localizedName { names.append(name) }
            }
            done(names)
        }
    }

    func arrange(apps: [String], arrangement: String, done: @escaping (PetCommandOutcome) -> Void) {
        guard let tool = GadgetToolRegistry.mcpTool(named: "window_arrange_apps") else {
            return done(PetCommandOutcome(ok: false, message: "window_arrange_apps is not available in this build."))
        }
        GadgetToolDispatcher.shared.run(tool, arguments: ["apps": .array(apps.map { .string($0) }), "arrangement": .string(arrangement)],
                                        exit: .connector, done: done)
    }
}
