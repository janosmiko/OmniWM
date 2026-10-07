// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

/// Moves a focused column's proportion change onto its neighbors so the total proportion stays the same.
struct NiriFillScreenSplit: Equatable {
    static let minimumProportion: CGFloat = 0.1

    let focused: CGFloat
    let others: [CGFloat]

    init?(focused: CGFloat, target: CGFloat, others: [CGFloat], minimum: CGFloat) {
        guard !others.isEmpty else { return nil }
        let room = others.reduce(0) { $0 + max(0, $1 - minimum) }
        let clampedTarget = min(max(target, min(focused, minimum)), focused + room)
        var remaining = clampedTarget - focused
        var result = others
        if remaining < 0 {
            let share = -remaining / CGFloat(others.count)
            result = others.map { $0 + share }
        } else {
            var shrinkable = result.indices.filter { result[$0] - minimum > 1e-9 }
            while remaining > 1e-9, !shrinkable.isEmpty {
                let share = remaining / CGFloat(shrinkable.count)
                for index in shrinkable {
                    let taken = min(share, result[index] - minimum)
                    result[index] -= taken
                    remaining -= taken
                }
                shrinkable = shrinkable.filter { result[$0] - minimum > 1e-9 }
            }
        }
        self.focused = clampedTarget
        self.others = result
    }
}
