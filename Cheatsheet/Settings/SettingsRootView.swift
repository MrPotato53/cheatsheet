import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            CheatsheetsSettingsView()
                .tabItem { Label("Cheatsheets", systemImage: "rectangle.stack") }
        }
        .frame(minWidth: 700, minHeight: 440)
    }
}
