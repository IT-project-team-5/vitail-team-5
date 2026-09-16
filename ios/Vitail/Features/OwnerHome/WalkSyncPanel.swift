import SwiftUI

struct WalkSyncPanel: View {
    @ObservedObject var sync: WalkSyncStore
    @ObservedObject var history: WalkHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Walking points").font(.headline)
            Text("8 points per km · up to 40 walking points per Melbourne day. Points use server-validated distance, not the live estimate.")
                .font(.footnote).foregroundStyle(AppColors.secondaryText)
            if let message = sync.errorMessage {
                Text(message).font(.footnote).foregroundStyle(AppColors.error)
            }
            Button(sync.isSyncing ? "Syncing…" : "Refresh / Retry Upload") {
                Task { await sync.refreshAndUpload() }
            }
            .disabled(sync.isSyncing)
            ForEach(sync.summaries.filter { receipt in
                !history.records.contains { $0.id == receipt.requestID }
            }.prefix(10)) { walk in
                HStack {
                    VStack(alignment: .leading) {
                        Text(walk.pointDate)
                        Text("Server summary · route not on this device").font(.caption)
                    }
                    Spacer()
                    Text(String(format: "%.2f km · +%d pts", walk.distanceM / 1000, walk.pointsAwarded))
                }
            }
        }
        .padding(.vertical, AppSpacing.small)
    }
}
