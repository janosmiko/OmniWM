// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices

enum HostEffects {
    nonisolated(unsafe) static var isEnabled = true

    @discardableResult
    static func warpCursor(to point: CGPoint) -> CGError {
        isEnabled ? CGWarpMouseCursorPosition(point) : .success
    }

    static func post(_ event: CGEvent?, tap: CGEventTapLocation) {
        if isEnabled { event?.post(tap: tap) }
    }

    // A skipped AX write reports what an unreachable app reports, so callers treat the element as stale.
    static func setAXAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        isEnabled ? AXUIElementSetAttributeValue(element, attribute, value) : .cannotComplete
    }

    static func performAXAction(_ element: AXUIElement, _ action: CFString) -> AXError {
        isEnabled ? AXUIElementPerformAction(element, action) : .cannotComplete
    }
}
