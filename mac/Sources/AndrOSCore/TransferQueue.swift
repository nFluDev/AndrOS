import Foundation

/// Telefon <-> Mac dosya aktarimlarinin merkezi kuyrugu.
///
/// Paneller artik dogrudan `pull/push` cagirmiyor; her sey buradan geciyor.
/// Boylece arayuzde tek bir yerde ilerleme, duraklat/devam ve iptal
/// gosterilebiliyor ve ayni anda cok sayida adb sureci acilmiyor.
public final class TransferQueue {

    public static let shared = TransferQueue()

    public enum Direction { case download, upload }
    public enum State: Equatable { case waiting, running, paused, done, failed, cancelled }

    public final class Item: Identifiable {
        public let id = UUID()
        public let name: String
        public let remote: String
        public let local: String
        public let direction: Direction
        public internal(set) var progress: Int = 0
        public internal(set) var state: State = .waiting
        var handle: RawProcess.Handle?
        var onFinish: ((Bool) -> Void)?

        init(name: String, remote: String, local: String, direction: Direction) {
            self.name = name; self.remote = remote
            self.local = local; self.direction = direction
        }
    }

    /// Degisiklikte arayuzu uyandirir (ana is parcaciginda cagrilir).
    public var onChange: (() -> Void)?

    private var items: [Item] = []
    private let lock = NSLock()
    private var running = false
    /// Ayni anda tek aktarim: adb es zamanli buyuk transferlerde yavasliyor
    /// ve ilerleme ic ice giriyor.
    private var adbPath: String?
    private var serial: String?

    public func configure(adbPath: String, serial: String?) {
        self.adbPath = adbPath
        self.serial = serial
    }

    /// Veri katmani: eslesmis uygulama varsa indirme ONDAN yapiliyor.
    /// adb yalnizca geri dusus — USB cikinca ve hata ayiklama kapaninca
    /// `adb pull` calismiyor ve kuyruktaki hicbir sey inmiyordu.
    public var data: AndroidData?

    public var snapshot: [Item] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    public var activeCount: Int {
        snapshot.filter { $0.state == .running || $0.state == .waiting || $0.state == .paused }.count
    }

    @discardableResult
    public func enqueue(name: String, remote: String, local: String,
                        direction: Direction,
                        onFinish: ((Bool) -> Void)? = nil) -> Item {
        let it = Item(name: name, remote: remote, local: local, direction: direction)
        it.onFinish = onFinish
        lock.lock(); items.append(it); lock.unlock()
        notify()
        pump()
        return it
    }

    public func pause(_ id: UUID) {
        guard let it = find(id), it.state == .running else { return }
        it.handle?.suspend()
        it.state = .paused
        notify()
    }

    public func resume(_ id: UUID) {
        guard let it = find(id), it.state == .paused else { return }
        it.handle?.resume()
        it.state = .running
        notify()
    }

    public func cancel(_ id: UUID) {
        guard let it = find(id) else { return }
        if it.state == .running || it.state == .paused {
            it.handle?.cancel()
        }
        it.state = .cancelled
        notify()
        pump()
    }

    /// Bitmis/iptal edilmis kayitlari listeden temizler.
    public func clearFinished() {
        lock.lock()
        items.removeAll { $0.state == .done || $0.state == .cancelled || $0.state == .failed }
        lock.unlock()
        notify()
    }

    private func find(_ id: UUID) -> Item? {
        lock.lock(); defer { lock.unlock() }
        return items.first { $0.id == id }
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    private func pump() {
        lock.lock()
        let busy = running
        let next = items.first { $0.state == .waiting }
        lock.unlock()
        // ADB SART DEGIL.
        //
        // Buradaki `let adb = adbPath` kosulu, adb yapilandirilmamisken
        // (USB yok, hata ayiklama kapali) kuyrugu TAMAMEN olduruyordu:
        // ogeler "sirada" kalip hic baslamiyordu — kullanicinin gordugu
        // "queued oluyor devam etmiyor" tam olarak buydu. Uygulama
        // koprusu varken adb'ye hic ihtiyac yok.
        guard !busy, let item = next else { return }
        let adb = adbPath
        let appReady = data?.companion?.isReady == true
        guard adb != nil || appReady else { return }

        lock.lock(); running = true; lock.unlock()
        item.state = .running
        notify()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            // UYGULAMA YOLU once (indirmede): adb'siz calismak hedef.
            if item.direction == .download, let d = self.data,
               d.companion?.isReady == true {
                let ok = d.pullPreferringApp(item.remote, to: item.local) { got, total in
                    guard total > 0 else { return }
                    item.progress = min(100, got * 100 / total)
                    self.notify()
                }
                if item.state != .cancelled {
                    item.state = ok ? .done : .failed
                    item.progress = ok ? 100 : item.progress
                }
                item.onFinish?(ok)
                self.lock.lock(); self.running = false; self.lock.unlock()
                self.notify()
                self.pump()
                return
            }

            // Buraya adb ile geldiysek yol kesin var.
            guard let adb else {
                item.state = .failed
                item.onFinish?(false)
                self.lock.lock(); self.running = false; self.lock.unlock()
                self.notify(); self.pump()
                return
            }
            var args = self.serial.map { ["-s", $0] } ?? []
            args += item.direction == .download
                ? ["pull", item.remote, item.local]
                : ["push", item.local, item.remote]

            let r = RawProcess.runStreaming(adb, args,
                onHandle: { h in item.handle = h },
                onProgress: { pct in
                    item.progress = pct
                    self.notify()
                })
            let ok = r.code == 0
            if item.state != .cancelled {
                item.state = ok ? .done : .failed
                item.progress = ok ? 100 : item.progress
            }
            item.onFinish?(ok)
            self.lock.lock(); self.running = false; self.lock.unlock()
            self.notify()
            self.pump()
        }
    }
}
