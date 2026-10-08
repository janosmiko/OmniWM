// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NativeEdgeResizeTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let gap: CGFloat = 10

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

        var dwindle: DwindleLayoutEngine {
            controller.dwindleEngine!
        }

        func entry(_ token: WindowToken) -> WindowState {
            controller.workspaceManager.entry(for: token)!
        }

        func niriFrame(_ token: WindowToken) -> CGRect? {
            niri.findNode(for: token, in: workspaceId).flatMap { $0.renderedFrame ?? $0.frame }
        }

        func dwindleFrame(_ token: WindowToken) -> CGRect? {
            dwindle.presentedFrame(for: token, in: workspaceId, at: 0)
        }
    }

    func testNiriRightEdgeDragWidensColumnAndSurvivesLayoutPass() throws {
        let fixture = try makeNiriFixture()
        let token = fixture.tokens[0]
        let frame = try XCTUnwrap(fixture.niriFrame(token))
        let widthBefore = fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth

        try releaseNativeDrag(
            fixture, token: token, from: frame, to: resized(frame, maxX: 120),
            pressAt: CGPoint(x: frame.maxX - 2, y: frame.midY)
        )

        let column = fixture.niri.columns(in: fixture.workspaceId)[0]
        XCTAssertEqual(column.settledWidth, widthBefore + 120, accuracy: 1)
        assertResizeFinished(fixture)
        XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        try layoutNiri(fixture)
        XCTAssertEqual(column.settledWidth, widthBefore + 120, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(fixture.niriFrame(token)).width, frame.width + 120, accuracy: 1)
    }

    func testNiriLeftEdgeDragWidensColumn() throws {
        let fixture = try makeNiriFixture()
        let token = fixture.tokens[1]
        let frame = try XCTUnwrap(fixture.niriFrame(token))
        let widthBefore = fixture.niri.columns(in: fixture.workspaceId)[1].settledWidth

        try releaseNativeDrag(
            fixture, token: token, from: frame, to: resized(frame, minX: -80),
            pressAt: CGPoint(x: frame.minX + 2, y: frame.midY)
        )

        let column = fixture.niri.columns(in: fixture.workspaceId)[1]
        XCTAssertEqual(column.settledWidth, widthBefore + 80, accuracy: 1)
        assertResizeFinished(fixture)
        try layoutNiri(fixture)
        XCTAssertEqual(try XCTUnwrap(fixture.niriFrame(token)).width, frame.width + 80, accuracy: 1)
    }

    func testNiriBottomEdgeDragGrowsWindowInStackedColumn() throws {
        let fixture = try makeNiriFixture(stackSecondWindow: true)
        let frames = try fixture.tokens.map { try XCTUnwrap(fixture.niriFrame($0)) }
        let topIndex = frames[0].maxY > frames[1].maxY ? 0 : 1
        let top = fixture.tokens[topIndex]
        let bottom = fixture.tokens[1 - topIndex]
        let topFrame = frames[topIndex]
        let bottomFrame = frames[1 - topIndex]
        let widthBefore = fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth

        try releaseNativeDrag(
            fixture, token: top, from: topFrame, to: resized(topFrame, minY: -100),
            pressAt: CGPoint(x: topFrame.midX, y: topFrame.minY + 2)
        )

        assertResizeFinished(fixture)
        try layoutNiri(fixture)
        let topAfter = try XCTUnwrap(fixture.niriFrame(top))
        let bottomAfter = try XCTUnwrap(fixture.niriFrame(bottom))
        XCTAssertGreaterThan(topAfter.height, topFrame.height + 30)
        XCTAssertLessThan(bottomAfter.height, bottomFrame.height - 30)
        XCTAssertEqual(topAfter.maxY, topFrame.maxY, accuracy: 1)
        XCTAssertEqual(fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth, widthBefore, accuracy: 1)
    }

    func testDwindleRightEdgeDragMovesSplitRatio() throws {
        let fixture = try makeDwindleFixture()
        let first = fixture.tokens[0]
        let firstFrame = try XCTUnwrap(fixture.dwindleFrame(first))
        let secondFrame = try XCTUnwrap(fixture.dwindleFrame(fixture.tokens[1]))
        XCTAssertLessThan(firstFrame.maxX, secondFrame.minX)

        try releaseNativeDrag(
            fixture, token: first, from: firstFrame, to: resized(firstFrame, maxX: 100),
            pressAt: CGPoint(x: firstFrame.maxX - 2, y: firstFrame.midY)
        )

        assertResizeFinished(fixture)
        relayoutDwindle(fixture)
        XCTAssertEqual(try XCTUnwrap(fixture.dwindleFrame(first)).width, firstFrame.width + 100, accuracy: 2)
        XCTAssertEqual(
            try XCTUnwrap(fixture.dwindleFrame(fixture.tokens[1])).width,
            secondFrame.width - 100,
            accuracy: 2
        )
    }

    func testPositionOnlyTitleBarMoveStillSnapsBack() throws {
        let fixture = try makeNiriFixture()
        let token = fixture.tokens[0]
        let frame = try XCTUnwrap(fixture.niriFrame(token))
        let widthBefore = fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth

        try releaseNativeDrag(
            fixture, token: token, from: frame, to: frame.offsetBy(dx: 40, dy: -30),
            pressAt: CGPoint(x: frame.midX, y: frame.maxY - 14)
        )

        XCTAssertEqual(fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth, widthBefore)
        XCTAssertNil(fixture.niri.interactiveResize)
        XCTAssertFalse(fixture.handler.state.isResizing)
        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .immediateRelayout)
        XCTAssertEqual(pending.reason, .interactiveGesture)
        XCTAssertEqual(pending.affectedWorkspaceIds, [fixture.workspaceId])
        if case .awaitingCorrection? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("a position-only move must still request the snap-back correction")
        }
    }

    func testEdgePressOutsideFrameTracksNearestWindowAndAdoptsWidth() throws {
        let fixture = try makeNiriFixture()
        let token = fixture.tokens[0]
        let frame = try XCTUnwrap(fixture.niriFrame(token))
        let widthBefore = fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth
        let handlePoint = CGPoint(x: frame.maxX + 2, y: frame.midY)
        XCTAssertNil(fixture.niri.hitTestTiled(point: handlePoint, in: fixture.workspaceId))
        let resizedFrame = resized(frame, maxX: 90)
        fixture.controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        fixture.handler.nativeWindowFrameProvider = { _ in resizedFrame }

        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: handlePoint, modifiers: []))
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry(token)))
        if case .dragging? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("the first frame change of the edge-pressed window must claim the drag")
        }
        fixture.handler.dispatchMouseUp(at: CGPoint(x: handlePoint.x + 90, y: handlePoint.y))

        XCTAssertEqual(fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth, widthBefore + 90, accuracy: 1)
        assertResizeFinished(fixture)
    }

    func testEdgeResizeWhoseFirstFrameChangeArrivesAfterReleaseIsAdopted() throws {
        let fixture = try makeNiriFixture()
        let token = fixture.tokens[0]
        let frame = try XCTUnwrap(fixture.niriFrame(token))
        let widthBefore = fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth
        let handlePoint = CGPoint(x: frame.maxX + 2, y: frame.midY)
        fixture.handler.nativeWindowFrameProvider = { _ in self.resized(frame, maxX: 90) }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: handlePoint, modifiers: []))

        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: CGPoint(x: handlePoint.x + 90, y: handlePoint.y))
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry(token)))

        XCTAssertEqual(fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth, widthBefore + 90, accuracy: 1)
        assertResizeFinished(fixture)
        try layoutNiri(fixture)
        XCTAssertEqual(try XCTUnwrap(fixture.niriFrame(token)).width, frame.width + 90, accuracy: 1)
    }

    func testTitleBarMoveOfSizeLimitedAppSnapsBackWithoutResize() throws {
        let fixture = try makeNiriFixture()
        let token = fixture.tokens[0]
        let frame = try XCTUnwrap(fixture.niriFrame(token))
        let widthBefore = fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth
        let appLimitedFrame = CGRect(
            x: frame.minX + 50, y: frame.minY - 20, width: frame.width - 30, height: frame.height
        )

        try releaseNativeDrag(
            fixture, token: token, from: frame, to: appLimitedFrame,
            pressAt: CGPoint(x: frame.midX, y: frame.maxY - 14)
        )

        XCTAssertEqual(fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth, widthBefore)
        XCTAssertNil(fixture.niri.interactiveResize)
        if case .awaitingCorrection? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("a title-bar move must keep the snap-back correction")
        }
    }

    func testPressInMiddleOfNarrowGapAdoptsLeftWindowResize() throws {
        let fixture = try makeNiriFixture(gap: 4)
        let left = fixture.tokens[0]
        let frame = try XCTUnwrap(fixture.niriFrame(left))
        let rightFrame = try XCTUnwrap(fixture.niriFrame(fixture.tokens[1]))
        XCTAssertEqual(rightFrame.minX - frame.maxX, 4, accuracy: 0.5)
        let widthBefore = fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth
        let gapMiddle = CGPoint(x: frame.maxX + 2, y: frame.midY)
        fixture.handler.nativeWindowFrameProvider = { _ in self.resized(frame, maxX: 60) }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }

        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: gapMiddle, modifiers: []))
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry(left)))
        fixture.handler.dispatchMouseUp(at: CGPoint(x: gapMiddle.x + 60, y: gapMiddle.y))

        XCTAssertEqual(fixture.niri.columns(in: fixture.workspaceId)[0].settledWidth, widthBefore + 60, accuracy: 1)
        assertResizeFinished(fixture)
    }

    private func resized(
        _ frame: CGRect,
        minX: CGFloat = 0,
        maxX: CGFloat = 0,
        minY: CGFloat = 0,
        maxY: CGFloat = 0
    ) -> CGRect {
        CGRect(
            x: frame.minX + minX,
            y: frame.minY + minY,
            width: frame.width - minX + maxX,
            height: frame.height - minY + maxY
        )
    }

    private func releaseNativeDrag(
        _ fixture: Fixture,
        token: WindowToken,
        from frame: CGRect,
        to observedFrame: CGRect,
        pressAt press: CGPoint
    ) throws {
        fixture.controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        fixture.handler.nativeWindowFrameProvider = { _ in observedFrame }
        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(at: press, modifiers: [], windowIdUnderPointer: token.windowId)
        )
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: press.x + 5, y: press.y))
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: fixture.entry(token)))
        if case .dragging? = fixture.handler.state.nativeTitleBarDrag?.phase {
        } else {
            XCTFail("plain native drag must be active before release")
        }
        fixture.handler.dispatchMouseUp(at: observedFrame.center)
    }

    private func assertResizeFinished(_ fixture: Fixture, line: UInt = #line) {
        XCTAssertFalse(fixture.handler.state.isResizing, line: line)
        XCTAssertNil(fixture.handler.state.resizeLayout, line: line)
        XCTAssertNil(fixture.handler.state.activeInteractionSource, line: line)
        XCTAssertNil(fixture.handler.state.capturedInteractionButton, line: line)
        XCTAssertNil(fixture.controller.niriEngine?.interactiveResize, line: line)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize, line: line)
    }

    private func layoutNiri(_ fixture: Fixture) throws {
        let plans = fixture.controller.workspaceManager.withBatchedLayoutBuild {
            fixture.controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspaceId])
        }
        XCTAssertNotNil(plans.first { $0.workspaceId == fixture.workspaceId })
    }

    private func relayoutDwindle(_ fixture: Fixture) {
        let monitor = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)!
        _ = fixture.dwindle.calculateLayout(
            for: fixture.workspaceId,
            screen: fixture.controller.insetWorkingFrame(for: monitor)
        )
        fixture.dwindle.cancelAnimations(in: fixture.workspaceId)
    }

    private func makeNiriFixture(stackSecondWindow: Bool = false, gap: CGFloat? = nil) throws -> Fixture {
        let gap = gap ?? self.gap
        let (controller, workspaceId, monitor) = try makeController(layoutType: .niri, gap: gap)
        controller.niriLayoutHandler.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        let tokens = [addWindow(201, controller, workspaceId), addWindow(202, controller, workspaceId)]
        var fixture = Fixture(controller: controller, workspaceId: workspaceId, tokens: tokens)
        try layoutNiri(fixture)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        try layoutNiri(fixture)
        if stackSecondWindow {
            let engine = fixture.niri
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                XCTAssertTrue(engine.consumeWindowIntoColumn(
                    focusedColumn: engine.columns(in: workspaceId)[0],
                    context: .init(
                        workspaceId: workspaceId,
                        motion: .disabled,
                        workingFrame: controller.insetWorkingFrame(for: monitor),
                        gaps: gap,
                        orientation: .horizontal
                    ),
                    state: &state
                ))
            }
            fixture = Fixture(controller: controller, workspaceId: workspaceId, tokens: tokens)
            try layoutNiri(fixture)
            XCTAssertEqual(engine.columns(in: workspaceId).count, 1)
        } else {
            XCTAssertEqual(fixture.niri.columns(in: workspaceId).count, 2)
        }
        for token in tokens {
            controller.axManager.confirmFrameWrite(for: token.windowId, frame: try XCTUnwrap(fixture.niriFrame(token)))
        }
        startServices(controller, workspaceId: workspaceId)
        return fixture
    }

    private func makeDwindleFixture() throws -> Fixture {
        let (controller, workspaceId, monitor) = try makeController(layoutType: .dwindle, gap: gap)
        controller.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        var tokens: [WindowToken] = []
        for windowId in 301 ... 302 {
            let token = addWindow(windowId, controller, workspaceId)
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
            tokens.append(token)
        }
        _ = engine.calculateLayout(for: workspaceId, screen: controller.insetWorkingFrame(for: monitor))
        engine.cancelAnimations(in: workspaceId)
        for token in tokens {
            let frame = try XCTUnwrap(engine.presentedFrame(for: token, in: workspaceId, at: 0))
            controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
        }
        startServices(controller, workspaceId: workspaceId)
        return Fixture(controller: controller, workspaceId: workspaceId, tokens: tokens)
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

    private func makeController(
        layoutType: LayoutType,
        gap: CGFloat
    ) throws -> (WMController, WorkspaceDescriptor.ID, Monitor) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNativeEdgeResizeTests-\(UUID().uuidString)", isDirectory: true)
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
        settings.gaps.outerGapLeft = 0
        settings.gaps.outerGapRight = 0
        settings.gaps.outerGapTop = 0
        settings.gaps.outerGapBottom = 0
        settings.gestures.windowResizeEnabled = false
        let monitor = Monitor(
            id: .init(displayId: 57_101), displayId: 57_101,
            frame: workingFrame, visibleFrame: workingFrame, hasNotch: false, name: "Native Edge Resize"
        )
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: layoutType
            )
        ]
        let controller = WMController(settings: settings)
        controller.setGapSize(gap, publishChange: false)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        return (controller, workspaceId, monitor)
    }
}
