// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@_cdecl("test_isolate_host")
func isolateTestHost() {
    HostEffects.isEnabled = false
    XCTestObservationCenter.shared.addTestObserver(TestHostIsolationObserver.shared)
}

private final class TestHostIsolationObserver: NSObject, XCTestObservation {
    nonisolated(unsafe) static let shared = TestHostIsolationObserver()

    func testBundleWillStart(_: Bundle) {
        MainActor.assumeIsolated {
            _ = NSApplication.shared.setActivationPolicy(.prohibited)
        }
    }
}
