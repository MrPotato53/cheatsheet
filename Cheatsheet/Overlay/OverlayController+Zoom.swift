import AppKit

extension OverlayController {
    func setZoom(_ zoom: Double, in session: OverlaySession) {
        let zoom = PageZoom.clamped(zoom)
        session.zoomFlash += 1
        guard zoom != session.zoom else { return }
        session.zoom = zoom
        ZoomMemory.record(zoom, for: session.sheet.id)
    }

    /// ⌘= (or ⌘+) zooms in, ⌘- out, ⌘0 back to 100%: in every page kind,
    /// including web pages, which would otherwise handle these themselves.
    func handleZoomKeyEvent(_ event: NSEvent, in session: OverlaySession) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags == .command, let key = event.charactersIgnoringModifiers else { return false }
        switch key {
        case "=", "+":
            setZoom(PageZoom.zoomedIn(from: session.zoom), in: session)
        case "-":
            setZoom(PageZoom.zoomedOut(from: session.zoom), in: session)
        case "0":
            setZoom(PageZoom.actualSize, in: session)
        default:
            return false
        }
        return true
    }
}
