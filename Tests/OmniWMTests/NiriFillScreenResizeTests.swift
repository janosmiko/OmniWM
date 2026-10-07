// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriFillScreenResizeTests: XCTestCase {
    private func assertSplit(
        focused: CGFloat,
        target: CGFloat,
        others: [CGFloat],
        expectedFocused: CGFloat,
        expectedOthers: [CGFloat],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let split = NiriFillScreenSplit(focused: focused, target: target, others: others, minimum: 0.1) else {
            return XCTFail("Expected a split", file: file, line: line)
        }
        XCTAssertEqual(split.focused, expectedFocused, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(split.others.count, expectedOthers.count, file: file, line: line)
        for (actual, expected) in zip(split.others, expectedOthers) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001, file: file, line: line)
        }
    }

    func testGrowTakesSpanFromSingleNeighbor() {
        assertSplit(focused: 0.5, target: 0.55, others: [0.5], expectedFocused: 0.55, expectedOthers: [0.45])
    }

    func testGrowSplitsEvenlyAcrossNeighbors() {
        assertSplit(
            focused: 0.5, target: 0.6, others: [0.25, 0.25],
            expectedFocused: 0.6, expectedOthers: [0.2, 0.2]
        )
    }

    func testShrinkGivesSpanToNeighbors() {
        assertSplit(
            focused: 0.5, target: 0.4, others: [0.25, 0.25],
            expectedFocused: 0.4, expectedOthers: [0.3, 0.3]
        )
    }

    func testGrowStopsWhenNeighborsReachMinimum() {
        assertSplit(focused: 0.8, target: 1.0, others: [0.2], expectedFocused: 0.9, expectedOthers: [0.1])
    }

    func testNeighborAtMinimumPassesRemainderToOthers() {
        assertSplit(
            focused: 0.58, target: 0.68, others: [0.12, 0.3],
            expectedFocused: 0.68, expectedOthers: [0.1, 0.22]
        )
    }

    func testShrinkStopsAtMinimum() {
        assertSplit(focused: 0.15, target: 0.05, others: [0.85], expectedFocused: 0.1, expectedOthers: [0.9])
    }

    func testNoNeighborsHasNoSplit() {
        XCTAssertNil(NiriFillScreenSplit(focused: 0.5, target: 0.6, others: [], minimum: 0.1))
    }

    private let gap: CGFloat = 16
    private let workingFrame = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)

    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let columns: [NiriContainer]
        var state: ViewportState
    }

    /// Three half-width columns with the view scrolled so the last two fill the screen.
    private func makeFixture() -> Fixture {
        let engine = NiriLayoutEngine()
        engine.updateConfiguration(centerFocusedColumn: .never)
        let workspaceId = WorkspaceDescriptor.ID()
        let monitor = Monitor(
            id: Monitor.ID(displayId: 8), displayId: 8,
            frame: workingFrame, visibleFrame: workingFrame, hasNotch: false, name: "Fill screen"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        for index in 0 ..< 3 {
            _ = engine.addWindow(token: WindowToken(pid: 1, windowId: index + 1), to: workspaceId, afterSelection: nil)
        }
        let columnSpan = (workingFrame.width - gap) * 0.5 - gap
        let columns = engine.columns(in: workspaceId)
        for column in columns {
            column.width = .proportion(0.5)
            column.cachedWidth = columnSpan
        }
        var state = ViewportState()
        state.activeColumnIndex = 2
        state.selectedNodeId = columns[2].windowNodes.first?.id
        state.jumpOffset(to: -(workingFrame.width - gap - columnSpan))
        return Fixture(engine: engine, workspaceId: workspaceId, columns: columns, state: state)
    }

    private func growTrailing(_ fixture: inout Fixture) {
        fixture.engine.setContainerPrimarySpan(
            fixture.columns[2],
            change: .adjustProportion(10),
            context: .init(
                workspaceId: fixture.workspaceId, motion: .disabled, workingFrame: workingFrame,
                gaps: gap, orientation: .horizontal
            ),
            state: &fixture.state,
            fillsScreen: true
        )
    }

    func testGrowingTrailingColumnShrinksVisibleNeighborOnly() {
        var fixture = makeFixture()
        growTrailing(&fixture)
        let columns = fixture.columns

        XCTAssertEqual(columns[0].width, .proportion(0.5))
        guard case let .proportion(middle) = columns[1].width,
              case let .proportion(trailing) = columns[2].width
        else { return XCTFail("Expected proportional widths") }
        XCTAssertEqual(middle, 0.4, accuracy: 0.000001)
        XCTAssertEqual(trailing, 0.6, accuracy: 0.000001)
        let middleSpan = (workingFrame.width - gap) * 0.4 - gap
        XCTAssertEqual(fixture.state.viewOffset, -(middleSpan + gap * 2), accuracy: 0.001)
    }

    func testNeighborMinimumWidthLimitsGrowthAndKeepsScreenFilled() {
        var fixture = makeFixture()
        let columns = fixture.columns
        let filledSpan = columns[1].settledWidth + columns[2].settledWidth
        fixture.engine.updateWindowConstraints(
            for: WindowToken(pid: 1, windowId: 2),
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 1_100, height: 1), maxSize: .zero, isFixed: false
            ),
            in: fixture.workspaceId,
            motion: .disabled
        )
        growTrailing(&fixture)

        XCTAssertEqual(columns[1].settledWidth, 1_100, accuracy: 0.001)
        XCTAssertEqual(columns[2].settledWidth, filledSpan - 1_100, accuracy: 0.001)
        XCTAssertEqual(fixture.state.viewOffset, -(1_100 + gap * 2), accuracy: 0.001)
    }
}
