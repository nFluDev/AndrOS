import Foundation
import CryptoKit

/// AndrOS aginin kimlik anahtarlari (Mac tarafi).
///
/// Android tarafiyla BIREBIR ayni turetme: Ed25519 kimlik, X25519
/// sifreleme, adres = SHA-256(ed açık anahtar)[0..<10] -> Crockford
/// base32. Iki taraf ayni kimligi uretmezse hicbir sey tutmaz, o yuzden
/// burasi olculerek dogrulandi.
public struct SignalKeys {

    public let edPrivate: Curve25519.Signing.PrivateKey
    public let xPrivate: Curve25519.KeyAgreement.PrivateKey

    /// Anahtarlar Anahtar Zinciri'nde DEGIL, uygulamanin kendi destek
    /// klasorunde: Anahtar Zinciri'ne yazmak imzasiz uygulamada her
    /// derlemeden sonra yeniden izin istiyor ve kimligin degismesi
    /// karsi tarafta "baska cihaz" demek olurdu.
    private static var file: URL {
        // Sinamada IKI KIMLIK gerekiyor (iki ayri cihaz gibi davranmak
        // icin); bu degisken olmadan ayni makinede iki uc calistirmak
        // mumkun degil.
        if let custom = ProcessInfo.processInfo.environment["ANDROS_IDENTITY"] {
            return URL(fileURLWithPath: custom)
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("AndrOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("identity.json")
    }

    public init() {
        var ed: Curve25519.Signing.PrivateKey?
        var x: Curve25519.KeyAgreement.PrivateKey?
        if let data = try? Data(contentsOf: Self.file),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let e = j["ed"].flatMap({ Data(base64Encoded: $0) }),
           let xr = j["x"].flatMap({ Data(base64Encoded: $0) }) {
            ed = try? Curve25519.Signing.PrivateKey(rawRepresentation: e)
            x = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: xr)
        }
        let edKey = ed ?? Curve25519.Signing.PrivateKey()
        let xKey = x ?? Curve25519.KeyAgreement.PrivateKey()
        edPrivate = edKey
        xPrivate = xKey
        if ed == nil || x == nil {
            let j = ["ed": edKey.rawRepresentation.base64EncodedString(),
                     "x": xKey.rawRepresentation.base64EncodedString()]
            try? JSONSerialization.data(withJSONObject: j).write(to: Self.file)
            Log.write("AndrOS kimliği üretildi: \(Self.id(for: edKey.publicKey.rawRepresentation))")
        }
    }

    public var edPublic: Data { edPrivate.publicKey.rawRepresentation }
    public var xPublic: Data { xPrivate.publicKey.rawRepresentation }
    public var id: String { Self.id(for: edPublic) }

    public func sign(_ data: Data) -> Data {
        (try? edPrivate.signature(for: data)) ?? Data()
    }

    /// Crockford base32 — sesli okunurken karistirilan harfler yok.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func id(for edPublic: Data) -> String {
        let h = Data(SHA256.hash(data: edPublic).prefix(10))
        var bits = 0, value = 0, out = ""
        for b in h {
            value = (value << 8) | Int(b); bits += 8
            while bits >= 5 { out.append(alphabet[(value >> (bits - 5)) & 31]); bits -= 5 }
        }
        return out
    }

    public static func verify(edPublic: Data, data: Data, signature: Data) -> Bool {
        guard let k = try? Curve25519.Signing.PublicKey(rawRepresentation: edPublic)
        else { return false }
        return k.isValidSignature(signature, for: data)
    }

    /// Iki cihaz arasindaki ortak anahtar. Tuz SIRALI iki kimlik:
    /// iki taraf bagimsizca ayni sonuca varsin.
    public func sharedKey(with theirX: Data, myID: String, theirID: String) -> SymmetricKey? {
        guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirX),
              let secret = try? xPrivate.sharedSecretFromKeyAgreement(with: pub)
        else { return nil }
        let salt = Data((myID < theirID ? myID + theirID : theirID + myID).utf8)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                              sharedInfo: Data("andros-e2e-v1".utf8),
                                              outputByteCount: 32)
    }
}

/// Uctan uca sifreli zarf. Bicim Android tarafiyla ayni.
public enum Envelope {

    public static let typeIntro: UInt8 = 0
    public static let typeSealed: UInt8 = 1
    private static let version: UInt8 = 1

    public struct Peer {
        public let id: String
        public let edPublic: Data
        public let xPublic: Data
    }

    public static func intro(_ keys: SignalKeys) -> Data {
        let x = keys.xPublic
        let sig = keys.sign(Data("andros-intro".utf8) + x)
        return Data([version, typeIntro]) + keys.edPublic + x + sig
    }

    /// Tanisma paketi. Gonderen kimligiyle TUTMUYORSA reddedilir —
    /// sunucunun araya baska bir anahtar sokmasini bu engelliyor.
    public static func openIntro(_ raw: Data, from id: String) -> Peer? {
        guard raw.count == 2 + 32 + 32 + 64, raw[raw.startIndex + 1] == typeIntro
        else { return nil }
        let b = [UInt8](raw)
        let ed = Data(b[2..<34]), x = Data(b[34..<66]), sig = Data(b[66..<130])
        guard SignalKeys.id(for: ed) == id,
              SignalKeys.verify(edPublic: ed, data: Data("andros-intro".utf8) + x,
                                signature: sig) else { return nil }
        return Peer(id: id, edPublic: ed, xPublic: x)
    }

    public static func seal(_ key: SymmetricKey, _ payload: [String: Any]) -> Data? {
        guard let plain = try? JSONSerialization.data(withJSONObject: payload),
              let box = try? ChaChaPoly.seal(plain, using: key) else { return nil }
        // CryptoKit nonce'u 12 bayt; Android tarafi da oyle bekliyor.
        return Data([version, typeSealed]) + box.nonce.withUnsafeBytes { Data($0) }
             + box.ciphertext + box.tag
    }

    public static func open(_ key: SymmetricKey, _ raw: Data) -> [String: Any]? {
        guard raw.count > 2 + 12 + 16, raw[raw.startIndex + 1] == typeSealed else { return nil }
        let b = [UInt8](raw)
        guard let nonce = try? ChaChaPoly.Nonce(data: Data(b[2..<14])) else { return nil }
        let body = Data(b[14...])
        let cipher = body.prefix(body.count - 16)
        let tag = body.suffix(16)
        guard let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag),
              let plain = try? ChaChaPoly.open(box, using: key),
              let j = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
        else { return nil }
        return j
    }

    public static func type(of raw: Data) -> UInt8 {
        raw.count > 1 ? raw[raw.startIndex + 1] : 255
    }
}
