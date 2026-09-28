import SwiftUI

/// Grid of ScreenScraper search hits (cover + console + title).
struct ScreenScraperMatchGrid: View {
    let candidates: [ScreenScraperGameMatch]
    let onSelect: (ScreenScraperGameMatch) -> Void

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(candidates) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    candidateCard(candidate)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func candidateCard(_ candidate: ScreenScraperGameMatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedCoverThumbnail(urlString: candidate.coverURL?.absoluteString, contentMode: .fit)
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180)
                .clipped()
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            Text(candidate.systemName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(candidate.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}
