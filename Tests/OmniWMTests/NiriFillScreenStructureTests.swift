// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriFillScreenStructureTests: XCTestCase {
    private let gap: CGFloat = 16
    private let workingFrame = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)

    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        var state: ViewportState
        var columns: [NiriContainer] {
            engine.columns(in: workspaceId)
        }
    }

    private func span(_ proportion: CGFloat) -> CGFloat {
        (workingFrame.width - gap) * proportion - gap
    }

    /// Columns with the given proportions, the last one active, and the first one at the left edge.
    private func makeFixture(_ proportions: [CGFloat]) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.updateConfiguration(centerFocusedColumn: .never)
        let workspaceId = WorkspaceDescriptor.ID()
        let monitor = Monitor(
            id: Monitor.ID(displayId: 9), displayId: 9,
            frame: workingFrame, visibleFrame: workingFrame, hasNotch: false, name: "Fill screen structure"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        for index in proportions.indices {
            _ = engine.addWindow(token: WindowToken(pid: 1, windowId: index + 1), to: workspaceId, afterSelection: nil)
        }
        let columns = engine.columns(in: workspaceId)
        for (column, proportion) in zip(columns, proportions) {
            column.width = .proportion(proportion)
            column.cachedWidth = span(proportion)
        }
        var state = ViewportState()
        state.activeColumnIndex = columns.count - 1
        state.selectedNodeId = columns.last?.windowNodes.first?.id
        let leadingSpan = proportions.dropLast().reduce(0) { $0 + span($1) + gap }
        state.jumpOffset(to: -(leadingSpan + gap))
        return Fixture(engine: engine, workspaceId: workspaceId, state: state)
    }

    private func context(_ fixture: Fixture) -> NiriInteractionContext {
        .init(
            workspaceId: fixture.workspaceId, motion: .disabled, workingFrame: workingFrame,
            gaps: gap, orientation: .horizontal
        )
    }

    private func assertProportions(
        _ fixture: Fixture,
        _ expected: [CGFloat],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = fixture.columns.map(\.settledWidth)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (width, proportion) in zip(actual, expected) {
            XCTAssertEqual(width, span(proportion), accuracy: 0.01, file: file, line: line)
        }
    }

    private func insertColumn(after selection: NodeId?, into fixture: inout Fixture) throws -> Bool {
        let filled = try XCTUnwrap(fixture.engine.filledVisibleColumns(context: context(fixture), state: fixture.state))
        let window = fixture.engine.addWindow(
            token: WindowToken(pid: 1, windowId: 99), to: fixture.workspaceId, afterSelection: selection
        )
        let column = try XCTUnwrap(fixture.engine.column(of: window))
        column.width = .proportion(0.5)
        // The layout handler moves the active index past a column inserted before it.
        if let index = fixture.columns.firstIndex(where: { $0 === column }), index <= fixture.state.activeColumnIndex {
            fixture.state.activeColumnIndex += 1
        }
        fixture.engine.resolvePrimaryContainerSpans(
            in: fixture.workspaceId, workingFrame: workingFrame, gaps: gap, orientation: .horizontal
        )
        return fixture.engine.fillScreenAfterInsert(
            column, filledBefore: filled, context: context(fixture), state: &fixture.state
        )
    }

    private func removeWindow(_ windowId: Int, from fixture: inout Fixture) {
        fixture.engine.recordFilledColumns(context: context(fixture), state: fixture.state)
        fixture.engine.removeWindows(
            [WindowToken(pid: 1, windowId: windowId)],
            context: context(fixture),
            state: &fixture.state,
            selectedNodeId: fixture.state.selectedNodeId,
            removedNodeIds: []
        )
        XCTAssertTrue(fixture.engine.fillScreenAfterRemoval(context: context(fixture), state: &fixture.state))
    }

    func testPartlyFilledScreenHasNoFilledColumns() {
        let fixture = makeFixture([0.5, 0.3])
        XCTAssertNil(fixture.engine.filledVisibleColumns(context: context(fixture), state: fixture.state))
    }

    func testNewColumnTakesWidthEvenlyFromFilledColumns() throws {
        var fixture = makeFixture([0.73, 0.27])
        XCTAssertTrue(try insertColumn(after: fixture.state.selectedNodeId, into: &fixture))

        assertProportions(fixture, [0.4, 0.1, 0.5])
        XCTAssertEqual(fixture.state.activeColumnIndex, 1)
        XCTAssertEqual(fixture.state.viewOffset, -(span(0.4) + gap * 2), accuracy: 0.01)
    }

    func testNewColumnBetweenFilledColumnsKeepsFirstColumnAtLeftEdge() throws {
        var fixture = makeFixture([0.5, 0.5])
        let firstWindow = fixture.columns[0].windowNodes.first?.id
        XCTAssertTrue(try insertColumn(after: firstWindow, into: &fixture))

        assertProportions(fixture, [0.25, 0.5, 0.25])
        XCTAssertEqual(fixture.state.viewOffset, -(span(0.25) + span(0.5) + gap * 3), accuracy: 0.01)
    }

    func testClosingActiveColumnGivesWidthEvenlyToVisibleColumns() {
        var fixture = makeFixture([0.4, 0.1, 0.5])
        removeWindow(3, from: &fixture)

        assertProportions(fixture, [0.65, 0.35])
        XCTAssertEqual(fixture.state.activeColumnIndex, 1)
        XCTAssertEqual(fixture.state.viewOffset, -(span(0.65) + gap * 2), accuracy: 0.01)
    }

    func testClosingMiddleColumnKeepsFirstColumnAtLeftEdge() {
        var fixture = makeFixture([0.4, 0.1, 0.5])
        removeWindow(2, from: &fixture)

        assertProportions(fixture, [0.45, 0.55])
        XCTAssertEqual(fixture.state.activeColumnIndex, 1)
        XCTAssertEqual(fixture.state.viewOffset, -(span(0.45) + gap * 2), accuracy: 0.01)
    }

    func testColumnRemovedOutsideLayoutPassGivesWidthToRecordedColumns() {
        var fixture = makeFixture([0.4, 0.1, 0.5])
        fixture.engine.recordFilledColumns(context: context(fixture), state: fixture.state)
        fixture.engine.removeWindow(token: WindowToken(pid: 1, windowId: 3), in: fixture.workspaceId)
        fixture.state.activeColumnIndex = 1

        XCTAssertTrue(fixture.engine.fillScreenAfterRemoval(context: context(fixture), state: &fixture.state))
        assertProportions(fixture, [0.65, 0.35])
        XCTAssertEqual(fixture.state.viewOffset, -(span(0.65) + gap * 2), accuracy: 0.01)
    }

    func testClosingWithoutFillKeepsWidths() {
        var fixture = makeFixture([0.4, 0.1, 0.5])
        fixture.engine.removeWindows(
            [WindowToken(pid: 1, windowId: 3)],
            context: context(fixture),
            state: &fixture.state,
            selectedNodeId: fixture.state.selectedNodeId,
            removedNodeIds: []
        )

        assertProportions(fixture, [0.4, 0.1])
    }
}
