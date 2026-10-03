import SwiftUI

@main
struct MultiDisplayApp: App {
    @StateObject private var store = DisplayStore()

    var body: some Scene {
        MenuBarExtra("Multi Display", systemImage: "display.2") {
            MainView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}
