import Foundation

@MainActor
final class AppModel {
    static let shared = AppModel()

    let store: CheatsheetStore
    let overlay: OverlayController
    let hotkeys: HotkeyManager

    private init() {
        let store = CheatsheetStore()
        let overlay = OverlayController(store: store)
        let hotkeys = HotkeyManager(store: store, overlay: overlay)
        self.store = store
        self.overlay = overlay
        self.hotkeys = hotkeys
        store.onChange = { [weak hotkeys, weak overlay] in
            hotkeys?.sync()
            overlay?.refreshFromStore()
        }
        hotkeys.sync()
    }
}
