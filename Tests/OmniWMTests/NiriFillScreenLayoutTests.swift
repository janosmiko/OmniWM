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
