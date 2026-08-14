import Foundation
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        TabView {
            SubscriptionListView()
                .tabItem {
                    Image(systemName: "message.fill")
                    Text("Notifications")
                }
                .badge(store.unreadCount)
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
        }
    }
}

#Preview {
    let store = Store.preview // Store.previewEmpty
    MainView()
        .environment(\.managedObjectContext, store.context)
        .environmentObject(store)
        .environmentObject(AppIconManager())
        .environment(AppDelegate())
}
