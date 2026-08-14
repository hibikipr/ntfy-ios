import SwiftUI

struct AppIconPickerView: View {
    private let tag = "AppIconPickerView"

    @EnvironmentObject private var iconManager: AppIconManager
    @State private var showDialog = false

    var body: some View {
        Button(action: { showDialog = true }) {
            HStack {
                Text("App Icon")
                    .foregroundStyle(.primary)
                Spacer()
                Text(iconManager.current.displayName)
                    .foregroundStyle(.gray)
            }
            .contentShape(Rectangle())
        }
        .sheet(isPresented: $showDialog) {
            NavigationStack {
                List {
                    row(for: .classic)
                    row(for: .orange)
                    row(for: .green)
                }
                .navigationTitle("App Icon")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showDialog = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for option: AppIconOption) -> some View {
        Button(action: { selectIcon(option) }) {
            HStack(spacing: 16) {
                Image(option.previewImageName)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(option.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if option == iconManager.current {
                    Image(systemName: "checkmark")
                        .foregroundStyle(option.accentColor)
                }
            }
        }
    }

    private func selectIcon(_ option: AppIconOption) {
        showDialog = false
        iconManager.setIcon(option) { error in
            if let error {
                Log.e(tag, "Failed to set alternate icon to \(option.rawValue)", error)
            }
        }
    }
}

#Preview {
    Form {
        AppIconPickerView()
    }
    .environmentObject(AppIconManager())
}
