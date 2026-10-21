// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriFillScreenEdgeDragRegressionTests: XCTestCase {
    private let displayFrame = CGRect(x: 0, y: 0, width: 2408, height: 1008)
    private let gap: CGFloat = 4

    @MainActor
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        var niri: NiriLayoutEngine {
            controller.niriEngine!
        }

        func entry(_ token: WindowToken) -> WindowState {
            controller.workspaceManager.entry(for: token)!
        }

        func frame(_ token: WindowToken) -> CGRect? {
            controller.niriLayoutHandler.settledFrames(in: workspaceId)?[token]
        }

        var workingFrame: CGRect {
            controller.niriWorkingFrame(for: controller.workspaceManager.monitor(for: workspaceId)!)
        }
    }

    // MARK: - Native left-button drag of column 2's leading edge

    func testTwoNativeLeadingEdgeDragsKeepScreenFilled() throws {
        for focusLeft in [false, true] {
            let fixture = try makeFixture()
            if focusLeft { try focusLeftColumn(fixture) }
            try assertFilled(fixture, "start focusLeft=\(focusLeft)")
            for round in 1 ... 3 {
                let label = "focusLeft=\(focusLeft) drag \(round)"
                try nativeDrag(fixture, token: rightToken(fixture), edge: .leading, by: 120)
                dump(fixture, "\(label) release")
                try assertFilled(fixture, "\(label) release")
                try settle(fixture)
                dump(fixture, "\(label) settled")
                try assertFilled(fixture, "\(label) settled")
                try assertFramesFill(fixture, "\(label) settled")
            }
        }
    }

    func testSweepNativeDragDeltasKeepsFillRecord() throws {
        var failures: [String] = []
        for focusLeft in [false, true] {
            for first in stride(from: CGFloat(-300), through: 300, by: 37.5) where first != 0 {
                for second in [CGFloat(-151), -60.5, -13, 17, 75.25, 160, 233] {
                    let fixture = try makeFixture(log: false)
                    if focusLeft { try focusLeftColumn(fixture) }
                    for (round, (edge, delta)) in [(Edge.leading, first), (.leading, second)].enumerated() {
                        let token = try edge == .leading ? rightToken(fixture) : leftToken(fixture)
                        try nativeDrag(fixture, token: token, edge: edge, by: delta, log: false)
                        try settle(fixture)
                        let recorded = fixture.niri.states[fixture.workspaceId]?.filledColumns ?? []
                        let frames = try orderedTokens(fixture).map { try XCTUnwrap(fixture.frame($0)) }
                        let working = fixture.workingFrame
                        let filled = abs(frames[0].minX - (working.minX + gap)) < 1
                            && abs(frames[1].maxX - (working.maxX - gap)) < 1
                        if recorded.count != 2 || !filled {
                            failures.append(
                                "focusLeft=\(focusLeft) first=\(first) second=\(second) round=\(round + 1) "
                                    + "recorded=\(recorded.count) frames=\(frames.map { ($0.minX, $0.maxX) })"
                            )
                        }
                    }
                }
            }
        }
        XCTAssertEqual(failures, [], failures.prefix(20).joined(separator: "\n"))
    }

    func testTwoNativeTrailingEdgeDragsOfLeftColumnKeepScreenFilled() throws {
        let fixture = try makeFixture()
        for round in 1 ... 2 {
            try nativeDrag(fixture, token: leftToken(fixture), edge: .trailing, by: 120)
            dump(fixture, "trailing drag \(round) release")
            try assertFilled(fixture, "trailing drag \(round) release")
            try layout(fixture)
            try assertFilled(fixture, "trailing drag \(round) layout")
        }
    }

    // MARK: - Event-order scenarios for the second drag

    private struct Scenario {
        var name: String
        var settleFirst = true
        var pointerOnWindow = true
        var focusOnPress = false
        var preserveViewportOnFocus = false
        var midDragLayout = false
        var retireFirst = false
    }

    func testSecondDragScenariosKeepScreenFilled() throws {
        let base = [
            Scenario(name: "baseline"),
            Scenario(name: "gap press, no window id", pointerOnWindow: false),
            Scenario(name: "focus on press", focusOnPress: true),
            Scenario(name: "focus on press, preserve viewport", focusOnPress: true, preserveViewportOnFocus: true),
            Scenario(name: "mid-drag layout", midDragLayout: true),
            Scenario(name: "focus + mid-drag layout", focusOnPress: true, midDragLayout: true),
            Scenario(name: "gap press + mid-drag layout", pointerOnWindow: false, midDragLayout: true)
        ]
        let scenarios = base + base.map { var copy = $0
            copy.settleFirst = false
            copy.retireFirst = true
            copy.name += " / unsettled"
            return copy
        }
        var failures: [String] = []
        for scenario in scenarios {
            for focusLeft in [false, true] {
                for (first, second) in [(CGFloat(120), CGFloat(120)), (-120, 280), (280, -150)] {
                    let fixture = try makeFixture(log: false)
                    if focusLeft { try focusLeftColumn(fixture) }
                    for (round, delta) in [first, second].enumerated() {
                        let label = "\(scenario.name) focusLeft=\(focusLeft) deltas=\(first),\(second) round=\(round + 1)"
                        try scenarioDrag(fixture, scenario: scenario, by: delta)
                        if round == 0, !scenario.settleFirst {
                            try layout(fixture)
                        } else {
                            try settle(fixture)
                        }
                        if round == 1 { try settle(fixture) }
                        let recorded = fixture.niri.states[fixture.workspaceId]?.filledColumns ?? []
                        let frames = try orderedTokens(fixture).map { try XCTUnwrap(fixture.frame($0)) }
                        let working = fixture.workingFrame
                        let filled = abs(frames[0].minX - (working.minX + gap)) < 1
                            && abs(frames[1].maxX - (working.maxX - gap)) < 1
                        if round == 1, recorded.count != 2 || !filled {
                            failures.append("\(label) recorded=\(recorded.count) "
                                + "frames=\(frames.map { (Int($0.minX), Int($0.maxX)) })")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(failures, [], failures.prefix(30).joined(separator: "\n"))
    }

    /// Drives the display-link tick by hand, so drag 2 can start while drag 1's settle animation still runs.
    func testSecondDragDuringOrAfterSettleAnimationKeepsScreenFilled() throws {
        var failures: [String] = []
        for focusLeft in [false, true] {
            for pointerOnWindow in [true, false] {
                for wait in [0.02, 0.08, 0.2, 3.0] {
                    for (first, second) in [(CGFloat(280), CGFloat(120)), (280, -150), (-200, 200)] {
                        let label = "focusLeft=\(focusLeft) onWindow=\(pointerOnWindow) wait=\(wait) "
                            + "deltas=\(first),\(second)"
                        let fixture = try makeFixture(log: false)
                        if focusLeft { try focusLeftColumn(fixture) }
                        fixture.controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
                        var clock = fixture.controller.animationClock.now()
                        try animatedDrag(fixture, by: first, pointerOnWindow: pointerOnWindow, clock: &clock)
                        tick(fixture, until: &clock, plus: wait)
                        try animatedDrag(fixture, by: second, pointerOnWindow: pointerOnWindow, clock: &clock)
                        tick(fixture, until: &clock, plus: 3)
                        try executedLayout(fixture)
                        tick(fixture, until: &clock, plus: 3)
                        let recorded = fixture.niri.states[fixture.workspaceId]?.filledColumns ?? []
                        let frames = try orderedTokens(fixture).map { try XCTUnwrap(fixture.frame($0)) }
                        let working = fixture.workingFrame
                        let filled = abs(frames[0].minX - (working.minX + gap)) < 1
                            && abs(frames[1].maxX - (working.maxX - gap)) < 1
                        if recorded.count != 2 || !filled {
                            failures.append("\(label) recorded=\(recorded.count) "
                                + "frames=\(frames.map { (Int($0.minX), Int($0.maxX)) })")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(failures, [], failures.prefix(30).joined(separator: "\n"))
    }

    private func tick(_ fixture: Fixture, until clock: inout TimeInterval, plus seconds: TimeInterval) {
        let handler = fixture.controller.niriLayoutHandler
        let displayId = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)!.displayId
        let end = clock + seconds
        while clock < end {
            clock = min(end, clock + 1.0 / 60)
            guard handler.hasScrollAnimation(for: fixture.workspaceId) else { continue }
            handler.tickScrollAnimation(targetTime: clock, displayId: displayId)
            try? confirmAppliedFrames(fixture)
        }
    }

    private func animatedDrag(
        _ fixture: Fixture, by delta: CGFloat, pointerOnWindow: Bool, clock: inout TimeInterval
    ) throws {
        let token = try rightToken(fixture)
        let left = try leftToken(fixture)
        let frame = try XCTUnwrap(fixture.frame(token))
        let leftBefore = try XCTUnwrap(fixture.frame(left))
        let observed = CGRect(x: frame.minX + delta, y: frame.minY, width: frame.width - delta, height: frame.height)
        let press = CGPoint(x: frame.minX - 2, y: frame.midY)
        let handler = fixture.handler
        let scrolling = { fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.workspaceId) }
        // Mirrors AXEventHandler.handleFrameChanged: a scrolling workspace drops tiled frame changes.
        let frameChanged = {
            guard !scrolling() else { return }
            if !handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry(token)) {
                try? self.executedLayout(fixture)
            }
        }
        handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        handler.nativeWindowFrameProvider = { ref in ref.windowId == token.windowId ? observed : fixture.frame(left) }
        handler.retireNativeTitleBarDragAtInputBoundary()
        _ = handler.dispatchMouseDown(
            at: press,
            modifiers: [],
            windowIdUnderPointer: pointerOnWindow ? token.windowId : nil
        )
        for step in 1 ... 10 {
            handler.dispatchMouseDragged(at: CGPoint(x: press.x + delta * CGFloat(step) / 10, y: press.y))
            frameChanged()
            tick(fixture, until: &clock, plus: 1.0 / 30)
        }
        let leftDuring = try XCTUnwrap(fixture.frame(left))
        if abs(leftDuring.minX - leftBefore.minX) > 1 {
            print("[edge-drag] left moved during drag: \(Int(leftBefore.minX)) -> \(Int(leftDuring.minX)) "
                + "delta=\(delta) scrolling=\(scrolling())")
        }
        handler.pressedMouseButtonsProvider = { 0 }
        handler.dispatchMouseUp(at: CGPoint(x: press.x + delta, y: press.y))
        frameChanged()
        // The immediate relayout that finishNiriResize and the drag correction request.
        try executedLayout(fixture)
    }

    private func executedLayout(_ fixture: Fixture) throws {
        let plans = fixture.controller.workspaceManager.withBatchedLayoutBuild {
            fixture.controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspaceId])
        }
        for plan in plans {
            _ = fixture.controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(plan)
        }
        try confirmAppliedFrames(fixture)
    }

    private func scenarioDrag(_ fixture: Fixture, scenario: Scenario, by delta: CGFloat) throws {
        let token = try rightToken(fixture)
        let left = try leftToken(fixture)
        let frame = try XCTUnwrap(fixture.frame(token))
        let observed = CGRect(x: frame.minX + delta, y: frame.minY, width: frame.width - delta, height: frame.height)
        let press = CGPoint(x: frame.minX - 2, y: frame.midY)
        let handler = fixture.handler
        handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        handler.nativeWindowFrameProvider = { ref in ref.windowId == token.windowId ? observed : fixture.frame(left) }
        if scenario.retireFirst { handler.retireNativeTitleBarDragAtInputBoundary() }
        _ = handler.dispatchMouseDown(
            at: press, modifiers: [], windowIdUnderPointer: scenario.pointerOnWindow ? token.windowId : nil
        )
        if scenario.focusOnPress {
            let node = try XCTUnwrap(fixture.niri.findNode(for: token, in: fixture.workspaceId))
            var state = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
            fixture.controller.niriLayoutHandler.activateNode(
                node, in: fixture.workspaceId, state: &state,
                options: scenario.preserveViewportOnFocus
                    ? .init(
                        ensureVisible: false,
                        preserveViewportAnchor: true,
                        layoutRefresh: false,
                        axFocus: false,
                        startAnimation: false
                    )
                    : .init(layoutRefresh: false, axFocus: false)
            )
            _ = fixture.controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: fixture.workspaceId,
                    viewportState: state,
                    rememberedFocusToken: nil,
                    plannedSeq: fixture.controller.workspaceManager.worldSeq
                )
            )
            fixture.controller.niriLayoutHandler.cancelAnimationMotion(for: fixture.workspaceId)
            try layout(fixture)
        }
        handler.dispatchMouseDragged(at: CGPoint(x: press.x + 5, y: press.y))
        let claimed = handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry(token))
        if !claimed, !fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.workspaceId) {
            try layout(fixture)
        }
        if scenario.midDragLayout {
            let plans = fixture.controller.workspaceManager.withBatchedLayoutBuild {
                fixture.controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspaceId])
            }
            XCTAssertNotNil(plans.first { $0.workspaceId == fixture.workspaceId })
            let leftFrame = try XCTUnwrap(fixture.frame(left))
            print("[edge-drag] \(scenario.name) mid-drag left=\(Int(leftFrame.minX))..\(Int(leftFrame.maxX)) "
                + "claimed=\(claimed)")
        }
        handler.pressedMouseButtonsProvider = { 0 }
        handler.dispatchMouseUp(at: CGPoint(x: press.x + delta, y: press.y))
        if !claimed {
            _ = handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry(token))
        }
    }

    // MARK: - Option + right-drag (managed resize) of the same edge

    func testTwoManagedLeadingEdgeDragsKeepScreenFilled() throws {
        let fixture = try makeFixture()
        for round in 1 ... 2 {
            let token = try rightToken(fixture)
            let frame = try XCTUnwrap(fixture.frame(token))
            let press = CGPoint(x: frame.minX + 3, y: frame.midY)
            let window = try XCTUnwrap(fixture.niri.findNode(for: token, in: fixture.workspaceId))
            XCTAssertTrue(fixture.handler.beginNiriResize(
                window: window, engine: fixture.niri, wsId: fixture.workspaceId, at: press, source: .mouse(.right)
            ))
            fixture.handler.updateManagedResize(at: CGPoint(x: press.x + 120, y: press.y))
            fixture.handler.completeActiveResize()
            dump(fixture, "managed drag \(round) release")
            try assertFilled(fixture, "managed drag \(round) release")
            try layout(fixture)
            try confirmAppliedFrames(fixture)
            try assertFilled(fixture, "managed drag \(round) layout")
        }
    }

    // MARK: - Helpers

    private enum Edge { case leading, trailing }

    private func rightToken(_ fixture: Fixture) throws -> WindowToken {
        try orderedTokens(fixture).last!
    }

    private func leftToken(_ fixture: Fixture) throws -> WindowToken {
        try orderedTokens(fixture).first!
    }

    private func orderedTokens(_ fixture: Fixture) throws -> [WindowToken] {
        let columns = fixture.niri.columns(in: fixture.workspaceId)
        return try fixture.tokens.sorted { lhs, rhs in
            let index = { (token: WindowToken) throws -> Int in
                let node = try XCTUnwrap(fixture.niri.findNode(for: token, in: fixture.workspaceId))
                let column = try XCTUnwrap(fixture.niri.column(of: node))
                return try XCTUnwrap(columns.firstIndex { $0 === column })
            }
            return try index(lhs) < index(rhs)
        }
    }

    private func nativeDrag(
        _ fixture: Fixture, token: WindowToken, edge: Edge, by delta: CGFloat, log: Bool = true
    ) throws {
        let frame = try XCTUnwrap(fixture.frame(token))
        let observed: CGRect
        let press: CGPoint
        switch edge {
        case .leading:
            observed = CGRect(x: frame.minX + delta, y: frame.minY, width: frame.width - delta, height: frame.height)
            press = CGPoint(x: frame.minX - 2, y: frame.midY)
        case .trailing:
            observed = CGRect(x: frame.minX, y: frame.minY, width: frame.width + delta, height: frame.height)
            press = CGPoint(x: frame.maxX + 2, y: frame.midY)
        }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        fixture.handler.nativeWindowFrameProvider = { _ in observed }
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: press,
            modifiers: [],
            windowIdUnderPointer: token.windowId
        ))
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: press.x + 5, y: press.y))
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry(token)))
        if log { print("[edge-drag] before up: drag=\(String(describing: fixture.handler.state.nativeTitleBarDrag)) "
                + "applied=\(String(describing: fixture.controller.axManager.lastAppliedFrame(for: token.windowId))) "
                + "observed=\(observed) "
                + "scroll=\(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.workspaceId))") }
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: CGPoint(x: press.x + delta, y: press.y))
        XCTAssertFalse(fixture.handler.state.isResizing)
        XCTAssertNil(fixture.niri.interactiveResize)
    }

    private func assertFilled(_ fixture: Fixture, _ label: String, line: UInt = #line) throws {
        let engine = fixture.niri
        let state = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let columns = engine.columns(in: fixture.workspaceId)
        let viewX = state.containerPosition(
            at: state.activeColumnIndex, containers: columns, gap: gap, sizeKeyPath: \.settledWidth
        ) + state.viewOffset
        let xs = columns.indices.map {
            state.containerPosition(at: $0, containers: columns, gap: gap, sizeKeyPath: \.settledWidth) - viewX
        }
        let working = fixture.workingFrame.width
        XCTAssertEqual(xs.first ?? -1, gap, accuracy: 0.5, "\(label): first column left edge", line: line)
        XCTAssertEqual(
            (xs.last ?? 0) + (columns.last?.settledWidth ?? 0),
            working - gap,
            accuracy: 0.5,
            "\(label): last column right edge",
            line: line
        )
    }

    private func dump(_ fixture: Fixture, _ label: String) {
        let engine = fixture.niri
        let state = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let columns = engine.columns(in: fixture.workspaceId)
        let widths = columns.map { String(format: "%.1f", $0.settledWidth) }
        let recorded = engine.states[fixture.workspaceId]?.filledColumns.map { String(format: "%.3f", $0.proportion) }
        let frames = fixture.tokens.map { token in
            fixture.frame(token).map { "(\(Int($0.minX))..\(Int($0.maxX)))" } ?? "nil"
        }
        print(
            "[edge-drag] \(label): active=\(state.activeColumnIndex) offset=\(state.viewOffset) "
                + "widths=\(widths) frames=\(frames) recorded=\(recorded ?? []) "
                + "working=\(fixture.workingFrame)"
        )
    }

    private func focusLeftColumn(_ fixture: Fixture) throws {
        let left = try XCTUnwrap(fixture.niri.findNode(for: leftToken(fixture), in: fixture.workspaceId))
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            let columns = fixture.niri.columns(in: fixture.workspaceId)
            let current = state
            let position = { (index: Int) in
                current.containerPosition(at: index, containers: columns, gap: self.gap, sizeKeyPath: \.settledWidth)
            }
            let viewX = position(state.activeColumnIndex) + state.viewOffset
            state.activeColumnIndex = 0
            state.selectedNodeId = left.id
            state.jumpOffset(to: viewX - position(0))
        }
        try settle(fixture)
    }

    /// Lets every animation finish, runs the correction relayout, and confirms the frames as written.
    private func settle(_ fixture: Fixture) throws {
        let handler = fixture.controller.niriLayoutHandler
        handler.cancelAnimationMotion(for: fixture.workspaceId)
        try layout(fixture)
        handler.cancelAnimationMotion(for: fixture.workspaceId)
        fixture.handler.discardNativeTitleBarDragState()
        try confirmAppliedFrames(fixture)
    }

    private func assertFramesFill(_ fixture: Fixture, _ label: String, line: UInt = #line) throws {
        let frames = try orderedTokens(fixture).map { try XCTUnwrap(fixture.frame($0)) }
        let working = fixture.workingFrame
        XCTAssertEqual(frames.first?.minX ?? -1, working.minX + gap, accuracy: 0.5, "\(label): left frame", line: line)
        XCTAssertEqual(frames.last?.maxX ?? -1, working.maxX - gap, accuracy: 0.5, "\(label): right frame", line: line)
    }

    private func layout(_ fixture: Fixture) throws {
        let plans = fixture.controller.workspaceManager.withBatchedLayoutBuild {
            fixture.controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspaceId])
        }
        XCTAssertNotNil(plans.first { $0.workspaceId == fixture.workspaceId })
        try confirmAppliedFrames(fixture)
    }

    private func confirmAppliedFrames(_ fixture: Fixture) throws {
        for token in fixture.tokens {
            fixture.controller.axManager.confirmFrameWrite(
                for: token.windowId,
                frame: try XCTUnwrap(fixture.frame(token))
            )
        }
    }

    private func makeFixture(log: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMEdgeDragRegression-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        settings.borders.enabled = false
        settings.workspaceBar.enabled = false
        settings.gaps.size = Double(gap)
        settings.gaps.outerGapLeft = 8
        settings.gaps.outerGapRight = 8
        settings.gaps.outerGapTop = 36
        settings.gaps.outerGapBottom = 4
        settings.gestures.windowResizeEnabled = false
        settings.gestures.adoptNativeResize = true
        settings.niri.fillScreenOnResize = true
        settings.niri.edgeGaps = false
        settings.niri.visibleContainerCount = 2
        settings.niri.alwaysCenterSingleColumn = true
        settings.niri.centerFocusedColumn = .never
        settings.niri.singleWindowFit = SingleWindowFit(mode: .fill)
        settings.niri.containerPrimarySpanPresets = [0.99, 0.5, 0.33]
        let monitor = Monitor(
            id: .init(displayId: 57_102), displayId: 57_102,
            frame: displayFrame, visibleFrame: displayFrame, hasNotch: false, name: "AW3423DWF"
        )
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "10",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        let controller = WMController(settings: settings)
        controller.setGapSize(gap, publishChange: false)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "10"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        controller.niriLayoutHandler.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()

        let first = addWindow(201, controller, workspaceId)
        var fixture = Fixture(controller: controller, workspaceId: workspaceId, tokens: [first])
        try layout(fixture)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let second = addWindow(202, controller, workspaceId)
        fixture = Fixture(controller: controller, workspaceId: workspaceId, tokens: [first, second])
        try layout(fixture)
        try layout(fixture)
        XCTAssertEqual(fixture.niri.columns(in: workspaceId).count, 2)
        if log { dump(fixture, "setup") }
        startServices(controller, workspaceId: workspaceId)
        return fixture
    }

    private func addWindow(_ windowId: Int, _ controller: WMController, _ workspaceId: WorkspaceDescriptor.ID)
        -> WindowToken
    {
        let pid = pid_t(100 + windowId)
        return controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: WindowToken(pid: pid, windowId: windowId)),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }

    private func startServices(_ controller: WMController, workspaceId: WorkspaceDescriptor.ID) {
        controller.layoutRefreshController.resetState()
        controller.hasStartedServices = true
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        addTeardownBlock { @MainActor in
            blocker.cancel()
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.axManager.cleanup()
        }
    }
}
