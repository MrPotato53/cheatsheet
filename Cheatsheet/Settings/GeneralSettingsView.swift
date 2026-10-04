import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    /// Mirrors the system's login item state (System Settings → Login Items
    /// is the source of truth; switching it off there shows off here).
    @State private var launchAtLogin = UITestMode.isActive ? false : Self.isLoginItemEnabled
    @State private var launchAtLoginError: String?
    /// Turned on here, but macOS wants it approved in System Settings.
    @State private var loginItemAwaitsApproval = false
    @AppStorage("dismissWithEsc", store: AppDefaults.store) private var dismissWithEsc = true
    @AppStorage(OverlayController.dismissOnClickOutsideKey, store: AppDefaults.store) private var dismissOnClickOutside = false
    @AppStorage("dockIconPolicy", store: AppDefaults.store) private var dockIconPolicy = DockIconPolicy.whenSettingsOpen.rawValue
    @State private var pinShortcutWarning: String?
    @AppStorage(SheetOpenMethod.defaultsKey, store: AppDefaults.store) private var openMethod = SheetOpenMethod.shortcuts
    @State private var searchShortcutWarning: String?
    @AppStorage(LauncherEmptyState.defaultsKey, store: AppDefaults.store) private var launcherEmptyState = LauncherEmptyState.nothing
    @State private var previousSearchShortcut = KeyboardShortcuts.getShortcut(for: .openSearch)
    @Environment(CheatsheetStore.self) private var store
    @AppStorage(OverlayButtonsMode.defaultsKey, store: AppDefaults.store) private var overlayButtonsMode = OverlayButtonsMode.expanded
    @AppStorage(SearchScope.defaultsKey, store: AppDefaults.store) private var searchScope = SearchScope.allPages

    var body: some View {
        Form {
            Section("App") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                    .accessibilityIdentifier("general.launchAtLogin")
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if loginItemAwaitsApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Allow Cheatsheet in System Settings → Login Items to finish turning this on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("general.openLoginItems")
                    }
                }
                Picker("Show in Dock", selection: $dockIconPolicy) {
                    ForEach(DockIconPolicy.allCases) { policy in
                        Text(policy.label).tag(policy.rawValue)
                    }
                }
                .accessibilityIdentifier("general.dockIconPolicy")
                .onChange(of: dockIconPolicy) { _, _ in
                    AppModel.shared.applyDockIconPolicy()
                }
            }
            // Coming back from System Settings: pick up an approval made there.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshLoginItemStatus()
            }

            Section("Opening Cheatsheets") {
                Picker("Open cheatsheets with", selection: $openMethod) {
                    ForEach(SheetOpenMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .accessibilityIdentifier("general.openMethod")
                .onChange(of: openMethod) { _, _ in
                    AppModel.shared.hotkeys.updateOpenMethodAvailability()
                }
                if openMethod == .search {
                    Text("Each cheatsheet's keyboard shortcut is kept, but turned off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if openMethod.usesSearch {
                    LabeledContent("Search bar shortcut") {
                        KeyboardShortcuts.Recorder("", name: .openSearch, onChange: handleSearchShortcutChange)
                    }
                    .accessibilityIdentifier("general.searchShortcut")
                    if let searchShortcutWarning {
                        Text(searchShortcutWarning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("general.searchShortcutWarning")
                    }
                    Picker("Search bar suggestions", selection: $launcherEmptyState) {
                        ForEach(LauncherEmptyState.allCases) { state in
                            Text(state.label).tag(state)
                        }
                    }
                    .accessibilityIdentifier("general.launcherEmptyState")
                    Text("Listed in the search bar before you type.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("While a Cheatsheet Is Open") {
                Picker("Buttons", selection: $overlayButtonsMode) {
                    ForEach(OverlayButtonsMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .accessibilityIdentifier("general.overlayButtonsMode")
                .help("Collapsed buttons are grouped behind ☰ in the cheatsheet's corner")
                Picker("Search", selection: $searchScope) {
                    ForEach(SearchScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .accessibilityIdentifier("general.searchScope")
                .help("Which pages ⌘F finds matches on. Web pages are searched once they've been shown.")
                Toggle("Close with Escape", isOn: $dismissWithEsc)
                    .accessibilityIdentifier("general.dismissWithEsc")
                Toggle("Close when clicking outside it", isOn: $dismissOnClickOutside)
                    .accessibilityIdentifier("general.dismissOnClickOutside")
                LabeledContent("Pin or unpin shortcut") {
                    KeyboardShortcuts.Recorder("", name: .togglePin) { shortcut in
                        pinShortcutWarning = SystemShortcuts.conflictWarning(for: shortcut)
                        // Recording re-registers the shortcut unconditionally;
                        // re-apply the only-while-a-cheatsheet-is-open gate.
                        AppModel.shared.hotkeys.updatePinShortcutAvailability()
                    }
                }
                if let pinShortcutWarning {
                    Text(pinShortcutWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("general.systemShortcutWarning")
                }
                Text("A pinned cheatsheet stays open until you unpin it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Original Files") {
                Toggle("Sync with original files", isOn: Binding(
                    get: { store.syncsWithOriginals },
                    set: { isOn in Task { await store.setSyncsWithOriginals(isOn) } }
                ))
                .accessibilityIdentifier("general.syncWithOriginals")
                Text("Files are copied into the cheatsheet. With sync on, copies follow their originals and edits save back; if both changed, you choose which to keep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            pinShortcutWarning = SystemShortcuts.conflictWarning(
                for: KeyboardShortcuts.getShortcut(for: .togglePin)
            )
            searchShortcutWarning = SystemShortcuts.conflictWarning(
                for: KeyboardShortcuts.getShortcut(for: .openSearch)
            )
        }
    }

    /// Mirrors the per-sheet recorder: a combination another cheatsheet uses
    /// (while its shortcuts are on) is refused and the previous one kept.
    private func handleSearchShortcutChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        if let shortcut, openMethod.usesSheetShortcuts,
           let other = store.conflictingSheet(with: shortcut, excluding: UUID()) {
            KeyboardShortcuts.setShortcut(previousSearchShortcut, for: .openSearch)
            searchShortcutWarning = "\(shortcut) is already used by “\(other.name)”. Kept the previous shortcut."
        } else {
            previousSearchShortcut = shortcut
            searchShortcutWarning = SystemShortcuts.conflictWarning(for: shortcut)
        }
        // Recording re-registers shortcuts unconditionally; re-apply.
        AppModel.shared.hotkeys.updateOpenMethodAvailability()
    }

    private static var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Re-reads the system's state, e.g. after the user changed it in
    /// System Settings. Setting the toggle here doesn't re-register: the
    /// onChange handler skips values that already match the system.
    private func refreshLoginItemStatus() {
        guard !UITestMode.isActive else { return }
        launchAtLogin = Self.isLoginItemEnabled
        // Back from System Settings, approved or not: the toggle now shows
        // the real state, so the "finish in System Settings" hint is done.
        loginItemAwaitsApproval = false
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // UI tests exercise the toggle but must never register the test build
        // as a real login item on the host machine.
        guard !UITestMode.isActive, enabled != Self.isLoginItemEnabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
                loginItemAwaitsApproval = false
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        // Previously switched off in System Settings: macOS won't re-enable
        // it without the user's approval there, so take them to it.
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            loginItemAwaitsApproval = true
            launchAtLoginError = nil
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = Self.isLoginItemEnabled || loginItemAwaitsApproval
    }
}
