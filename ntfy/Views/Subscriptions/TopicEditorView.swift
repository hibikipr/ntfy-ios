import SwiftUI

struct TopicEditorView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var subscription: Subscription
    @State private var iconText: String
    @State private var displayNameText: String

    init(subscription: Subscription) {
        self.subscription = subscription
        _iconText = State(initialValue: subscription.icon ?? "")
        _displayNameText = State(initialValue: subscription.customDisplayName ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TopicAvatarView(name: subscription.topicName(), emoji: iconText.isEmpty ? nil : iconText)
                    .scaleEffect(2)
                    .padding(.top, 24)

                VStack(spacing: 8) {
                    TextField("Emoji", text: $iconText)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 32))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: iconText) { _, newValue in
                            if let last = newValue.last {
                                iconText = String(last)
                            }
                            store.saveIcon(for: subscription, icon: iconText)
                        }

                    Text("Tap the field, then tap the globe/emoji key on the keyboard to pick one.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Divider()
                    .padding(.horizontal, 32)

                VStack(spacing: 8) {
                    Text("Display Name")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    TextField(subscription.displayName(), text: $displayNameText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 220)
                    Text("Leave empty to show the default topic name.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                if !iconText.isEmpty {
                    Button(role: .destructive) {
                        iconText = ""
                        store.saveIcon(for: subscription, icon: nil)
                    } label: {
                        Text("Remove Emoji")
                    }
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle(subscription.topicName())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.saveDisplayName(for: subscription, name: displayNameText)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TopicEditorView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview
        let subscription = store.makeSubscription(store.context, "stats", Store.sampleMessages["stats"]!)
        TopicEditorView(subscription: subscription)
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
    }
}
