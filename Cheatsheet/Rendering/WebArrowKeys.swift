import WebKit

/// ←/→ in a clicked-into web page go to the site first; ones it doesn't
/// use page the cheatsheet. "Used" means the site called preventDefault (or
/// stopped the event before it reached the window), or the key went to a
/// text field or other editable element.
///
/// Runs in an isolated content world: the site can neither see this script
/// nor post its messages, but sees the same key events.
nonisolated enum WebArrowKeys {
    static let messageName = "cheatsheetArrowKeys"

    /// Checked after dispatch (setTimeout), so listeners the site adds to
    /// the window after this one have had their say too.
    static let script = """
    window.addEventListener('keydown', function (event) {
      if (!event.isTrusted || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
      if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
      var target = event.target;
      if (target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
      setTimeout(function () {
        if (event.defaultPrevented) return;
        window.webkit.messageHandlers.\(messageName).postMessage(event.key === 'ArrowRight' ? 'next' : 'previous');
      }, 0);
    });
    """

    @MainActor
    static func install(in content: WKUserContentController, handler: WKScriptMessageHandler) {
        let world = WKContentWorld.defaultClient
        content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        content.add(handler, contentWorld: world, name: messageName)
    }

    /// True for "next", false for "previous", nil for anything else.
    static func isForward(_ body: Any) -> Bool? {
        switch body as? String {
        case "next": true
        case "previous": false
        default: nil
        }
    }
}
