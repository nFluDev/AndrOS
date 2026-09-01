import Foundation

/// AndrOS agindan gelen/giden metin mesajlari.
///
/// SMS'ten AYRI durmak zorunda: SMS telefonun kendi veritabaninda,
/// bunlar ise yalnizca iki ucun elinde. Sunucu iletiyi tasiyip
/// unutuyor, saklamiyor — yani kayit BIZDE degilse hicbir yerde yok.
public final class NetworkMessages {

    public static let shared = NetworkMessages()

    public struct Message: Codable, Identifiable, Hashable {
        public let id: String
        /// Bu cihazdan mi gitti?
        public let outgoing: Bool
        public let text: String
        public let at: Date
        public init(id: String = UUID().uuidString, outgoing: Bool,
                    text: String, at: Date = Date()) {
            self.id = id; self.outgoing = outgoing; self.text = text; self.at = at
        }
    }

    private struct Store: Codable {
        var threads: [String: [Message]] = [:]
        /// Kimlik -> telefon numarasi. Gelen mesaji DOGRU sohbete
        /// koyabilmek icin: ag kimlik konusuyor, arayuz numara.
        var numbers: [String: String] = [:]
    }

    private var store = Store()
    private let lock = NSLock()

    private static var file: URL {
        if let custom = ProcessInfo.processInfo.environment["ANDROS_MESSAGES"] {
            return URL(fileURLWithPath: custom)
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("AndrOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("messages.json")
    }

    private init() {
        if let d = try? Data(contentsOf: Self.file),
           let s = try? JSONDecoder().decode(Store.self, from: d) { store = s }
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(store) else { return }
        try? d.write(to: Self.file)
    }

    // MARK: - Okuma

    public func messages(peer: String) -> [Message] {
        lock.lock(); defer { lock.unlock() }
        return store.threads[peer] ?? []
    }

    /// Numaraya ait sohbet — kimligi biliniyorsa.
    public func messages(number: String) -> [Message] {
        guard let peer = peerID(forNumber: number) else { return [] }
        return messages(peer: peer)
    }

    public func peerID(forNumber number: String) -> String? {
        let want = SignalClient.normalize(number)
        lock.lock(); defer { lock.unlock() }
        return store.numbers.first { SignalClient.normalize($0.value) == want }?.key
    }

    public func number(forPeer peer: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store.numbers[peer]
    }

    // MARK: - Yazma

    public func remember(peer: String, number: String) {
        lock.lock()
        store.numbers[peer] = number
        lock.unlock()
        save()
    }

    @discardableResult
    public func add(peer: String, _ m: Message) -> Message {
        lock.lock()
        store.threads[peer, default: []].append(m)
        // Sohbet basi sinir: bellekte ve diskte sinirsiz buyumesin.
        if store.threads[peer]!.count > 2000 {
            store.threads[peer]!.removeFirst(store.threads[peer]!.count - 2000)
        }
        lock.unlock()
        save()
        return m
    }

    /// Bir mesaji olan tum kimlikler — sohbet listesi icin.
    public func peers() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(store.threads.keys)
    }
}
