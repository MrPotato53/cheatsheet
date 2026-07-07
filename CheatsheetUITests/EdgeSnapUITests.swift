import XCTest

/// Dragging the overlay against monitor edges and snapping back, then
/// changing the page aspect ratio to confirm the overlay keeps hugging the
/// edge (top, side, and corner) — i.e. the user's placement *intent* is
/// preserved, not just a numeric position.
///
/// NOTE: the sticking-across-aspect-change tests encode the intended
/// behavior. Code analysis says the current model stores a proportional
/// *center*, so when the next page's fitted size is smaller on an axis the
/// overlay drifts off the edge on that axis. Failures here document that gap
/// rather than a test bug — see the "edge intent" comments inline.
final class EdgeSnapUITests: CheatsheetUITestCase {
    /// Page 0 is wide (fills the size box's width), page 1 is tall (much
    /// narrower, taller) — switching pages changes the fitted panel size on
    /// both axes, which is exactly what stresses edge-stickiness.
    private func edgeSheet() -> SeedSheet {
        SeedSheet(
            name: "Edges",
            pages: [
                .image("wide.png", width: 1500, height: 500),
                .image("tall.png", width: 500, height: 1200),
            ],
            previewScale: 0.5,
            startPage: "first"
        )
    }

    @MainActor
    func testDragPastRightEdgeSnapsFullyOnScreen() throws {
        launchApp(sheets: [edgeSheet()])
        openOverlayFromMenu("Edges")
        _ = waitForSettledFrame(sessionNamed: "Edges")

        // Shove it far past the right edge of the monitor.
        dragOverlayTowards([.right], sessionNamed: "Edges")

        let session = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        assertFullyOnScreen(session)
        assertTouchesEdge(.right, session)
    }

    @MainActor
    func testDragPastTopEdgeClampsWithinVisibleFrame() throws {
        launchApp(sheets: [edgeSheet()])
        openOverlayFromMenu("Edges")
        _ = waitForSettledFrame(sessionNamed: "Edges")

        // Up and past the menu bar.
        dragOverlayTowards([.top], sessionNamed: "Edges")

        let session = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        assertFullyOnScreen(session) // notably: below the menu bar
        assertTouchesEdge(.top, session)
    }

    @MainActor
    func testRightEdgeContactPreservedAcrossAspectChange() throws {
        launchApp(sheets: [edgeSheet()])
        openOverlayFromMenu("Edges")
        _ = waitForSettledFrame(sessionNamed: "Edges")

        dragOverlayTowards([.right], sessionNamed: "Edges")
        let snapped = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        assertTouchesEdge(.right, snapped)

        // Page 2 is much narrower. Edge intent says it should still hug the
        // right edge. (Current model: proportional center → expected gap.)
        app.buttons["overlay.nextPage"].click()
        let narrow = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        XCTAssertEqual(narrow.pageIndex, 1)
        assertTouchesEdge(.right, narrow)

        // Back to the wide page: contact must be restored either way.
        app.buttons["overlay.previousPage"].click()
        let wide = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        XCTAssertEqual(wide.pageIndex, 0)
        assertTouchesEdge(.right, wide)
    }

    @MainActor
    func testTopEdgeContactPreservedAcrossAspectChange() throws {
        launchApp(sheets: [edgeSheet()])
        openOverlayFromMenu("Edges")
        _ = waitForSettledFrame(sessionNamed: "Edges")

        // Go to the tall page first (it fills the size box's height), then
        // pin it against the top edge.
        app.buttons["overlay.nextPage"].click()
        _ = waitForSettledFrame(sessionNamed: "Edges")
        dragOverlayTowards([.top], sessionNamed: "Edges")
        let snapped = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        assertTouchesEdge(.top, snapped)

        // The wide page is much shorter. Edge intent: still hug the top.
        app.buttons["overlay.previousPage"].click()
        let short = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        XCTAssertEqual(short.pageIndex, 0)
        assertTouchesEdge(.top, short)

        // And back: the tall page returns to the top edge.
        app.buttons["overlay.nextPage"].click()
        let tall = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        XCTAssertEqual(tall.pageIndex, 1)
        assertTouchesEdge(.top, tall)
    }

    @MainActor
    func testCornerContactPreservedAcrossAspectChange() throws {
        launchApp(sheets: [edgeSheet()])
        openOverlayFromMenu("Edges")
        _ = waitForSettledFrame(sessionNamed: "Edges")

        // Into the top-right corner (both axes at once).
        dragOverlayTowards([.right, .top], sessionNamed: "Edges")
        let snapped = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        assertTouchesEdge(.right, snapped)
        assertTouchesEdge(.top, snapped)

        // Aspect flips wide→tall: corner intent should survive on both axes.
        app.buttons["overlay.nextPage"].click()
        let flipped = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        XCTAssertEqual(flipped.pageIndex, 1)
        assertTouchesEdge(.right, flipped)
        assertTouchesEdge(.top, flipped)

        // And survive flipping back.
        app.buttons["overlay.previousPage"].click()
        let restored = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        assertTouchesEdge(.right, restored)
        assertTouchesEdge(.top, restored)
    }

    @MainActor
    func testEdgeContactSurvivesReopenWithRememberedPosition() throws {
        launchApp(sheets: [edgeSheet()]) // dragBehavior remembers (default)
        openOverlayFromMenu("Edges")
        _ = waitForSettledFrame(sessionNamed: "Edges")

        dragOverlayTowards([.right], sessionNamed: "Edges")
        let snapped = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        assertTouchesEdge(.right, snapped)

        hideAllOverlays()
        openOverlayFromMenu("Edges")
        let reopened = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Edges"))
        assertTouchesEdge(.right, reopened)
    }
}
