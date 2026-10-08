// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

extension NiriLayoutEngine {
    typealias FilledColumns = [(column: NiriContainer, proportion: CGFloat)]

    /// Returns false when no other column is fully visible, so the caller resizes the column alone.
    func applyFillScreenWidth(
        _ column: NiriContainer,
        width newWidth: ProportionalSize,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard canFillScreen(context) else { return false }
        resolveFillScreenSpans(context)
        let columns = columns(in: context.workspaceId)
        guard let activeIndex = columns.firstIndex(where: { $0 === column }) else { return false }
        let visible = fullyVisibleColumnIndices(columns: columns, state: state, context: context)
        let neighbors = visible.filter { $0 != activeIndex }.map { columns[$0] }
        guard visible.contains(activeIndex), !neighbors.isEmpty else { return false }

        for neighbor in neighbors {
            beginManualPrimarySpanResize(neighbor, in: context.workspaceId, orientation: .horizontal)
        }
        guard let split = NiriFillScreenSplit(
            focused: widthProportion(column.isFullWidth ? .proportion(1) : column.width, context: context),
            target: widthProportion(newWidth, context: context),
            others: neighbors.map { widthProportion($0.width, context: context) },
            minimum: NiriFillScreenSplit.minimumProportion
        ) else { return false }

        applyFillScreenSplit(
            Array(zip(neighbors, split.others)),
            focused: column,
            filledSpan: neighbors.reduce(column.settledWidth) { $0 + $1.settledWidth },
            context: context,
            state: &state
        )
        return true
    }

    /// Returns the fully visible columns when they fill the screen from edge to edge.
    func filledVisibleColumns(context: NiriInteractionContext, state: ViewportState) -> FilledColumns? {
        guard canFillScreen(context) else { return nil }
        resolveFillScreenSpans(context)
        let columns = columns(in: context.workspaceId)
        let visible = fullyVisibleColumnIndices(columns: columns, state: state, context: context).map { columns[$0] }
        let usedSpan = visible.reduce(context.gaps) { $0 + $1.settledWidth + context.gaps }
        guard !visible.isEmpty, abs(usedSpan - context.workingFrame.width) <= 1 else { return nil }
        return visible.map { ($0, widthProportion(.fixed($0.settledWidth), context: context)) }
    }

    /// Shrinks the columns that filled the screen evenly so that the new column fits next to them.
    @discardableResult
    func fillScreenAfterInsert(
        _ column: NiriContainer,
        filledBefore: FilledColumns,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let columns = columns(in: context.workspaceId)
        let index = { (target: NiriContainer) in columns.firstIndex { $0 === target } }
        guard canFillScreen(context),
              let newIndex = index(column),
              let firstIndex = filledBefore.first.flatMap({ index($0.column) }),
              let lastIndex = filledBefore.last.flatMap({ index($0.column) }),
              newIndex > firstIndex, newIndex <= lastIndex + 1,
              let split = NiriFillScreenSplit(
                  focused: 0,
                  target: widthProportion(.fixed(column.settledWidth), context: context),
                  others: filledBefore.map(\.proportion),
                  minimum: NiriFillScreenSplit.minimumProportion
              )
        else { return false }

        keepManualWidths([column] + filledBefore.map(\.column), context: context)
        applyFillScreenSplit(
            Array(zip(filledBefore.map(\.column), split.others)),
            focused: column,
            filledSpan: filledSpan(columnCount: filledBefore.count + 1, context: context),
            context: context,
            state: &state
        )
        return true
    }

    /// Returns the columns that expelled windows created since the last call, and forgets them.
    func takeExpelledColumnIds(in workspaceId: WorkspaceDescriptor.ID) -> [NodeId] {
        guard let workspaceState = states[workspaceId] else { return [] }
        defer { workspaceState.expelledColumnIds = [] }
        return workspaceState.expelledColumnIds
    }

