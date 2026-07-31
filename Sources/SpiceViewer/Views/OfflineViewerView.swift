import SwiftSpice
import SwiftUI

struct OfflineViewerView: View {
    let store: ViewerStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(store.presentationPath)
                Text(String(format: "%.1f fps", store.submittedFPS))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("640 × 360 BGRA")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.bar)

            SpiceDesktopView(frame: store.frame) { _ in }
                .background(.black)
        }
    }
}
