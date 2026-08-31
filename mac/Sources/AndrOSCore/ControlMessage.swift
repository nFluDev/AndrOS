import Foundation

/// scrcpy kontrol soketi mesajlari (control_msg.c'den dogrulandi).
public enum ControlMessage {
    public enum MsgType: UInt8 {
        case injectKeycode = 0, injectText = 1, injectTouch = 2, injectScroll = 3
        case backOrScreenOn = 4, expandNotificationPanel = 5, expandSettingsPanel = 6
        case collapsePanels = 7, getClipboard = 8, setClipboard = 9, setDisplayPower = 10
        case rotateDevice = 11
    }
    /// AMotionEvent sabitleri
    public enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }

    /// Gercek parmak gibi davranan pointer id. Oyunlar mouse pointer'ini (-1)
    /// bazen yok saydigi icin normal bir dokunma kimligi kullaniyoruz.
    public static let fingerID: UInt64 = 0
    /// Tus haritalama kendi parmagini kullanir; fare ile ayni anda basilabilsin.
    public static let joystickID: UInt64 = 1
    public static let mappedKeyID: UInt64 = 2

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private static func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (56 - 8 * $0)) & 0xFF) } }

    /// [x i32][y i32][w u16][h u16] = 12 bayt
    private static func position(x: Int32, y: Int32, w: UInt16, h: UInt16) -> [UInt8] {
        be32(UInt32(bitPattern: x)) + be32(UInt32(bitPattern: y)) + be16(w) + be16(h)
    }
    private static func u16fp(_ f: Float) -> UInt16 {
        UInt16(max(0, min(0xFFFF, Int(max(0, min(1, f)) * 65536))))
    }
    private static func i16fp(_ f: Float) -> UInt16 {
        let v = Int(max(-1, min(1, f)) * 32768)
        return UInt16(bitPattern: Int16(max(-32768, min(32767, v))))
    }

    /// 32 baytlik dokunma olayi
    public static func touch(_ action: TouchAction, x: Int, y: Int,
                             w: Int, h: Int, pressure: Float = 1.0,
                             buttons: UInt32 = 0, actionButton: UInt32 = 0,
                             pointerID: UInt64 = fingerID) -> [UInt8] {
        [MsgType.injectTouch.rawValue, action.rawValue]
            + be64(pointerID)
            + position(x: Int32(x), y: Int32(y), w: UInt16(w), h: UInt16(h))
            + be16(u16fp(action == .up ? 0 : pressure))
            + be32(actionButton) + be32(buttons)
    }

    /// 21 baytlik kaydirma olayi. hscroll/vscroll [-16,16] araliginda.
    public static func scroll(x: Int, y: Int, w: Int, h: Int,
                              hscroll: Float, vscroll: Float, buttons: UInt32 = 0) -> [UInt8] {
        [MsgType.injectScroll.rawValue]
            + position(x: Int32(x), y: Int32(y), w: UInt16(w), h: UInt16(h))
            + be16(i16fp(hscroll / 16)) + be16(i16fp(vscroll / 16))
            + be32(buttons)
    }

    /// 14 baytlik tus olayi (0=ACTION_DOWN, 1=ACTION_UP)
    public static func keycode(_ action: UInt8, _ keycode: UInt32,
                               repeatCount: UInt32 = 0, metaState: UInt32 = 0) -> [UInt8] {
        [MsgType.injectKeycode.rawValue, action] + be32(keycode) + be32(repeatCount) + be32(metaState)
    }

    public static func backOrScreenOn(_ action: UInt8) -> [UInt8] {
        [MsgType.backOrScreenOn.rawValue, action]
    }
    public static func setDisplayPower(_ on: Bool) -> [UInt8] {
        [MsgType.setDisplayPower.rawValue, on ? 1 : 0]
    }
    public static let collapsePanels: [UInt8] = [MsgType.collapsePanels.rawValue]
    public static let expandNotifications: [UInt8] = [MsgType.expandNotificationPanel.rawValue]
    public static let expandSettings: [UInt8] = [MsgType.expandSettingsPanel.rawValue]
    public static let rotateDevice: [UInt8] = [MsgType.rotateDevice.rawValue]

    /// [9][sequence u64][paste u8][len u32][utf8 metin]
    public static func setClipboard(_ text: String, sequence: UInt64 = 0,
                                    paste: Bool = false) -> [UInt8] {
        let bytes = Array(text.utf8)
        return [MsgType.setClipboard.rawValue] + be64(sequence) + [paste ? 1 : 0]
             + be32(UInt32(bytes.count)) + bytes
    }

    /// [8][copy_key u8]  — cihazdan panoyu iste
    public static func getClipboard() -> [UInt8] {
        [MsgType.getClipboard.rawValue, 0]
    }
}

/// Cihazdan istemciye gelen mesajlar (device_msg.c'den dogrulandi).
public enum DeviceMessage {
    case clipboard(String)
    case ackClipboard(UInt64)
    case unknown(UInt8)

    /// Akistan bir mesaj okur. Eksik veri varsa nil doner.
    public static func read(from sock: TCPSocket) -> DeviceMessage? {
        guard let head = sock.readExactly(1) else { return nil }
        switch head[0] {
        case 0:   // CLIPBOARD: [len u32][metin]
            guard let lenB = sock.readExactly(4) else { return nil }
            let len = Int(UInt32(lenB[0]) << 24 | UInt32(lenB[1]) << 16
                        | UInt32(lenB[2]) << 8  | UInt32(lenB[3]))
            guard len >= 0, len < 8 << 20 else { return nil }
            if len == 0 { return .clipboard("") }
            guard let body = sock.readExactly(len) else { return nil }
            return .clipboard(String(decoding: body, as: UTF8.self))
        case 1:   // ACK_CLIPBOARD: [sequence u64]
            guard let s = sock.readExactly(8) else { return nil }
            var v: UInt64 = 0
            for b in s { v = (v << 8) | UInt64(b) }
            return .ackClipboard(v)
        default:
            return .unknown(head[0])
        }
    }
}

/// Android keycode sabitleri (ihtiyac duyulanlar).
public enum AKeycode {
    public static let back: UInt32 = 4, home: UInt32 = 3, appSwitch: UInt32 = 187
    public static let volumeUp: UInt32 = 24, volumeDown: UInt32 = 25, power: UInt32 = 26
    public static let enter: UInt32 = 66, del: UInt32 = 67, escape: UInt32 = 111
    public static let dpadUp: UInt32 = 19, dpadDown: UInt32 = 20
    public static let dpadLeft: UInt32 = 21, dpadRight: UInt32 = 22
}
