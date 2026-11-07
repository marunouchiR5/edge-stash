import CoreGraphics
import Foundation
import Testing
@testable import EdgeStashCore

// Fixture: a 1440x900 primary display with a 1920x1080 external display arranged above it.
private let primaryHeight: CGFloat = 900
private let builtIn = CGRect(x: 0, y: 0, width: 1440, height: 900)                   // AX space
private let external = StashGeometry.axRect(fromCocoa: CGRect(x: -240, y: 900, width: 1920, height: 1080),
                                      primaryHeight: primaryHeight)

@Suite struct GeometryTests {
    @Test func cocoaToAXConversion() {
        #expect(external == CGRect(x: -240, y: -1080, width: 1920, height: 1080))
        let p = StashGeometry.axPoint(fromCocoa: CGPoint(x: 1679, y: 1400), primaryHeight: primaryHeight)
        #expect(p == CGPoint(x: 1679, y: -500))
    }

    @Test func shownAndHiddenOriginsRight() {
        let size = CGSize(width: 600, height: 1000)
        let shown = StashGeometry.shownOrigin(size: size, y: -1000, area: external, edge: .right)
        #expect(shown == CGPoint(x: 1080, y: -1000))
        let hidden = StashGeometry.hiddenOrigin(size: size, y: -1000, screen: external, area: external, edge: .right, peek: 0)
        #expect(hidden == CGPoint(x: 1680, y: -1000))
        let peeking = StashGeometry.hiddenOrigin(size: size, y: -1000, screen: external, area: external, edge: .right, peek: 3)
        #expect(peeking.x == 1677)
    }

    @Test func shownAndHiddenOriginsLeft() {
        let size = CGSize(width: 500, height: 400)
        #expect(StashGeometry.shownOrigin(size: size, y: 100, area: builtIn, edge: .left) == CGPoint(x: 0, y: 100))
        let hidden = StashGeometry.hiddenOrigin(size: size, y: 100, screen: builtIn, area: builtIn, edge: .left, peek: 0)
        #expect(hidden == CGPoint(x: -500, y: 100))
    }

    @Test func verticalPositionIsClampedIntoArea() {
        let area = CGRect(x: 0, y: 25, width: 1440, height: 875) // below the menu bar
        let size = CGSize(width: 400, height: 600)
        #expect(StashGeometry.shownOrigin(size: size, y: 0, area: area, edge: .right).y == 25)
        #expect(StashGeometry.shownOrigin(size: size, y: 900, area: area, edge: .right).y == 300)
        // Taller than the area: pinned to the top.
        let tall = CGSize(width: 400, height: 2000)
        #expect(StashGeometry.shownOrigin(size: tall, y: 500, area: area, edge: .right).y == 25)
    }

    @Test func edgeHitTesting() {
        #expect(StashGeometry.isAtEdge(CGPoint(x: 1679, y: -500), screen: external, edge: .right))
        #expect(StashGeometry.isAtEdge(CGPoint(x: 1679.9, y: -1), screen: external, edge: .right))
        #expect(!StashGeometry.isAtEdge(CGPoint(x: 1660, y: -500), screen: external, edge: .right))
        // Same x but below the external display: not on this screen.
        #expect(!StashGeometry.isAtEdge(CGPoint(x: 1679, y: 300), screen: external, edge: .right))
        #expect(StashGeometry.isAtEdge(CGPoint(x: -240, y: -10), screen: external, edge: .left))
    }

    @Test func edgeDiscoveryUsesThePointersDisplay() {
        let screens = [builtIn, external]
        #expect(StashGeometry.edgeScreenIndex(for: CGPoint(x: external.minX + 1, y: external.midY),
                                              screens: screens, edge: .left) == 1)
        #expect(StashGeometry.edgeScreenIndex(for: CGPoint(x: external.maxX - 1, y: external.midY),
                                              screens: screens, edge: .right) == 1)
        #expect(StashGeometry.edgeScreenIndex(for: CGPoint(x: builtIn.minX + 1, y: builtIn.midY),
                                              screens: screens, edge: .left) == 0)
        #expect(StashGeometry.edgeScreenIndex(for: CGPoint(x: builtIn.maxX - 1, y: builtIn.midY),
                                              screens: screens, edge: .right) == 0)
        #expect(StashGeometry.edgeScreenIndex(for: CGPoint(x: 500, y: 500), screens: screens, edge: .left) == nil)
    }

    @Test func bestScreen() {
        let screens = [builtIn, external]
        #expect(StashGeometry.bestScreenIndex(for: CGRect(x: 1080, y: -1000, width: 600, height: 1000), screens: screens) == 1)
        #expect(StashGeometry.bestScreenIndex(for: CGRect(x: 200, y: 33, width: 1200, height: 900), screens: screens) == 0)
        #expect(StashGeometry.bestScreenIndex(for: CGRect(x: 5000, y: 5000, width: 10, height: 10), screens: screens) == nil)
    }

    @Test func distanceFromEdge() {
        let f = CGRect(x: 1080, y: -1000, width: 600, height: 1000)
        #expect(StashGeometry.distanceFromEdge(f, area: external, edge: .right) == 0)
        #expect(StashGeometry.distanceFromEdge(f.offsetBy(dx: -200, dy: 0), area: external, edge: .right) == 200)
    }
}

@Suite struct PolicyTests {
    private func sample(_ t: TimeInterval, edge: Bool = false, inside: Bool = false,
                        button: Bool = false, front: Bool = false) -> StashPolicy.Sample {
        .init(now: t, pointerAtEdge: edge, pointerInWindow: inside, mouseButtonDown: button, targetIsFrontmost: front)
    }

