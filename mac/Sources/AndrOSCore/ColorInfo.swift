import Foundation

/// Bit akisindan okunan renk sinyali bilgisi. Solukluk teshisinin temeli.
public struct ColorInfo: CustomStringConvertible {
    public var fullRange: Bool?          // video_full_range_flag
    public var primaries: UInt8?         // colour_primaries
    public var transfer: UInt8?          // transfer_characteristics
    public var matrix: UInt8?            // matrix_coefficients
    public var bitDepthLuma: Int?
    public var chromaFormat: Int?        // 0=mono 1=4:2:0 2=4:2:2 3=4:4:4
    public var width: Int?
    public var height: Int?
    public var profile: String?

    public static func primaryName(_ v: UInt8) -> String {
        switch v {
        case 1: return "BT.709"; case 2: return "belirtilmemis"; case 5: return "BT.601 PAL"
        case 6: return "BT.601 NTSC (SMPTE 170M)"; case 9: return "BT.2020"; case 12: return "Display P3"
        default: return "kod \(v)" }
    }
    public static func transferName(_ v: UInt8) -> String {
        switch v {
        case 1: return "BT.709"; case 2: return "belirtilmemis"; case 6: return "SMPTE 170M"
        case 8: return "Lineer"; case 13: return "sRGB/IEC61966-2-1"; case 16: return "PQ (ST2084)"
        case 18: return "HLG"; default: return "kod \(v)" }
    }
    public static func matrixName(_ v: UInt8) -> String {
        switch v {
        case 0: return "Identity/GBR"; case 1: return "BT.709"; case 2: return "belirtilmemis"
        case 5: return "BT.601 PAL"; case 6: return "BT.601 NTSC (SMPTE 170M)"; case 9: return "BT.2020 NCL"
        default: return "kod \(v)" }
    }
    public static func chromaName(_ v: Int) -> String {
        switch v { case 0: return "monokrom"; case 1: return "4:2:0"; case 2: return "4:2:2"
        case 3: return "4:4:4"; default: return "?" }
    }

    public var description: String {
        var l: [String] = []
        if let w = width, let h = height { l.append("cozunurluk       : \(w)x\(h)") }
        if let p = profile               { l.append("profil           : \(p)") }
        if let b = bitDepthLuma          { l.append("bit derinligi    : \(b)-bit") }
        if let c = chromaFormat          { l.append("chroma           : \(ColorInfo.chromaName(c))") }
        l.append("renk araligi     : " + (fullRange.map { $0 ? "FULL (0-255)" : "LIMITED (16-235)" } ?? "SINYAL YOK"))
        l.append("primaries        : " + (primaries.map { ColorInfo.primaryName($0) } ?? "SINYAL YOK"))
        l.append("transfer         : " + (transfer.map { ColorInfo.transferName($0) } ?? "SINYAL YOK"))
        l.append("matris           : " + (matrix.map { ColorInfo.matrixName($0) } ?? "SINYAL YOK"))
        return l.joined(separator: "\n")
    }

    /// Solukluga yol acan yapilandirmalari tespit eder.
    public var warnings: [String] {
        var w: [String] = []
        if fullRange == nil {
            w.append("Akista video_signal_type YOK. Cozucu varsayilan olarak LIMITED range + BT.601 kabul eder; encoder FULL uretiyorsa siyahlar grilesir, renkler solar. -> Ana suphe.")
        }
        if matrix == nil || matrix == 2 {
            w.append("Matris belirtilmemis. 1080p+ icin BT.709 dogrusu ama cozucular sik sik BT.601'e duser -> ton kaymasi ve doygunluk kaybi.")
        }
        if let m = matrix, m == 5 || m == 6 {
            w.append("Matris BT.601 olarak isaretli. HD icerik icin yanlis; BT.709 ile cozulurse renkler kayar.")
        }
        if let f = fullRange, f == false {
            w.append("Encoder LIMITED range uretiyor: 16-235'e sikistirilmis. Kontrast ve doygunluk dogal olarak dusuk. Kaynakta color-range=1 (FULL) denenmeli.")
        }
        if let b = bitDepthLuma, b == 8 { w.append("8-bit: gradyanlarda banding beklenir. 10-bit HEVC (profile Main10) denenebilir; RX 580 donanimda cozer.") }
        if let c = chromaFormat, c == 1 { w.append("4:2:0: renk cozunurlugu her eksende yariya iniyor. Emulatorde bu kayip yok; 'soluk' hissinin bir kismi bu. Client'ta iyi bir chroma upsample sart.") }
        return w
    }
}
