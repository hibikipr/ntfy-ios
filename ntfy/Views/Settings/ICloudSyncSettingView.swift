import SwiftUI

/// Shows whether topic sync via iCloud is active. There's nothing to configure here — sync is
/// automatic once the user is signed into iCloud — so this is a read-only status row, unlike
/// FirebaseConfigView's import/remove flow.
///
/// The status comes from `TopicSyncStore.syncStatus`, not just from `ubiquityIdentityToken`:
/// being signed into iCloud says nothing about whether the mirrored Core Data store actually
/// loaded, and reporting "Synced" while mirroring is broken is exactly the failure mode that
/// hid the CloudKit-incompatible model bug.
///
/// Named `ICloudSyncSettingView` (not `iCloudSyncSettingView`) to match this codebase's existing
/// convention of uppercase-leading type names — no other type in this project starts lowercase.
struct ICloudSyncSettingView: View {
    @State private var status: TopicSyncStore.SyncStatus = .notSignedIn

    private var statusText: String {
        switch status {
        case .notSignedIn: return "Not signed into iCloud"
        case .signedInButNotSyncing: return "Not syncing"
        case .synced: return "Synced"
        }
    }

    var body: some View {
        HStack {
            Text("Topic Sync")
                .foregroundStyle(.primary)
            Spacer()
            Text(statusText)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: TopicSyncStore.accountChangedNotification)) { _ in
            refreshStatus()
        }
    }

    private func refreshStatus() {
        status = TopicSyncStore.shared.syncStatus
    }
}

#Preview {
    Form {
        ICloudSyncSettingView()
    }
}
