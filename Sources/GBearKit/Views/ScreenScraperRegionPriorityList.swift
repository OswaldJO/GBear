import SwiftUI

/// Ranked ScreenScraper cover regions with up/down controls (RetroHrai-style).
struct ScreenScraperRegionPriorityList: View {
    @Binding var order: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose which region to prefer when multiple covers are available. The first available region in this list will be used.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(order.enumerated()), id: \.element) { index, code in
                    HStack(spacing: 12) {
                        Text("\(index + 1).")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)
                        Text(ScreenScraperRegionPreference.label(forCode: code))
                            .font(.body)
                        Spacer(minLength: 8)
                        Button {
                            move(index, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("Move up")

                        Button {
                            move(index, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == order.count - 1)
                        .help("Move down")
                    }
                    .padding(.vertical, 8)

                    if index < order.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func move(_ index: Int, by delta: Int) {
        let destination = index + delta
        guard order.indices.contains(index), order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
    }
}
