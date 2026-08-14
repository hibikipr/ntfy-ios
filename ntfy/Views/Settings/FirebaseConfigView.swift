import SwiftUI
import UniformTypeIdentifiers
import FirebaseCore

/// Lets the user import their own `GoogleService-Info.plist` so push notifications go through
/// their own Firebase project instead of one bundled with the app. See `FirebaseConfigStore`.
struct FirebaseConfigView: View {
    @State private var showSheet = false
    @State private var showImporter = false
    @State private var showRemoveConfirmation = false
    @State private var summary: FirebaseConfigStore.ConfigSummary?
    @State private var errorMessage: String?

    /// A restart is needed whenever the persisted config and the live `FirebaseApp` state disagree
    /// — covers both "just imported" and "just removed", with no separate persisted flag needed.
    private var status: ConfigStatus {
        let storedConfigured = FirebaseConfigStore.isConfigured
        let liveConfigured = FirebaseApp.app() != nil
        if storedConfigured != liveConfigured {
            return .restartRequired
        }
        return storedConfigured ? .configured : .notConfigured
    }

    var body: some View {
        Button {
            refreshSummary()
            showSheet = true
        } label: {
            HStack {
                Text("Firebase configuration")
                    .foregroundStyle(.primary)
                Spacer()
                Text(status.label)
                    .foregroundStyle(.gray)
            }
            .contentShape(Rectangle())
        }
        .onAppear(perform: refreshSummary)
        .sheet(isPresented: $showSheet) {
            NavigationStack {
                Form {
                    Section(
                        footer: Text("Import your own GoogleService-Info.plist to receive push notifications through your own Firebase project. Your self-hosted ntfy server must also be configured with matching Firebase credentials.")
                    ) {
                        if let summary {
                            LabeledContent("Project", value: summary.projectID ?? "Unknown")
                            if summary.bundleIDMismatch {
                                Label("This file's bundle ID doesn't match this app. Push notifications may not work.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("Not configured")
                                .foregroundStyle(.gray)
                        }

                        Button("Import GoogleService-Info.plist") {
                            showImporter = true
                        }

                        if summary != nil {
                            Button("Remove configuration", role: .destructive) {
                                showRemoveConfirmation = true
                            }
                        }
                    }

                    if status == .restartRequired {
                        Section {
                            Text("Force-quit and reopen the app to apply this change.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .navigationTitle("Firebase Configuration")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showSheet = false
                        }
                    }
                }
                // Attached inside the sheet's content (not on the outer row) so these can present
                // on top of the already-presented sheet — SwiftUI queues a modal triggered by a
                // modifier outside a sheet's hierarchy until that sheet is dismissed.
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.propertyList]) { result in
                    handleImportResult(result)
                }
                .confirmationDialog(
                    "Remove Firebase configuration?",
                    isPresented: $showRemoveConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) {
                        FirebaseConfigStore.removeConfig()
                        refreshSummary()
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .alert(
                    "Import Failed",
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { isPresented in
                            if !isPresented {
                                errorMessage = nil
                            }
                        }
                    )
                ) {
                    Button("OK") { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
            }
        }
    }

    private func refreshSummary() {
        summary = FirebaseConfigStore.currentSummary()
    }

    private func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                summary = try FirebaseConfigStore.importConfig(from: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

private enum ConfigStatus {
    case notConfigured
    case restartRequired
    case configured

    var label: String {
        switch self {
        case .notConfigured:
            return "Not configured"
        case .restartRequired:
            return "Restart required"
        case .configured:
            return "Configured"
        }
    }
}

#Preview {
    Form {
        FirebaseConfigView()
    }
}
