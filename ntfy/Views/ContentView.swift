import SwiftUI

struct ContentView: View {
    var body: some View {
        MainView()
    }
}

#Preview {
    let store = Store.preview
    ContentView()
        .environment(\.managedObjectContext, store.context)
        .environmentObject(store)
        .environmentObject(AppIconManager())
        .environment(AppDelegate())
}
