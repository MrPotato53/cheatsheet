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
    @AppStorage("dockIconPolicy", store: AppDefaults.store) private var dockIconPolicy = DockIconPolicy.whenSettingsOpen.rawValue
    @State private var pinShortcutWarning: String?
    @Environment(CheatsheetStore.self) private var store
    @AppStorage(OverlayButtonsMode.defaultsKey, store: AppDefaults.store) private var overlayButtonsMode = OverlayButtonsMode.expanded

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
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
            }
            // Coming back from System Settings: pick up an approval made there.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshLoginItemStatus()
            }
            Section {
                Toggle("Dismiss overlay with Escape", isOn: $dismissWithEsc)
                    .accessibilityIdentifier("general.dismissWithEsc")
                Picker("Dock Icon", selection: $dockIconPolicy) {
                    ForEach(DockIconPolicy.allCases) { policy in
                        Text(policy.label).tag(policy.rawValue)
                    }
                }
                .accessibilityIdentifier("general.dockIconPolicy")
                .onChange(of: dockIconPolicy) { _, _ in
                    AppModel.shared.applyDockIconPolicy()
                }
            }
            Section {
                Toggle("Keep cheatsheets in sync with original files", isOn: Binding(
                    get: { store.syncsWithOriginals },
                    set: { isOn in Task { await store.setSyncsWithOriginals(isOn) } }
                ))
                .accessibilityIdentifier("general.syncWithOriginals")
                Text("Cheatsheet always keeps its own copy of each file. When this is on, copies update from your originals, and edits made in an overlay are saved to the original. If Cheatsheet's copy has changes the original doesn't, you're asked before either file is overwritten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Overlay buttons", selection: $overlayButtonsMode) {
                    ForEach(OverlayButtonsMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .accessibilityIdentifier("general.overlayButtonsMode")
                Text("Collapsed modes show a single ☰ button in the overlay instead of every control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Pin/unpin current cheatsheet") {
                    KeyboardShortcuts.Recorder("", name: .togglePin) { shortcut in
                        pinShortcutWarning = SystemShortcuts.conflictWarning(for: shortcut)
                        // Recording re-registers the shortcut unconditionally;
                        // re-apply the only-while-overlay-open gate.
                        AppModel.shared.hotkeys.updatePinShortcutAvailability()
                    }
                }
                if let pinShortcutWarning {
                    Text(pinShortcutWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("general.systemShortcutWarning")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            pinShortcutWarning = SystemShortcuts.conflictWarning(
                for: KeyboardShortcuts.getShortcut(for: .togglePin)
            )
        }
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
