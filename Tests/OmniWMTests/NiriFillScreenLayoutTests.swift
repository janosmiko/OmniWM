// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriFillScreenLayoutTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let gap: CGFloat = 10

    func testOpeningAndClosingWindowKeepsScreenFilled() throws {
        let (controller, workspaceId) = try makeNiriController(fillsScreen: true)
        let first = addWindow(windowId: 201, to: workspaceId, controller: controller)
        let second = addWindow(windowId: 202, to: workspaceId, controller: controller)
        try layout(workspaceId, controller: controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let third = addWindow(windowId: 203, to: workspaceId, controller: controller)
        try layout(workspaceId, controller: controller)
        let opened = try visibleFrames([first, second, third], in: workspaceId, controller: controller)
        XCTAssertEqual(opened.map(\.width).sorted(), [spanWidth(0.25), spanWidth(0.25), spanWidth(0.5)])

        _ = controller.workspaceManager.removeWindow(pid: third.pid, windowId: third.windowId)
        try layout(workspaceId, controller: controller)
        let closed = try visibleFrames([first, second], in: workspaceId, controller: controller)
        XCTAssertEqual(closed.map(\.width), [spanWidth(0.5), spanWidth(0.5)])
    }

    func testOpeningSecondWindowNextToSingleWindowFitsBoth() throws {
        for firstWidth: ProportionalSize? in [nil, .fixed(spanWidth(0.8)), .proportion(0.99)] {
            let (controller, workspaceId) = try makeNiriController(fillsScreen: true)
            controller.settings.niri.alwaysCenterSingleColumn = true
            controller.settings.niri.singleWindowFit = SingleWindowFit(mode: .fill)
            controller.settings.niri.visibleContainerCount = 2
            controller.settings.niri.containerPrimarySpanPresets = [0.99, 0.5, 0.33]
            controller.niriLayoutHandler.enableNiriLayout()
            let first = addWindow(windowId: 201, to: workspaceId, controller: controller)
            try layout(workspaceId, controller: controller)
            controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
            if let firstWidth {
                let engine = try XCTUnwrap(controller.niriEngine)
                let column = try XCTUnwrap(engine.findNode(for: first, in: workspaceId)
                    .flatMap { engine.column(of: $0) })
                column.width = firstWidth
                try layout(workspaceId, controller: controller)
            }

            let second = addWindow(windowId: 202, to: workspaceId, controller: controller)
            try layout(workspaceId, controller: controller)

            _ = try visibleFrames([first, second], in: workspaceId, controller: controller)
        }
    }

    func testColumnThatOutgrowsScreenIsScaledBack() throws {
        let (controller, workspaceId) = try makeNiriController(fillsScreen: true)
        let tokens = (201 ... 203).map { addWindow(windowId: $0, to: workspaceId, controller: controller) }
        try layout(workspaceId, controller: controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        try setManualWidth(0.9, of: tokens[1], in: workspaceId, controller: controller)
        try layout(workspaceId, controller: controller)

        _ = try visibleFrames(tokens, in: workspaceId, controller: controller)
    }

    func testShiftedNarrowColumnsAreRefitted() throws {
        let (controller, workspaceId) = try makeNiriController(fillsScreen: true)
        let tokens = (201 ... 202).map { addWindow(windowId: $0, to: workspaceId, controller: controller) }
        try layout(workspaceId, controller: controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        for token in tokens {
            try setManualWidth(0.34, of: token, in: workspaceId, controller: controller)
        }
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { $0.jumpOffset(to: $0.viewOffset - 200) }
        try layout(workspaceId, controller: controller)

        _ = try visibleFrames(tokens, in: workspaceId, controller: controller)
    }

    func testLiveMouseResizeIsNotRefitted() throws {
        let (controller, workspaceId) = try makeNiriController(fillsScreen: true)
        let tokens = (201 ... 202).map { addWindow(windowId: $0, to: workspaceId, controller: controller) }
        try layout(workspaceId, controller: controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let engine = try XCTUnwrap(controller.niriEngine)
        let node = try XCTUnwrap(engine.findNode(for: tokens[0], in: workspaceId))
        XCTAssertTrue(engine.interactiveResizeBegin(
            windowId: node.id, edges: .right, startLocation: .zero, in: workspaceId, orientation: .horizontal
        ))

        let resized = try setManualWidth(0.3, of: tokens[0], in: workspaceId, controller: controller)
        try layout(workspaceId, controller: controller)

        XCTAssertEqual(resized.settledWidth, spanWidth(0.3), accuracy: 0.5)
        engine.clearInteractiveResize()
    }

    func testFullWidthColumnIsNotRefitted() throws {
        let (controller, workspaceId) = try makeNiriController(fillsScreen: true)
        let tokens = (201 ... 202).map { addWindow(windowId: $0, to: workspaceId, controller: controller) }
        try layout(workspaceId, controller: controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let full = try setManualWidth(1, of: tokens[0], in: workspaceId, controller: controller)
        _ = full.toggleFullWidthSpec()
        try layout(workspaceId, controller: controller)

        XCTAssertTrue(full.isFullWidth)
        XCTAssertEqual(full.settledWidth, spanWidth(1), accuracy: 0.5)
    }

    func testColumnsThatCannotFitAreLeftAlone() throws {
        let (controller, workspaceId) = try makeNiriController(fillsScreen: true)
        let tokens = (201 ... 202).map { addWindow(windowId: $0, to: workspaceId, controller: controller) }
        for token in tokens {
            controller.workspaceManager.setCachedConstraints(
                WindowSizeConstraints(minSize: CGSize(width: 900, height: 1), maxSize: .zero, isFixed: false),
                for: token
            )
        }
        try layout(workspaceId, controller: controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let engine = try XCTUnwrap(controller.niriEngine)
        let column = try XCTUnwrap(engine.columns(in: workspaceId).first)
        column.presetWidthIdx = 1

        try layout(workspaceId, controller: controller)

        // A refit rewrites every column width, and that clears the preset index.
        XCTAssertEqual(column.presetWidthIdx, 1)
    }

    func testPresetCycleKeepsScreenFilled() throws {
        let (controller, workspaceId) = try makeNiriController(fillsScreen: true)
        let tokens = (201 ... 202).map { addWindow(windowId: $0, to: workspaceId, controller: controller) }
        try layout(workspaceId, controller: controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let engine = try XCTUnwrap(controller.niriEngine)
        let selected = try XCTUnwrap(engine.findNode(for: tokens[1], in: workspaceId))
        let firstWidth = engine.columns(in: workspaceId)[0].settledWidth
        controller.workspaceManager.withNiriViewportState(for: workspaceId) {
            $0.selectedNodeId = selected.id
            $0.activeColumnIndex = 1
            $0.jumpOffset(to: $0.viewOffset - firstWidth - gap)
        }

        controller.niriLayoutHandler.cycleSize(forward: true)
        try layout(workspaceId, controller: controller)

        let frames = try visibleFrames(tokens, in: workspaceId, controller: controller)
        XCTAssertEqual(frames[1].width, spanWidth(2.0 / 3.0), accuracy: 0.5)
    }

    func testClosingWindowWhileSettingIsOffDoesNotRefillLater() throws {
        let (controller, workspaceId) = try makeNiriController(fillsScreen: true)
        let first = addWindow(windowId: 201, to: workspaceId, controller: controller)
        let second = addWindow(windowId: 202, to: workspaceId, controller: controller)
        let third = addWindow(windowId: 203, to: workspaceId, controller: controller)
        try layout(workspaceId, controller: controller)

        controller.settings.niri.fillScreenOnResize = false
        _ = controller.workspaceManager.removeWindow(pid: first.pid, windowId: first.windowId)
        try layout(workspaceId, controller: controller)
        controller.settings.niri.fillScreenOnResize = true
        try layout(workspaceId, controller: controller)

        let engine = try XCTUnwrap(controller.niriEngine)
        for token in [second, third] {
            let node = try XCTUnwrap(engine.findNode(for: token, in: workspaceId))
            XCTAssertEqual(engine.column(of: node)?.settledWidth, spanWidth(0.5))
        }
    }

    func testOpeningWindowWithoutSettingKeepsWidths() throws {
        let (controller, workspaceId) = try makeNiriController(fillsScreen: false)
        let first = addWindow(windowId: 201, to: workspaceId, controller: controller)
        try layout(workspaceId, controller: controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        _ = addWindow(windowId: 202, to: workspaceId, controller: controller)
        _ = addWindow(windowId: 203, to: workspaceId, controller: controller)
        try layout(workspaceId, controller: controller)

        let engine = try XCTUnwrap(controller.niriEngine)
        let node = try XCTUnwrap(engine.findNode(for: first, in: workspaceId))
        XCTAssertEqual(engine.column(of: node)?.settledWidth, spanWidth(0.5))
    }

    @discardableResult
    private func setManualWidth(
        _ proportion: CGFloat,
        of token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) throws -> NiriContainer {
        let engine = try XCTUnwrap(controller.niriEngine)
        let column = try XCTUnwrap(engine.findNode(for: token, in: workspaceId).flatMap { engine.column(of: $0) })
        engine.beginManualPrimarySpanResize(column, in: workspaceId, orientation: .horizontal)
        column.width = .fixed(spanWidth(proportion))
        column.cachedWidth = spanWidth(proportion)
        column.targetWidth = nil
        return column
    }

    private func spanWidth(_ proportion: CGFloat) -> CGFloat {
        (workingFrame.width - gap) * proportion - gap
    }

    /// Returns the column frames in screen order and fails unless they fill the working frame.
    private func visibleFrames(
        _ tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        controller: WMController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [CGRect] {
        let engine = try XCTUnwrap(controller.niriEngine)
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let columns = engine.columns(in: workspaceId)
        let viewX = state.containerPosition(
            at: state.activeColumnIndex, containers: columns, gap: gap, sizeKeyPath: \.settledWidth
        ) + state.viewOffset
        let frames = try tokens.map { token in
            let column = try XCTUnwrap(engine.findNode(for: token, in: workspaceId).flatMap { engine.column(of: $0) })
            let index = try XCTUnwrap(columns.firstIndex { $0 === column })
            let x = state.containerPosition(at: index, containers: columns, gap: gap, sizeKeyPath: \.settledWidth)
            return CGRect(x: x - viewX, y: 0, width: column.settledWidth, height: 1)
        }.sorted { $0.minX < $1.minX }
        XCTAssertEqual(frames.first?.minX ?? -1, gap, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(frames.last?.maxX ?? -1, workingFrame.width - gap, accuracy: 0.5, file: file, line: line)
        return frames
    }

    private func makeNiriController(fillsScreen: Bool) throws -> (WMController, WorkspaceDescriptor.ID) {
        let settings = makeSettingsStore()
        settings.borders.enabled = false
        settings.workspaceBar.enabled = false
        settings.gaps.size = Double(gap)
        settings.gaps.outerGapLeft = 0
        settings.gaps.outerGapRight = 0
        settings.gaps.outerGapTop = 0
        settings.gaps.outerGapBottom = 0
        settings.niri.fillScreenOnResize = fillsScreen
        let monitor = Monitor(
            id: .init(displayId: 1), displayId: 1,
            frame: workingFrame, visibleFrame: workingFrame, hasNotch: false, name: "Main"
        )
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        let controller = WMController(settings: settings)
        controller.setGapSize(gap, publishChange: false)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        return (controller, workspaceId)
    }

    private func layout(_ workspaceId: WorkspaceDescriptor.ID, controller: WMController) throws {
        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
        XCTAssertNotNil(plans.first { $0.workspaceId == workspaceId })
    }

    private func addWindow(
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        let pid = pid_t(100 + windowId)
        return controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNiriFillScreenLayoutTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return SettingsStore(
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
    }
}
