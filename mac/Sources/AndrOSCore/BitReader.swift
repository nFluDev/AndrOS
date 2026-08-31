import Foundation

/// RBSP uzerinde bit seviyesinde okuma (Exp-Golomb dahil).
public struct BitReader {
    private let bytes: [UInt8]
    private var bitPos = 0

    public init(_ data: [UInt8]) { self.bytes = data }

    public var bitsLeft: Int { bytes.count * 8 - bitPos }

    public mutating func u(_ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<n {
            guard bitPos < bytes.count * 8 else { return v << 1 }
            let byte = bytes[bitPos >> 3]
            let bit = (byte >> (7 - UInt8(bitPos & 7))) & 1
            v = (v << 1) | UInt64(bit)
            bitPos += 1
        }
        return v
    }

    public mutating func flag() -> Bool { u(1) == 1 }

    /// ue(v) — isaretsiz Exp-Golomb
    public mutating func ue() -> UInt32 {
        var lead = 0
        while bitsLeft > 0 && u(1) == 0 { lead += 1; if lead > 32 { return 0 } }
        if lead == 0 { return 0 }
        return UInt32((1 << lead) - 1 + Int(u(lead)))
    }

    /// se(v) — isaretli Exp-Golomb
    public mutating func se() -> Int32 {
        let k = ue()
        return k % 2 == 0 ? -Int32(k / 2) : Int32((k + 1) / 2)
    }

    public mutating func skip(_ n: Int) { bitPos = min(bitPos + n, bytes.count * 8) }
}

public enum NALU {
    /// Annex-B akisindan NAL birimlerini ayirir (start code 000001 / 00000001).
    public static func split(_ data: [UInt8]) -> [ArraySlice<UInt8>] {
        var starts: [(Int, Int)] = []   // (payload baslangici, start code uzunlugu)
        var i = 0
        while i + 2 < data.count {
            if data[i] == 0 && data[i+1] == 0 {
                if data[i+2] == 1 { starts.append((i + 3, 3)); i += 3; continue }
                if i + 3 < data.count && data[i+2] == 0 && data[i+3] == 1 {
                    starts.append((i + 4, 4)); i += 4; continue
                }
            }
            i += 1
        }
        return starts.enumerated().map { idx, s in
            let end = idx + 1 < starts.count ? starts[idx+1].0 - starts[idx+1].1 : data.count
            return data[s.0..<max(s.0, end)]
        }
    }

    /// Emulation prevention baytlarini (00 00 03 -> 00 00) cikarir.
    public static func rbsp(_ nal: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(nal.count)
        var zeros = 0
        for b in nal {
            if zeros == 2 && b == 0x03 { zeros = 0; continue }
            out.append(b)
            zeros = (b == 0) ? zeros + 1 : 0
        }
        return out
    }
}
