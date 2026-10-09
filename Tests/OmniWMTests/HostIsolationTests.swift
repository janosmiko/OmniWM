// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMTestHostIsolation
import XCTest

@MainActor
final class HostIsolationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard OmniWMTestHostIsIsolated() else {
            throw XCTSkip("An OMNIWM_RUN_*=1 live test gate turns host isolation off")
        }
    }

    func testHostEffectsAreDisabled() {
        XCTAssertFalse(HostEffects.isEnabled)
    }

    func testAXWritesAreSkipped() {
        let system = AXUIElementCreateSystemWide()

        XCTAssertEqual(
            HostEffects.setAXAttribute(system, kAXFocusedUIElementAttribute as CFString, system),
            .cannotComplete
        )
        XCTAssertEqual(HostEffects.performAXAction(system, kAXRaiseAction as CFString), .cannotComplete)
    }

    func testAlertRunModalPicksCancel() {
        let alert = NSAlert()
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        XCTAssertEqual(alert.runModal(), .alertSecondButtonReturn)
    }

    func testResignedWindowIsNotKey() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .titled,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        window.makeKey()
        XCTAssertTrue(OmniWMTestWindowIsKey(window))
        window.resignKey()

        XCTAssertFalse(OmniWMTestWindowIsKey(window))
    }

    func testActivationPolicyStaysProhibited() {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(originalPolicy) }

        NSApp.setActivationPolicy(.accessory)

        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
    }

    func testOrderedFrontWindowReportsVisibleButStaysOffScreen() {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(originalPolicy) }
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertGreaterThan(window.windowNumber, 0)

        window.orderFront(nil)
        CATransaction.flush()

        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(isOnScreen(window))
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
    }

    private func isOnScreen(_ window: NSWindow) -> Bool {
        let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }
}
