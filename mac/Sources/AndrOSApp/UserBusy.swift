import AppKit

/// "Kullanici su an bir sey yapiyor" bayragi.
///
/// Arka plandaki tazelemeler kullanicinin isini BOLMEMELI. Ornekler:
/// bir satiri saga sola surukluyorken liste yenilenirse hareket yarida
/// kaliyor; yeniden adlandirma kutusu acikken yenileme satiri yeniden
/// cizip yaziyi siliyor; menu acikken tablo tazelenirse menu kapaniyor.
///
/// Tazeleme yapan her yer `UserBusy.isBusy` iken ERTELIYOR; is bitince
/// `onIdle` ile bir kez tetikleniyor.
enum UserBusy {
    private static var counter = 0
    private static var pending: [() -> Void] = []

    static var isBusy: Bool { counter > 0 || NSEvent.pressedMouseButtons != 0 }

    /// Bir etkilesim basladi.
    static func begin() { counter += 1 }

    /// Etkilesim bitti; bekleyen tazelemeler calisir.
    static func end() {
        counter = max(0, counter - 1)
        guard counter == 0 else { return }
        let waiting = pending
        pending.removeAll()
        for f in waiting { f() }
    }

    /// Mesgulse ERTELE, degilse hemen calistir.
    static func run(_ work: @escaping () -> Void) {
        if isBusy { pending.append(work) } else { work() }
    }

    /// Etkilesim boyunca sarar.
    static func during<T>(_ body: () -> T) -> T {
        begin(); defer { end() }
        return body()
    }
}
