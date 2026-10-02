import Observation
import SwiftUI

/// Controller-driven text entry modeled on the PlayStation on-screen keyboard. While it's up,
/// `LibraryControllerNavigator` sends every controller command here instead of to the library.
@MainActor
@Observable
final class OnScreenKeyboard {
    static let shared = OnScreenKeyboard()

    enum Key: Hashable {
        case character(String)
        case shift
        case symbols
        case cursorLeft
        case cursorRight
        case space
        case backspace
        case done

        /// Width in key units; every row adds up to 10.
        var width: Int {
            switch self {
            case .space: return 3
            case .done: return 2
            default: return 1
            }
        }
    }

    private(set) var isPresented = false
    private(set) var title = ""
    private(set) var text = ""
    /// Caret position, in characters.
    private(set) var cursor = 0
    private(set) var shifted = false
    private(set) var showsSymbols = false
    private(set) var focusRow = 1
    private(set) var focusIndex = 0
    /// Column (in key units) kept while moving up / down through rows with wide keys.
    @ObservationIgnored private var preferredUnit = 0
    @ObservationIgnored private var onChange: ((String) -> Void)?
    @ObservationIgnored private var onCommit: ((String) -> Void)?

    private init() {}

    var rows: [[Key]] {
        let characterRows = showsSymbols
            ? ["1234567890", "!@#$%^&*()", "-_=+[]{};:", "/\\|~`\"<>'?"]
            : ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm,.?"]
        return characterRows.map { row in
            row.map { character in
                let key = String(character)
                return .character(shifted && !showsSymbols ? key.uppercased() : key)
            }
        } + [[.shift, .symbols, .cursorLeft, .cursorRight, .space, .backspace, .done]]
    }

    /// `onChange` runs after every edit (for live search); `onCommit` runs once when the keyboard closes.
    func present(
        title: String,
        text: String,
        onChange: ((String) -> Void)? = nil,
        onCommit: @escaping (String) -> Void
    ) {
        self.title = title
        self.text = text
        cursor = text.count
        shifted = false
        showsSymbols = false
        focusRow = 1
        focusIndex = 0
        preferredUnit = 0
        self.onChange = onChange
        self.onCommit = onCommit
        isPresented = true
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        onCommit?(text)
        onChange = nil
        onCommit = nil
    }

    func handle(_ command: LibraryControllerNavigator.Command) {
        switch command {
        case .move(let dx, let dy): moveFocus(dx: dx, dy: dy)
        case .confirm: press(rows[focusRow][focusIndex])
        case .coverSize(let step):
            if step < 0 { press(.backspace) } else { dismiss() }
        case .back: press(.space)
        case .previousGame: press(.cursorLeft)
        case .nextGame: press(.cursorRight)
        case .previousArea: press(.shift)
        case .nextArea, .play: dismiss()
        case .toggleInfo: break
        }
    }

    func press(_ key: Key) {
        switch key {
        case .character(let character):
            insert(character)
            shifted = false
        case .space:
            insert(" ")
        case .backspace:
            guard cursor > 0 else { return }
            text.remove(at: text.index(text.startIndex, offsetBy: cursor - 1))
            cursor -= 1
            onChange?(text)
        case .cursorLeft:
            cursor = max(0, cursor - 1)
        case .cursorRight:
            cursor = min(text.count, cursor + 1)
        case .shift:
            shifted.toggle()
        case .symbols:
            showsSymbols.toggle()
        case .done:
            dismiss()
        }
    }

    func focus(row: Int, index: Int) {
        guard rows.indices.contains(row), rows[row].indices.contains(index) else { return }
        focusRow = row
        focusIndex = index
        preferredUnit = Self.unitRanges(rows[row])[index].lowerBound
    }

    private func insert(_ string: String) {
        text.insert(contentsOf: string, at: text.index(text.startIndex, offsetBy: cursor))
        cursor += string.count
        onChange?(text)
    }

    private func moveFocus(dx: Int, dy: Int) {
        let rows = rows
        if dx != 0 {
            let count = rows[focusRow].count
            focus(row: focusRow, index: (focusIndex + dx + count) % count)
        } else if dy != 0 {
            focusRow = (focusRow + dy + rows.count) % rows.count
            let ranges = Self.unitRanges(rows[focusRow])
            focusIndex = ranges.firstIndex { $0.contains(preferredUnit) } ?? ranges.count - 1
        }
    }

