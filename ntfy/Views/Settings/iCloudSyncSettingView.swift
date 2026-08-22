import SwiftUI

/// Shows whether topic sync via iCloud is active. There's nothing to configure here — sync is
/// automatic once the user is signed into iCloud — so this is a read-only status row, unlike
/// FirebaseConfigView's import/remove flow.
///
/// Named `ICloudSyncSettingView` (not `iCloudSyncSettingView`) to match this codebase's existing
/// convention of uppercase-leading type names — no other type in this project starts lowercase.
struct ICloudSyncSettingView: View {
    @State private var isSignedIntoiCloud = FileManager.default.ubiquityIdentityToken != nil

    private var statusText: String {
        isSignedIntoiCloud ? "Synced" : "Not signed into iCloud"
    }

    var body: some View {
        HStack {
            Text("Topic Sync")
                .foregroundStyle(.primary)
            Spacer()
            Text(statusText)
                .foregroundStyle(.gray)
        }
        .onAppear {
            isSignedIntoiCloud = FileManager.default.ubiquityIdentityToken != nil
        }
    }
}

#Preview {
    Form {
        ICloudSyncSettingView()
    }
}
