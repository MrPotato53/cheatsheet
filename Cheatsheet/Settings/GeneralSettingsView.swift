import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @AppStorage("dismissWithEsc") private var dismissWithEsc = true
    @AppStorage("dockIconPolicy") private var dockIconPolicy = DockIconPolicy.whenSettingsOpen.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Dismiss overlay with Escape", isOn: $dismissWithEsc)
                Picker("Dock Icon", selection: $dockIconPolicy) {
                    ForEach(DockIconPolicy.allCases) { policy in
                        Text(policy.label).tag(policy.rawValue)
                    }
                }
                .onChange(of: dockIconPolicy) { _, _ in
                    AppModel.shared.applyDockIconPolicy()
                }
            }
            Section {
                LabeledContent("Pin/unpin current cheatsheet") {
                    KeyboardShortcuts.Recorder("", name: .togglePin)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }
}
