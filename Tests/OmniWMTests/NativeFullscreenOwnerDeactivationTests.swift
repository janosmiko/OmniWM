// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NativeFullscreenOwnerDeactivationTests: XCTestCase {
    func testFullscreenOwnerDeactivationKeepsPendingFocusOnOtherWorkspace() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMFullscreenOwnerDeactivationTests")
        let manager = controller.workspaceManager
        let monitor = Monitor(
            id: .init(displayId: 55_902),
            displayId: 55_902,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Fullscreen Owner Deactivation"
        )
        manager.applyMonitorConfigurationChange([monitor])
        let fullscreenWorkspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let otherWorkspaceId = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        let fullscreenToken = WindowToken(pid: 559_011, windowId: 559_111)
        let otherToken = WindowToken(pid: 559_012, windowId: 559_112)
        for (token, workspaceId) in [(fullscreenToken, fullscreenWorkspaceId), (otherToken, otherWorkspaceId)] {
            _ = manager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token),
                pid: token.pid,
                windowId: token.windowId,
                to: workspaceId
            )
        }
        XCTAssertTrue(manager.markNativeFullscreenSuspended(fullscreenToken))
        _ = manager.recordExternalFocus(pid: fullscreenToken.pid, windowId: fullscreenToken.windowId)
        XCTAssertEqual(manager.activeNativeFullscreenFocusOwnerToken, fullscreenToken)
        XCTAssertTrue(manager.beginManagedFocusRequest(otherToken, in: otherWorkspaceId, requestId: 1))

        controller.axEventHandler.handleAppDeactivated(pid: fullscreenToken.pid)

        XCTAssertEqual(manager.pendingFocusedToken, otherToken)
        XCTAssertNil(manager.activeNativeFullscreenFocusOwnerToken)
    }
}
