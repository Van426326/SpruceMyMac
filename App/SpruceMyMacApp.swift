// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

@main
struct SpruceMyMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppView(model: model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsView()
        }
    }
}
