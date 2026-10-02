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

        var isCharacter: Bool {
            if case .character = self { return true }
            return false
        }

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

    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 2
    static let scaleStep: CGFloat = 0.1
    /// Gap between the keyboard's resting spot and the bottom of the window.
    static let bottomInset: CGFloat = 28
    private static let edgeMargin: CGFloat = 8
    private static let scaleKey = "Controller.Keyboard.Scale"
    private static let offsetXKey = "Controller.Keyboard.OffsetX"
    private static let offsetYKey = "Controller.Keyboard.OffsetY"

    /// Size multiplier from L3 / R3; 1 is the smallest.
    private(set) var scale: CGFloat
    /// Right-stick offset from the resting spot (bottom center), before clamping to the window.
    private(set) var offset: CGSize
    /// Reported by the view so moves and growth stay inside the window.
    var containerSize: CGSize = .zero
    var panelSize: CGSize = .zero

    private init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Self.scaleKey)
        scale = stored > 0 ? min(max(stored, Self.minScale), Self.maxScale) : Self.minScale
        offset = CGSize(width: defaults.double(forKey: Self.offsetXKey), height: defaults.double(forKey: Self.offsetYKey))
    }

    /// `offset` limited so the whole panel stays on screen, even after the window shrinks.
    var displayedOffset: CGSize {
        clamped(offset)
    }

    func move(by delta: CGSize) {
        offset = clamped(CGSize(width: offset.width + delta.width, height: offset.height + delta.height))
    }

    func resize(by step: Int) {
        let natural = CGSize(width: panelSize.width / scale, height: panelSize.height / scale)
        var largest = Self.maxScale
        if natural.width > 0, natural.height > 0 {
            let fits = min(
                (containerSize.width - Self.edgeMargin * 2) / natural.width,
                (containerSize.height - Self.edgeMargin * 2) / natural.height
            )
            largest = min(largest, max(Self.minScale, fits))
        }
        let steps = ((scale + Self.scaleStep * CGFloat(step)) / Self.scaleStep).rounded()
        scale = min(max(steps * Self.scaleStep, Self.minScale), largest)
        UserDefaults.standard.set(Double(scale), forKey: Self.scaleKey)
    }

    private func clamped(_ offset: CGSize) -> CGSize {
        guard containerSize != .zero, panelSize != .zero else { return offset }
        let sideSlack = max(0, (containerSize.width - panelSize.width) / 2 - Self.edgeMargin)
        let topSlack = max(0, containerSize.height - panelSize.height - Self.bottomInset - Self.edgeMargin)
        let bottomSlack = max(0, Self.bottomInset - Self.edgeMargin)
        return CGSize(
            width: min(max(offset.width, -sideSlack), sideSlack),
            height: min(max(offset.height, -topSlack), bottomSlack)
        )
    }

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
        offset = displayedOffset
        UserDefaults.standard.set(Double(offset.width), forKey: Self.offsetXKey)
        UserDefaults.standard.set(Double(offset.height), forKey: Self.offsetYKey)
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
        case .resizeKeyboard(let step): resize(by: step)
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

    private let navigator = LibraryControllerNavigator.shared

    /// Every size is drawn at the keyboard's scale (rather than `scaleEffect`) so text stays sharp.
    private var s: CGFloat { keyboard.scale }
    private var keyWidth: CGFloat { 46 * s }
    private var keyHeight: CGFloat { 40 * s }
    private var spacing: CGFloat { 6 * s }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * s) {
            Text(keyboard.title)
                .font(.system(size: 13 * s, weight: .semibold))
            textLine
            VStack(spacing: spacing) {
                ForEach(Array(keyboard.rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: spacing) {
                        ForEach(Array(row.enumerated()), id: \.offset) { keyIndex, key in
                            keyButton(key, row: rowIndex, index: keyIndex)
                        }
                    }
                }
            }
            hints
        }
        .frame(width: keyWidth * 10 + spacing * 9)
        .padding(16 * s)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14 * s))
        .overlay {
            RoundedRectangle(cornerRadius: 14 * s).strokeBorder(.separator, lineWidth: 1)
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
                .frame(width: 2 * s, height: 18 * s)
            Text(String(characters[cursor...]))
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .truncationMode(.head)
        .font(.system(size: 15 * s))
        .padding(.horizontal, 10 * s)
        .frame(height: 34 * s)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 7 * s))
        .overlay {
            RoundedRectangle(cornerRadius: 7 * s).strokeBorder(.separator, lineWidth: 1)
        }
    }

    private func keyButton(_ key: OnScreenKeyboard.Key, row: Int, index: Int) -> some View {
        let isFocused = keyboard.focusRow == row && keyboard.focusIndex == index
        let width = keyWidth * CGFloat(key.width) + spacing * CGFloat(key.width - 1)
        let shape = RoundedRectangle(cornerRadius: 6 * s)
        return Button {
            keyboard.focus(row: row, index: index)
            keyboard.press(key)
        } label: {
            ZStack(alignment: .topLeading) {
                label(for: key)
                    .font(.system(size: (key.isCharacter ? 15 : 13) * s))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let glyph = glyph(for: key) {
                    Image(systemName: glyph)
                        .font(.system(size: 11 * s))
                        .foregroundStyle(.secondary)
                        .padding(3 * s)
                }
            }
            .frame(width: width, height: keyHeight)
            .background(background(for: key), in: shape)
            .overlay {
                if isFocused {
                    shape.strokeBorder(Color.primary, lineWidth: 2.5 * s)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func label(for key: OnScreenKeyboard.Key) -> some View {
        switch key {
        case .character(let character): Text(character)
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
        HStack(spacing: 14 * s) {
            hint(.bottom, "Enter")
            hint(.right, "Close")
            hint(.top, "Space")
            hint(.left, "Delete")
            hint(.r2, "Done")
            Label("Move", systemImage: "r.joystick")
            Label("Size", systemImage: "l.joystick.press.down")
            Spacer(minLength: 0)
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 10 * s))
        .foregroundStyle(.secondary)
    }

    private func hint(_ button: LibraryControllerNavigator.ControllerButton, _ title: String) -> some View {
        Label(title, systemImage: navigator.buttonSymbol(button))
    }
}