    @Test func revealsOnlyAfterDwellingAtEdge() {
        var p = StashPolicy(revealDelay: 0.1, hideDelay: 0.3)
        #expect(p.update(sample(0, edge: true)) == nil)
        #expect(p.update(sample(0.05, edge: true)) == nil)
        #expect(p.update(sample(0.11, edge: true)) == .reveal(.hover))
        #expect(p.state == .shown(.hover))
    }

    @Test func briefEdgeTouchDoesNotReveal() {
        var p = StashPolicy(revealDelay: 0.1, hideDelay: 0.3)
        _ = p.update(sample(0, edge: true))
        _ = p.update(sample(0.05, edge: false))      // left the edge: dwell timer resets
        #expect(p.update(sample(0.12, edge: true)) == nil)
        #expect(p.update(sample(0.23, edge: true)) == .reveal(.hover))
    }

    @Test func hidesAfterPointerLeavesForHideDelay() {
        var p = StashPolicy(revealDelay: 0, hideDelay: 0.3)
        _ = p.update(sample(0, edge: true))
        #expect(p.update(sample(1, inside: true)) == nil)
        #expect(p.update(sample(2)) == nil)
        #expect(p.update(sample(2.2, inside: true)) == nil)   // came back: timer resets
        #expect(p.update(sample(3)) == nil)
        #expect(p.update(sample(3.31)) == .hide)
        #expect(p.state == .hidden)
    }

    @Test func doesNotHideWhileMouseButtonHeld() {
        var p = StashPolicy(revealDelay: 0, hideDelay: 0.3)
        _ = p.update(sample(0, edge: true))
        #expect(p.update(sample(1, button: true)) == nil)
        #expect(p.update(sample(5, button: true)) == nil)
        #expect(p.update(sample(5.1)) == nil)
        #expect(p.update(sample(5.5)) == .hide)
    }

    @Test func activationRevealHidesWhenAppLosesFocus() {
        var p = StashPolicy()
        #expect(p.targetActivated() == .reveal(.activation))
        #expect(p.update(sample(0, front: true)) == nil)
        #expect(p.update(sample(10, front: true)) == nil)     // pointer elsewhere: stays while focused
        #expect(p.update(sample(11, front: false)) == .hide)
    }

    @Test func clickedSideStaysVisibleWhileItHasKeyboardFocus() {
        var p = StashPolicy(revealDelay: 0, hideDelay: 0.3)
        _ = p.targetActivated()
        _ = p.update(sample(0, inside: true, front: true))
        #expect(p.state == .shown(.hover))
        _ = p.update(sample(1, front: true))
        #expect(p.update(sample(1.4, front: true)) == nil)
        #expect(p.update(sample(2, front: false)) == nil)
        #expect(p.update(sample(2.4, front: false)) == .hide)
    }

    @Test func activationWhileShownIsIgnored() {
        var p = StashPolicy(revealDelay: 0)
        _ = p.update(sample(0, edge: true))
        #expect(p.targetActivated() == nil)
        #expect(p.state == .shown(.hover))
    }


    @Test func bothSidesStayVisibleWithoutRequiringFocus() {
        var left = StashPolicy(revealDelay: 0, hideDelay: 0.3)
        var right = StashPolicy(revealDelay: 0, hideDelay: 0.3)
        left.keepVisible = true
        right.keepVisible = true
        #expect(left.update(sample(0)) == .reveal(.hover))
        #expect(right.update(sample(0)) == .reveal(.hover))
        #expect(left.update(sample(10)) == nil)
        #expect(right.update(sample(10)) == nil)
        left.keepVisible = false
        #expect(left.update(sample(11)) == nil)
        #expect(left.update(sample(11.4)) == .hide)
        #expect(right.state == .shown(.hover))
    }

    @Test func hoverPreviewCanHideWhileAnotherWindowRemainsFocused() {
        var p = StashPolicy(revealDelay: 0, hideDelay: 0.3)
        #expect(p.update(sample(0, edge: true, front: false)) == .reveal(.hover))
        #expect(p.update(sample(1, front: false)) == nil)
        #expect(p.update(sample(1.4, front: false)) == .hide)
    }

    @Test func oppositeEdgesKeepIndependentRevealAndHideState() {
        var left = StashPolicy(revealDelay: 0, hideDelay: 0.3)
        var right = StashPolicy(revealDelay: 0, hideDelay: 0.3)
        #expect(left.update(sample(0, edge: true)) == .reveal(.hover))
        #expect(right.state == .hidden)
        #expect(right.update(sample(1, edge: true)) == .reveal(.hover))
        #expect(left.update(sample(1)) == nil)
        #expect(left.update(sample(1.4)) == .hide)
        #expect(right.state == .shown(.hover))
        left.reset()
        #expect(right.state == .shown(.hover))
    }
}

@Suite struct WidthPresetTests {
    @Test func widths() {
        #expect(WidthPreset.current.width(forAreaWidth: 1920) == nil)
        #expect(WidthPreset.minimum.width(forAreaWidth: 1920) == 1)
        #expect(WidthPreset.quarter.width(forAreaWidth: 1920) == 480)
        #expect(WidthPreset.third.width(forAreaWidth: 1920) == 640)
        #expect(WidthPreset.half.width(forAreaWidth: 1366) == 683)
        #expect(WidthPreset.threeQuarters.width(forAreaWidth: 1366) == 1025)   // 1024.5 rounds up
        #expect(WidthPreset.full.width(forAreaWidth: 1920) == 1920)
    }
}
