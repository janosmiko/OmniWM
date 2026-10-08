// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class OrderedOutWindowRetirementTests: XCTestCase {
    func testExhaustedFocusActivationRescansTheOwningApp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_001), windowId: 913_101),
            pid: 913_001,
            windowId: 913_101,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil

        for _ in 0 ... AXEventHandler.activationRetryLimit {
            controller.axEventHandler.handleActivationFactsResolved(
                ActivationFacts(
                    pid: token.pid,
                    source: .focusedWindowChanged,
                    origin: .retry,
                    observationGeneration: 0,
                    requestedAtSeq: UInt64.max,
                    focusedWindow: nil
                )
            )
        }

        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        let refresh = try XCTUnwrap(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertEqual(refresh.kind, .fullRescan)
        XCTAssertEqual(refresh.rescanScope, .targeted(appPIDs: [token.pid], nativeSpaceIds: []))
    }

    func testOrderedOutManagedWindowRescansItsApp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_005), windowId: 913_105),
            pid: 913_005,
            windowId: 913_105,
            to: workspaceId
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil

        controller.axEventHandler.handleCGSEvent(.orderedOut(windowId: 913_999))
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)

        controller.axEventHandler.handleCGSEvent(.orderedOut(windowId: UInt32(token.windowId)))
        let refresh = try XCTUnwrap(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertEqual(refresh.kind, .fullRescan)
        XCTAssertEqual(refresh.rescanScope, .targeted(appPIDs: [token.pid], nativeSpaceIds: []))
    }

    func testOrderedOutWindowRetiresWhileAnotherAppIsInNativeFullscreen() throws {
        let (controller, token) = try nativeFullscreenMissingWindowFixture(orderedIn: false)

        retireMissingWindows(of: token, controller: controller)
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        retireMissingWindows(of: token, controller: controller)

        XCTAssertNil(controller.workspaceManager.entry(for: token))
    }

    func testOrderedInMissingWindowSurvivesWhileAnotherAppIsInNativeFullscreen() throws {
        let (controller, token) = try nativeFullscreenMissingWindowFixture(orderedIn: true)

        retireMissingWindows(of: token, controller: controller)
        retireMissingWindows(of: token, controller: controller)

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }

    func testOrderedOutWindowWithReusedIdSurvivesWhileAnotherAppIsInNativeFullscreen() throws {
        let (controller, token) = try nativeFullscreenMissingWindowFixture(orderedIn: false)
        controller.axEventHandler.windowInfoProvider = {
            WindowServerInfo(id: $0, pid: token.pid + 1, level: 0, frame: .zero)
        }

        retireMissingWindows(of: token, controller: controller)
        retireMissingWindows(of: token, controller: controller)

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }

    func testUnknownWindowSurvivesWhileAnotherAppIsInNativeFullscreen() throws {
        let (controller, token) = try nativeFullscreenMissingWindowFixture(orderedIn: false)
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        retireMissingWindows(of: token, controller: controller)
        retireMissingWindows(of: token, controller: controller)

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }

    func testRescanRetirementOfFocusedWindowRecoversFocus() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let focused = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_006), windowId: 913_106),
            pid: 913_006,
            windowId: 913_106,
            to: workspaceId
        )
        let other = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_007), windowId: 913_107),
            pid: 913_007,
            windowId: 913_107,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                focused,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil

        let handler = controller.axEventHandler
        handler.retireManagedWindowFromAuthoritativeRescan(
            try XCTUnwrap(controller.workspaceManager.entry(for: other))
        )
        handler.retireManagedWindowFromAuthoritativeRescan(
            try XCTUnwrap(controller.workspaceManager.entry(for: focused))
        )

        let layoutState = controller.layoutRefreshController.layoutState
        let payloads = (layoutState.activeRefresh?.windowRemovalPayloads ?? [])
            + (layoutState.pendingRefresh?.windowRemovalPayloads ?? [])
        XCTAssertEqual(payloads.map(\.shouldRecoverFocus), [false, true])
    }

    func testRescanRetirementRecoversFocusAfterAppReportedNoFocusedWindow() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_008), windowId: 913_108),
            pid: 913_008,
            windowId: 913_108,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: UInt64.max,
                focusedWindow: nil
            )
        )
        XCTAssertEqual(
            controller.workspaceManager.nativeFocusOwner,
            .external(pid: token.pid, windowId: nil)
        )
        controller.layoutRefreshController.layoutState.activeRefresh = nil

        controller.axEventHandler.retireManagedWindowFromAuthoritativeRescan(
            try XCTUnwrap(controller.workspaceManager.entry(for: token))
        )

        let layoutState = controller.layoutRefreshController.layoutState
        let payloads = (layoutState.activeRefresh?.windowRemovalPayloads ?? [])
            + (layoutState.pendingRefresh?.windowRemovalPayloads ?? [])
        XCTAssertEqual(payloads.map(\.shouldRecoverFocus), [true])
        XCTAssertFalse(controller.shouldSuppressManagedFocusRecovery)
    }

    func testFrontmostAppLosingItsFocusedWindowRescansThatApp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_002), windowId: 913_102),
            pid: 913_002,
            windowId: 913_102,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: UInt64.max,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, token)
        let refresh = try XCTUnwrap(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertEqual(refresh.kind, .fullRescan)
        XCTAssertEqual(refresh.rescanScope, .targeted(appPIDs: [token.pid], nativeSpaceIds: []))
    }

    func testWindowlessForeignAppTakingFrontDoesNotRescanTheFocusedApp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_003), windowId: 913_103),
            pid: 913_003,
            windowId: 913_103,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil
        controller.axEventHandler.previouslyFocusedManagedToken = token

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: 913_903,
                source: .cgsFrontAppChanged,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: UInt64.max,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, token)
        XCTAssertEqual(
            controller.workspaceManager.nativeFocusOwner,
            .external(pid: 913_903, windowId: nil)
        )
        XCTAssertNil(controller.workspaceManager.externalFocusToken)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(controller.axEventHandler.previouslyFocusedManagedToken, token)
    }

    func testConcreteExternalFocusRescansBeforeSameManagedWindowReturns() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let managedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_004), windowId: 913_104),
            pid: 913_004,
            windowId: 913_104,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                managedToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil
        controller.axEventHandler.previouslyFocusedManagedToken = managedToken

        let unmanagedToken = WindowToken(pid: 913_904, windowId: 913_194)
        XCTAssertTrue(
            controller.workspaceManager.recordExternalFocus(
                pid: unmanagedToken.pid,
                windowId: unmanagedToken.windowId
            )
        )
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, managedToken)
        XCTAssertEqual(controller.workspaceManager.externalFocusToken, unmanagedToken)
        XCTAssertTrue(controller.shouldSuppressManagedFocusRecovery)

        controller.axEventHandler.rescanAppThatLostFocus()

        let refresh = try XCTUnwrap(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertEqual(refresh.kind, .fullRescan)
        XCTAssertEqual(
            refresh.rescanScope,
            .targeted(appPIDs: [managedToken.pid], nativeSpaceIds: [])
        )
        XCTAssertNil(controller.axEventHandler.previouslyFocusedManagedToken)

        controller.layoutRefreshController.layoutState.activeRefresh = nil
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                managedToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.axEventHandler.rescanAppThatLostFocus()

        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(controller.axEventHandler.previouslyFocusedManagedToken, managedToken)
    }

    private func nativeFullscreenMissingWindowFixture(
        orderedIn: Bool
    ) throws -> (WMController, WindowToken) {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let fullscreen = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_010), windowId: 913_110),
            pid: 913_010,
            windowId: 913_110,
            to: workspaceId
        )
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenEnter(fullscreen, in: workspaceId))
        XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(fullscreen, ownsNativeFocus: false))
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_011), windowId: 913_111),
            pid: 913_011,
            windowId: 913_111,
            to: workspaceId
        )
        controller.axEventHandler.windowInfoProvider = {
            WindowServerInfo(id: $0, pid: token.pid, level: 0, frame: .zero, attributes: orderedIn ? 0x2 : 0)
        }
        return (controller, token)
    }

    private func retireMissingWindows(of token: WindowToken, controller: WMController) {
        var progress = FullRescanProgress(affectedWorkspaceIds: [])
        controller.layoutRefreshController.retireFullRescanWindows(
            context: FullRescanMutationContext(
                controller: controller,
                enumerationSnapshot: AXManager.FullRescanEnumerationSnapshot(
                    windows: [],
                    successfullyEnumeratedPIDs: [token.pid],
                    failedPIDs: [],
                    authoritativeTargetPIDs: [token.pid],
                    exactWindowIds: nil,
                    identityAliasesByWindowId: [:],
                    windowServerInfoByWindowId: [:]
                ),
                scope: .targeted(appPIDs: [token.pid], nativeSpaceIds: []),
                focusedWorkspaceId: nil,
                screenFrames: []
            ),
            hadNativeFullscreenLifecycleContextAtStart: true,
            permitsMissingRetirement: true,
            progress: &progress
        )
    }
}
