import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.general.info("ZFStatMenus launching...")

        coordinator = AppCoordinator()
        coordinator?.start()

        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
