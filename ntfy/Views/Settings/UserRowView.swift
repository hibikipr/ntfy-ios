//
//  UserRowView.swift
//  ntfy
//
//  Created by Alek Michelson on 4/10/26.
//

import SwiftUI

struct UserRowView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var user: User
    
    var body: some View {
        // TODO: swipe to delete action
        // I tried to add a swipe action here to delete, but for some strange reason it doesn't work,
        // even though in the subscription list it does.
        
        HStack {
            Image(systemName: "person.fill")
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(user.username ?? "?")
                    Text(user.baseUrl ?? "?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.forward")
                .font(.system(size: 12.0))
                .foregroundStyle(.secondary)
        }
        .padding(.all, 4)
    }
}

#Preview {
    let store = Store.previewEmpty
    let user = User(context: store.context)
    user.baseUrl = "https://ntfy.sh"
    user.username = "phil"
    user.password = "phil12"

    return List {
        UserRowView(user: user)
    }
    .environment(\.managedObjectContext, store.context)
    .environmentObject(store)
}
