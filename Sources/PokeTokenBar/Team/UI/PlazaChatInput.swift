import AppKit

/// 광장 아래쪽의 한 줄 입력창. 닫혀 있으면 보이지 않는다. 글자는 AppKit 입력창이 받으므로 한글 조합이 그대로 되고,
/// 열린 동안 장면은 키를 받지 않아 포켓몬이 움직이거나 이모트가 나가지 않는다.
@MainActor final class PlazaChatInput: NSObject, NSTextFieldDelegate {
    let view = NSView()
    let field = PlazaChatTextField()
    /// 입력한 글을 넘긴다. false면 입력창을 닫지 않고 글을 남긴다.
    var onSubmit: ((String) -> Bool)?
    /// 어떤 이유로든 닫히면 부른다.
    var onClose: (() -> Void)?
    /// 지금 키가 눌린 채 반복 중인지. 테스트에서 바꿔 끼운다.
    var isKeyRepeating: () -> Bool = { NSApp.currentEvent?.isARepeat == true }
    private(set) var isOpen = false

    override init() {
        super.init()
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(srgbRed: 0x1D / 255, green: 0x4F / 255, blue: 0x5C / 255, alpha: 0.95)
        view.layer?.borderColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 6
        view.isHidden = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.font = PlazaResources.font(size: 15)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(string: L(.ko).plazaChatPlaceholder, attributes: [
            .font: PlazaResources.font(size: 15), .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ])
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: view.topAnchor, constant: 9),
            field.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -9),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        field.stringValue = ""
        view.isHidden = false
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        field.stringValue = ""
        view.isHidden = true
        onClose?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // false를 돌려주면 입력이 끝나 입력창이 닫히고 글이 사라진다. 조합 중이면 글자만 확정한다.
            if textView.hasMarkedText() {
                textView.unmarkText()
                return true
            }
            // 입력창을 연 Enter를 누르고 있으면 반복 입력이 빈 입력창을 바로 닫는다.
            if isKeyRepeating() { return true }
            if onSubmit?(textView.string) != false { close() }
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            return true   // 입력창을 벗어나면 닫히므로 Tab이 쓰던 글을 지우지 않게 삼킨다.
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    /// 조합 중인 글자를 건드리면 한글이 깨지므로 조합이 끝난 뒤에 자른다.
    func controlTextDidChange(_ notification: Notification) {
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        if field.stringValue.count > TeamChat.maxCharacters {
            field.stringValue = String(field.stringValue.prefix(TeamChat.maxCharacters))
        }
    }

    /// 지도를 눌러 입력창을 벗어나면 닫는다. 닫지 않으면 Esc가 입력창 대신 광장을 닫는다.
    func controlTextDidEndEditing(_ notification: Notification) {
        close()
    }
}

final class PlazaChatTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let editor = currentEditor(),
              let action = Self.commandAction(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
            return super.performKeyEquivalent(with: event)
        }
        let target: Any? = action == #selector(NSWindow.performClose(_:)) ? window : editor
        return NSApp.sendAction(action, to: target, from: self)
    }

    /// 앱에 메인 메뉴가 없어 입력창이 단축키를 직접 처리한다. 한글 입력기에서는 문자가 달라지므로 keyCode로 판정한다.
    static func commandAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Selector? {
        guard modifiers.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        switch keyCode {
        case 0: return #selector(NSText.selectAll(_:))
        case 7: return #selector(NSText.cut(_:))
        case 8: return #selector(NSText.copy(_:))
        case 9: return #selector(NSText.paste(_:))
        case 13: return #selector(NSWindow.performClose(_:))
        default: return nil
        }
    }
}
