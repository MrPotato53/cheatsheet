import AppKit
import Testing

@testable import Cheatsheet

struct PageZoomTests {
    @Test func stepsByTenPercent() {
        #expect(PageZoom.label(for: PageZoom.zoomedIn(from: 1)) == "110%")
        #expect(PageZoom.label(for: PageZoom.zoomedOut(from: 1)) == "90%")
        #expect(PageZoom.label(for: PageZoom.zoomedIn(from: PageZoom.zoomedIn(from: 1))) == "120%")
    }

    @Test func repeatedStepsDoNotDrift() {
        var zoom = PageZoom.actualSize
        for _ in 0..<7 { zoom = PageZoom.zoomedIn(from: zoom) }
        for _ in 0..<7 { zoom = PageZoom.zoomedOut(from: zoom) }
        #expect(zoom == PageZoom.actualSize)
    }

    @Test func stopsAtTheLimits() {
        #expect(PageZoom.zoomedIn(from: PageZoom.maximum) == PageZoom.maximum)
        #expect(PageZoom.zoomedOut(from: PageZoom.minimum) == PageZoom.minimum)
    }

    @Test func strayValuesSnapToTensAndClamp() {
        #expect(PageZoom.label(for: PageZoom.zoomedIn(from: 1.04)) == "110%")
        #expect(PageZoom.clamped(12) == PageZoom.maximum)
        #expect(PageZoom.clamped(.nan) == PageZoom.actualSize)
    }
}

struct OverlayScrollModifierTests {
    @Test func shiftScrollsSidewaysUnlessHeldForTheShortcut() {
        #expect(OverlayPanel.scrollsSideways(modifiers: .shift, heldForShortcut: []))
        #expect(OverlayPanel.scrollsSideways(modifiers: [.shift, .command], heldForShortcut: .command))
        #expect(!OverlayPanel.scrollsSideways(modifiers: [.shift, .command], heldForShortcut: [.shift, .command]))
        #expect(!OverlayPanel.scrollsSideways(modifiers: .command, heldForShortcut: []))
    }
}