    /// Gives each expelled column an equal share of the filled screen and shrinks the filled columns in proportion.
    /// An expelled column copies the width of the column it left, which can be the whole screen.
    @discardableResult
    func fillScreenAfterExpel(
        _ expelledIds: [NodeId],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let recorded = ensureState(for: context.workspaceId).filledColumns
        let columns = columns(in: context.workspaceId)
        let column = { (id: NodeId) in columns.first { $0.id == id } }
        let filledBefore: FilledColumns = recorded
            .compactMap { entry in column(entry.id).map { ($0, entry.proportion) } }
        let expelled = expelledIds.compactMap(column)
        let indices = (filledBefore.map(\.column) + expelled)
            .compactMap { target in columns.firstIndex { $0 === target } }
            .sorted()
        guard canFillScreen(context), !expelled.isEmpty, !recorded.isEmpty,
              let firstIndex = indices.first, indices == Array(firstIndex ..< firstIndex + indices.count)
        else { return false }

        let count = CGFloat(indices.count)
        let total = filledBefore.reduce(0) { $0 + $1.proportion }
        let freed = recorded.reduce(0) { $0 + $1.proportion } - total
        // A moved column whose source column closed takes over the freed width instead of sharing the screen.
        let split = freed > 0
            ? filledBefore.map { ($0.column, $0.proportion) } + expelled.map { ($0, freed / CGFloat(expelled.count)) }
            : filledBefore.map { ($0.column, $0.proportion * CGFloat(filledBefore.count) / count) }
            + expelled.map { ($0, total / count) }
        let active = columns.indices.contains(state.activeColumnIndex) ? columns[state.activeColumnIndex] : nil
        let focused = split.first { $0.0 === active }?.0 ?? expelled[expelled.count - 1]
        keepManualWidths(split.map(\.0), context: context)
        applyFillScreenSplit(
            split.filter { $0.0 !== focused },
            focused: focused,
            filledSpan: filledSpan(columnCount: split.count, context: context),
            context: context,
            state: &state
        )
        return true
    }

    /// Moves the width change of a mouse resize onto the columns that filled the screen when the resize started.
    @discardableResult
    func fillScreenAfterInteractiveResize(
        _ resize: InteractiveResize,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let columns = columns(in: context.workspaceId)
        let filled: FilledColumns = resize.filledColumnsAtStart.compactMap { entry in
            columns.first { $0.id == entry.id }.map { ($0, entry.proportion) }
        }
        guard canFillScreen(context), resize.originalContainerSpan != nil,
              filled.count == resize.filledColumnsAtStart.count,
              let window = findNode(by: resize.windowId, in: context.workspaceId) as? NiriWindow,
              let column = findColumn(containing: window, in: context.workspaceId),
              let before = filled.first(where: { $0.column === column })?.proportion,
              // Measure like recordFilledColumns, so that a drag that keeps the width changes nothing.
              case let target = widthProportion(.fixed(column.settledWidth), context: context),
              abs(target - before) > 1e-6,
              case let others = filled.filter({ $0.column !== column }),
              let split = NiriFillScreenSplit(
                  focused: before,
                  target: target,
                  others: others.map(\.proportion),
                  minimum: NiriFillScreenSplit.minimumProportion
              )
        else { return false }

        keepManualWidths(filled.map(\.column), context: context)
        applyFillScreenSplit(
            Array(zip(others.map(\.column), split.others)),
            focused: column,
            filledSpan: filledSpan(columnCount: filled.count, context: context),
            context: context,
            state: &state
        )
        // A window can close before the next layout pass records the new widths.
        ensureState(for: context.workspaceId).filledColumns = filled.map {
            ($0.column.id, widthProportion(.fixed($0.column.settledWidth), context: context))
        }
        return true
    }

    /// Remembers the columns that fill the screen, so that a later pass can refill it when one of them goes away.
    func recordFilledColumns(context: NiriInteractionContext, state: ViewportState) {
        ensureState(for: context.workspaceId).filledColumns = filledVisibleColumns(context: context, state: state)?
            .map { ($0.column.id, $0.proportion) } ?? []
    }

    func forgetFilledColumns(in workspaceId: WorkspaceDescriptor.ID) {
        states[workspaceId]?.filledColumns = []
    }

    /// Gives the width of recorded columns that are gone evenly to the recorded columns that remain.
    @discardableResult
    func fillScreenAfterRemoval(context: NiriInteractionContext, state: inout ViewportState) -> Bool {
        let recorded = ensureState(for: context.workspaceId).filledColumns
        guard canFillScreen(context), !recorded.isEmpty else { return false }
        // A window that closes outside a layout pass leaves every column width unresolved.
        resolveFillScreenSpans(context)
        let columns = columns(in: context.workspaceId)
        let survivors: FilledColumns = recorded.compactMap { entry in
            columns.first { $0.id == entry.id }.map { ($0, entry.proportion) }
        }
        let freed = recorded.filter { entry in !columns.contains { $0.id == entry.id } }
        guard !freed.isEmpty, !survivors.isEmpty,
              singleWindowLayoutContext(in: context.workspaceId) == nil,
              columns.indices.contains(state.activeColumnIndex),
              let focused = survivors.first(where: { $0.column === columns[state.activeColumnIndex] })?.column
        else { return false }

        let share = freed.reduce(0) { $0 + $1.proportion } / CGFloat(survivors.count)
        keepManualWidths(survivors.map(\.column), context: context)
        applyFillScreenSplit(
            survivors.filter { $0.column !== focused }.map { ($0.column, $0.proportion + share) },
            focused: focused,
            filledSpan: filledSpan(columnCount: survivors.count, context: context),
            context: context,
            state: &state
        )
        return true
    }

