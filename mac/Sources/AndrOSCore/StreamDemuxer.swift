import Foundation

/// scrcpy 4.x video akis protokolu. Kaynaktan dogrulandi (demuxer.c).
public final class StreamDemuxer {

    public enum Codec: UInt32 {
        case h264 = 0x6832_3634, h265 = 0x6832_3635, av1 = 0x0061_7631
        case vp8  = 0x0076_7038, vp9  = 0x0076_7039
        public var name: String {
            switch self { case .h264: return "H.264"; case .h265: return "HEVC"
            case .av1: return "AV1"; case .vp8: return "VP8"; case .vp9: return "VP9" }
        }
    }

    public struct Packet {
        public let pts: UInt64          // mikrosaniye
        public let isConfig: Bool       // SPS/PPS tasiyan yapilandirma paketi
        public let isKeyFrame: Bool
        public let data: [UInt8]
    }

    public enum Event {
        case session(width: Int, height: Int, resized: Bool)
        case packet(Packet)
    }

    private static let headerSize = 12
    private static let flagSession  : UInt64 = 1 << 63
    private static let flagConfig   : UInt64 = 1 << 62
    private static let flagKeyFrame : UInt64 = 1 << 61
    private static let ptsMask      : UInt64 = (1 << 61) - 1

    private let sock: TCPSocket
    public private(set) var codec: Codec?

    public init(socket: TCPSocket) { self.sock = socket }

    /// Akisin basindaki 4 baytlik codec kimligini okur.
    @discardableResult
    public func readCodec() -> Codec? {
        guard let b = sock.readExactly(4) else { return nil }
        let raw = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        codec = Codec(rawValue: raw)
        return codec
    }

    /// Bir sonraki olayi okur. Akis biterse nil.
    public func next() -> Event? {
        guard let h = sock.readExactly(StreamDemuxer.headerSize) else { return nil }
        var head: UInt64 = 0
        for i in 0..<8 { head = (head << 8) | UInt64(h[i]) }
        let tail = (UInt32(h[8]) << 24) | (UInt32(h[9]) << 16) | (UInt32(h[10]) << 8) | UInt32(h[11])

        if head & StreamDemuxer.flagSession != 0 {
            // Oturum paketi: bayt 4-7 genislik, 8-11 yukseklik
            let w = (UInt32(h[4]) << 24) | (UInt32(h[5]) << 16) | (UInt32(h[6]) << 8) | UInt32(h[7])
            return .session(width: Int(w), height: Int(tail),
                            resized: (h[3] & 1) == 1)
        }

        let size = Int(tail)
        guard size > 0, size < 64 << 20, let payload = sock.readExactly(size) else { return nil }
        return .packet(Packet(pts: head & StreamDemuxer.ptsMask,
                              isConfig: head & StreamDemuxer.flagConfig != 0,
                              isKeyFrame: head & StreamDemuxer.flagKeyFrame != 0,
                              data: payload))
    }
}
