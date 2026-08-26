import SwiftUI

struct DiagnosticsView: View {
    @State private var shareFile: ShareFile?

    var body: some View {
        Group {
            Button {
                shareFile = LogExporter.mergedLogFile().map(ShareFile.init)
            } label: {
                Text("Share Logs")
                    .foregroundStyle(.primary)
            }
            Button("Clear Logs", role: .destructive) {
                LogExporter.clearLogs()
            }
        }
        .sheet(item: $shareFile) { file in
            ActivityView(activityItems: [file.url])
        }
    }

    private struct ShareFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    private struct ActivityView: UIViewControllerRepresentable {
        let activityItems: [Any]

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }

        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        }
    }
}

#Preview {
    DiagnosticsView()
}