    // Always-center mode moves the view on every resize, so a filled screen cannot stay filled.
    // Hidden columns still hold a slot in columns(in:), so their width would count as visible.
    private func canFillScreen(_ context: NiriInteractionContext) -> Bool {
        context.orientation == .horizontal
            && effectiveSettings(in: context.workspaceId).centerFocusedColumn != .always
            && projectionExclusions(in: context.workspaceId).isEmpty
    }

    private func resolveFillScreenSpans(_ context: NiriInteractionContext) {
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation,
            motion: context.motion
        )
    }

    // Auto-fit drops manual widths when the column count changes, so the new count must count as manual.
    private func keepManualWidths(_ columns: [NiriContainer], context: NiriInteractionContext) {
        for column in columns {
            beginManualPrimarySpanResize(column, in: context.workspaceId, orientation: .horizontal)
        }
        ensureState(for: context.workspaceId).manualWidthColumnCount = projectedColumns(in: context.workspaceId).count
    }

    private func filledSpan(columnCount: Int, context: NiriInteractionContext) -> CGFloat {
        context.workingFrame.width - context.gaps * CGFloat(columnCount + 1)
    }

    private func applyFillScreenSplit(
        _ split: [(neighbor: NiriContainer, proportion: CGFloat)],
        focused column: NiriContainer,
        filledSpan: CGFloat,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let neighbors = split.map(\.neighbor)
        // applyColumnWidth makes each resized column active, but the caller owns the focus.
        let activeIndex = state.activeColumnIndex
        for (neighbor, proportion) in split {
            applyColumnWidth(
                neighbor,
                width: .proportion(proportion),
                presetIndex: nil,
                context: context,
                state: &state,
                recoversSettledCoverage: false
            )
        }
        // Window size limits can stop a neighbor at another width, so the focused column takes the rest.
        let focusedSpan = filledSpan - neighbors.reduce(0) { $0 + $1.settledWidth }
        applyColumnWidth(
            column,
            width: .proportion(widthProportion(.fixed(focusedSpan), context: context)),
            presetIndex: nil,
            context: context,
            state: &state,
            recoversSettledCoverage: false
        )
        // Keep the first filled column at the left edge while the widths before the active column change.
        let columns = columns(in: context.workspaceId)
        let firstIndex = columns.firstIndex { candidate in
            candidate === column || neighbors.contains { $0 === candidate }
        } ?? state.activeColumnIndex
        state.activeColumnIndex = activeIndex.clamped(to: 0 ... max(0, columns.count - 1))
        let current = state
        let position = { (index: Int) in
            current.containerPosition(at: index, containers: columns, gap: context.gaps, sizeKeyPath: \.settledWidth)
        }
        state.animateToOffset(
            position(firstIndex) - position(state.activeColumnIndex) - context.gaps,
            motion: context.motion,
            scale: displayScale(in: context.workspaceId)
        )
        recoverSettledCoverage(context: context, state: &state)
    }

    private func fullyVisibleColumnIndices(
        columns: [NiriContainer],
        state: ViewportState,
        context: NiriInteractionContext
    ) -> [Int] {
        let scale = displayScale(in: context.workspaceId)
        let gaps = context.gaps
        let position = { (index: Int) in
            state.containerPosition(at: index, containers: columns, gap: gaps, sizeKeyPath: \.settledWidth)
        }
        let viewX = position(state.activeColumnIndex.clamped(to: 0 ... max(0, columns.count - 1))) + state.viewOffset
        let viewportStart = (viewX + gaps).roundedToPhysicalPixel(scale: scale)
        let viewportEnd = (viewX + context.workingFrame.width).roundedToPhysicalPixel(scale: scale)
        return columns.indices.filter { index in
            let columnX = position(index)
            return columnX.roundedToPhysicalPixel(scale: scale) >= viewportStart
                && (columnX + columns[index].settledWidth + gaps).roundedToPhysicalPixel(scale: scale) <= viewportEnd
        }
    }

    private func widthProportion(_ spec: ProportionalSize, context: NiriInteractionContext) -> CGFloat {
        switch spec {
        case let .proportion(proportion):
            return proportion
        case let .fixed(pixels):
            let proportionalSpan = context.workingFrame.width - context.gaps
            return proportionalSpan > 0 ? (pixels + context.gaps) / proportionalSpan : 1
        }
    }
}