    private static func unitRanges(_ row: [Key]) -> [Range<Int>] {
        var start = 0
        return row.map { key in
            defer { start += key.width }
            return start..<(start + key.width)
        }
    }
}

struct OnScreenKeyboardView: View {
    let keyboard: OnScreenKeyboard

    private static let keyWidth: CGFloat = 46
    private static let keyHeight: CGFloat = 40
    private static let spacing: CGFloat = 6
    private let navigator = LibraryControllerNavigator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(keyboard.title)
                .font(.headline)
            textLine
            VStack(spacing: Self.spacing) {
                ForEach(Array(keyboard.rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: Self.spacing) {
                        ForEach(Array(row.enumerated()), id: \.offset) { keyIndex, key in
                            keyButton(key, row: rowIndex, index: keyIndex)
                        }
                    }
                }
            }
            hints
        }
        .frame(width: Self.keyWidth * 10 + Self.spacing * 9)
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private var textLine: some View {
        let characters = Array(keyboard.text)
        let cursor = min(keyboard.cursor, characters.count)
        return HStack(spacing: 0) {
            Text(String(characters[..<cursor]))
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: 18)
            Text(String(characters[cursor...]))
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .truncationMode(.head)
        .font(.title3)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 1)
        }
    }

    private func keyButton(_ key: OnScreenKeyboard.Key, row: Int, index: Int) -> some View {
        let isFocused = keyboard.focusRow == row && keyboard.focusIndex == index
        let width = Self.keyWidth * CGFloat(key.width) + Self.spacing * CGFloat(key.width - 1)
        return Button {
            keyboard.focus(row: row, index: index)
            keyboard.press(key)
        } label: {
            ZStack(alignment: .topLeading) {
                label(for: key)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let glyph = glyph(for: key) {
                    Image(systemName: glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(3)
                }
            }
            .frame(width: width, height: Self.keyHeight)
            .background(background(for: key), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary, lineWidth: 2.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func label(for key: OnScreenKeyboard.Key) -> some View {
        switch key {
        case .character(let character): Text(character).font(.title3)
        case .shift: Image(systemName: keyboard.shifted ? "shift.fill" : "shift")
        case .symbols: Text(keyboard.showsSymbols ? "abc" : "@#:")
        case .cursorLeft: Image(systemName: "arrowtriangle.left.fill")
        case .cursorRight: Image(systemName: "arrowtriangle.right.fill")
        case .space: Text("Space")
        case .backspace: Image(systemName: "delete.left")
        case .done: Text("Done").fontWeight(.semibold)
        }
    }

    private func background(for key: OnScreenKeyboard.Key) -> AnyShapeStyle {
        switch key {
        case .done: return AnyShapeStyle(Color.accentColor.opacity(0.85))
        case .shift where keyboard.shifted: return AnyShapeStyle(Color.accentColor.opacity(0.4))
        case .symbols where keyboard.showsSymbols: return AnyShapeStyle(Color.accentColor.opacity(0.4))
        default: return AnyShapeStyle(.quaternary)
        }
    }

    private func glyph(for key: OnScreenKeyboard.Key) -> String? {
        switch key {
        case .shift: return navigator.buttonSymbol(.l2)
        case .cursorLeft: return navigator.buttonSymbol(.l1)
        case .cursorRight: return navigator.buttonSymbol(.r1)
        case .space: return navigator.buttonSymbol(.top)
        case .backspace: return navigator.buttonSymbol(.left)
        case .done: return navigator.buttonSymbol(.r2)
        case .character, .symbols: return nil
        }
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint(.bottom, "Enter")
            hint(.right, "Close")
            hint(.top, "Space")
            hint(.left, "Delete")
            hint(.r2, "Done")
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func hint(_ button: LibraryControllerNavigator.ControllerButton, _ title: String) -> some View {
        Label(title, systemImage: navigator.buttonSymbol(button))
            .labelStyle(.titleAndIcon)
    }
}
