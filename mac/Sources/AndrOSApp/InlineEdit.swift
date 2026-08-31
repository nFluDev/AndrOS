import AppKit

/// Yerinde yeniden adlandirma alani — Finder'daki dosya adi gibi.
///
/// Neden acilir pencere degil: macOS'ta bir seyi yeniden adlandirmak
/// LISTENIN UZERINDE olur; ayri bir pencere acmak hem baglami kopariyor
/// hem de fazladan bir tiklama getiriyor. Alan normalde duz bir etiket
/// gibi durur, `beginEditing()` ile kenarlik ve imlec kazanir.
///
/// Enter kaydeder, Esc vazgecer, odak kaybi da kaydeder (Finder boyle yapar).
final class InlineEditLabel: NSTextField, NSTextFieldDelegate {

    /// Yeni ad onaylandiginda. Bos ya da degismemisse cagrilmaz.
    var onCommit: ((String) -> Void)?
    /// Duzenleme bittiginde (kaydedilsin ya da vazgecilsin).
    var onEnd: (() -> Void)?

    private var original = ""
    private var editing = false

    static func label(_ text: String) -> InlineEditLabel {
        let f = InlineEditLabel(labelWithString: text)
        f.font = .systemFont(ofSize: 13, weight: .medium)
        f.lineBreakMode = .byTruncatingTail
        f.delegate = f
        return f
    }

    func beginEditing() {
        guard !editing else { return }
        editing = true
        UserBusy.begin()      // duzenlerken liste yenilenmesin
        original = stringValue
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        focusRingType = .default
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    private func endEditing(save: Bool) {
        guard editing else { return }
        editing = false
        UserBusy.end()
        let v = stringValue.trimmingCharacters(in: .whitespaces)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        if save, !v.isEmpty, v != original { onCommit?(v) } else { stringValue = original }
        window?.makeFirstResponder(nil)
        onEnd?()
    }

    func control(_ c: NSControl, textView: NSTextView,
                 doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): endEditing(save: true);  return true
        case #selector(NSResponder.cancelOperation(_:)): endEditing(save: false); return true
        default: return false
        }
    }

    // Odak baska yere gecerse Finder gibi KAYDEDIYORUZ.
    func controlTextDidEndEditing(_ n: Notification) { endEditing(save: true) }
}
