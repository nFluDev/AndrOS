import AppKit

/// Kenarliksiz ayna penceresi.
///
/// Baslik cubugu YOK: cubuk varken ustten surukleme pencereyi tasiyordu ve
/// Android bildirim panelini asagi cekmek imkansizdi. Artik pencerenin
/// tamami goruntu; tasima yalnizca ⌘ + sol tik surukleme ile.
final class MirrorWindow: NSWindow {
    // Kenarliksiz pencereler varsayilan olarak key/main olamaz.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
