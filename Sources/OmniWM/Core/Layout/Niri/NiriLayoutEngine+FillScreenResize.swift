// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

extension NiriLayoutEngine {
    /// Returns false when no other column is fully visible, so the caller resizes the column alone.
    func applyFillScreenWidth(
        _ column: NiriContainer,
        width newWidth: ProportionalSize,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        // Always-center mode moves the view on every resize, so a filled screen cannot stay filled.
        // Hidden columns still hold a slot in columns(in:), so their width would count as visible.
        guard context.orientation == .horizontal,
              effectiveSettings(in: context.workspaceId).centerFocusedColumn != .always,
              projectionExclusions(in: context.workspaceId).isEmpty
        else { return false }
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation,
            motion: context.motion
        )
        let columns = columns(in: context.workspaceId)
        guard let activeIndex = columns.firstIndex(where: { $0 === column }) else { return false }
        let visible = fullyVisibleColumnIndices(columns: columns, state: state, context: context)
        let neighbors = visible.filter { $0 != activeIndex }
        guard visible.contains(activeIndex), !neighbors.isEmpty else { return false }

        for index in neighbors {
            beginManualPrimarySpanResize(columns[index], in: context.workspaceId, orientation: .horizontal)
        }
        guard let split = NiriFillScreenSplit(
            focused: widthProportion(column.isFullWidth ? .proportion(1) : column.width, context: context),
            target: widthProportion(newWidth, context: context),
            others: neighbors.map { widthProportion(columns[$0].width, context: context) },
            minimum: NiriFillScreenSplit.minimumProportion
        ) else { return false }

        applyFillScreenSplit(
            Array(zip(neighbors.map { columns[$0] }, split.others)),
            leadingCount: neighbors.count(where: { $0 < activeIndex }),
            focused: column,
            context: context,
            state: &state
        )
        return true
    }

    private func applyFillScreenSplit(
        _ split: [(neighbor: NiriContainer, proportion: CGFloat)],
        leadingCount: Int,
        focused column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let neighbors = split.map(\.neighbor)
        let filledSpan = neighbors.reduce(column.settledWidth) { $0 + $1.settledWidth }
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
        // Keep the first visible column at the left edge while widths to the left of the focus change.
        let leadingSpan = neighbors.prefix(leadingCount).reduce(0) { $0 + $1.settledWidth + context.gaps }
        state.animateToOffset(
            -(leadingSpan + context.gaps),
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
