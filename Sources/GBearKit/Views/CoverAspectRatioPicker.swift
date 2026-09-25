import SwiftUI

/// Shared cover-size control for creating and editing emulator profiles.
struct CoverAspectRatioPicker: View {
    @Binding var selection: CoverAspectRatio

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Cover art size", selection: $selection) {
                ForEach(CoverAspectRatio.allCases) { ratio in
                    Text(ratio.pickerLabel).tag(ratio)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                Text("Library tiles crop scraped art to this shape. The image file is not rewritten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.secondary, lineWidth: 1)
                    }
                    .frame(width: previewWidth, height: previewHeight)
                    .help(selection.pickerLabel)
            }
        }
    }

    private var previewWidth: CGFloat {
        let maxW: CGFloat = 36
        let maxH: CGFloat = 48
        let heightAtMaxWidth = selection.height(forWidth: maxW)
        if heightAtMaxWidth <= maxH { return maxW }
        return selection.width(forHeight: maxH)
    }

    private var previewHeight: CGFloat {
        selection.height(forWidth: previewWidth)
    }
}
