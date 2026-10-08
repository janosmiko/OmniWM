// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    // macOS puts the resize handle a few points outside the window frame, in the gap between tiles.
    private static let nativeResizeHandleReach: CGFloat = 6

    func nativeResizeHandlePress(at location: CGPoint, workspaceId: WorkspaceDescriptor.ID) -> CGPoint? {
        guard let controller else { return nil }
        let nearHandle = controller.workspaceManager.tiledEntries(in: workspaceId).contains { entry in
            pressedNativeResizeHandle(of: entry, at: location)
        }
        return nearHandle ? location : nil
    }

    func pressedNativeResizeHandle(of entry: WindowState, at location: CGPoint? = nil) -> Bool {
        guard let location = location ?? state.nativeResizeHandlePressLocation,
              let frame = controller?.axManager.lastAppliedFrame(for: entry.windowId)
        else { return false }
        let reach = Self.nativeResizeHandleReach
        return frame.insetBy(dx: -reach, dy: -reach).contains(location)
            && !frame.insetBy(dx: reach, dy: reach).contains(location)
    }

    func adoptNativeEdgeResize(of entry: WindowState, from appliedFrame: CGRect?, to observedFrame: CGRect?) {
        guard let controller, let appliedFrame, let observedFrame,
              !state.isMoving, !state.isResizing,
              pressedNativeResizeHandle(of: entry),
              let path = Self.nativeEdgeResizePath(from: appliedFrame, to: observedFrame)
        else { return }
        let capturedButton = state.capturedInteractionButton
        defer { state.capturedInteractionButton = capturedButton }
        guard beginNativeEdgeResize(of: entry, at: path.start, controller: controller) else { return }
        updateManagedResize(at: path.end)
        completeActiveResize()
    }

    private func beginNativeEdgeResize(
        of entry: WindowState,
        at location: CGPoint,
        controller: WMController
    ) -> Bool {
        let workspaceId = entry.workspaceId
        let layoutType = controller.workspaceManager.descriptor(for: workspaceId)
            .map { controller.settings.workspaces.layoutType(for: $0.name) }
        if layoutType == .dwindle {
            guard let engine = controller.dwindleEngine else { return false }
            return beginDwindleResize(
                token: entry.token, engine: engine, wsId: workspaceId, at: location, source: .mouse(.left)
            )
        }
        guard let engine = controller.niriEngine,
              let window = engine.findNode(for: entry.token, in: workspaceId)
        else { return false }
        return beginNiriResize(window: window, engine: engine, wsId: workspaceId, at: location, source: .mouse(.left))
    }

    private static func nativeEdgeResizePath(
        from appliedFrame: CGRect,
        to observedFrame: CGRect
    ) -> (start: CGPoint, end: CGPoint)? {
        let tolerance = FrameTolerance.frameWrite
        let widthChanged = abs(observedFrame.width - appliedFrame.width) >= tolerance
        let heightChanged = abs(observedFrame.height - appliedFrame.height) >= tolerance
        guard widthChanged || heightChanged else { return nil }
        var start = appliedFrame.center
        var end = start
        if widthChanged {
            let leftMoved = abs(observedFrame.minX - appliedFrame.minX) > abs(observedFrame.maxX - appliedFrame.maxX)
            start.x = leftMoved ? appliedFrame.minX : appliedFrame.maxX
            end.x = leftMoved ? observedFrame.minX : observedFrame.maxX
        }
        if heightChanged {
            let bottomMoved = abs(observedFrame.minY - appliedFrame.minY) > abs(observedFrame.maxY - appliedFrame.maxY)
            start.y = bottomMoved ? appliedFrame.minY : appliedFrame.maxY
            end.y = bottomMoved ? observedFrame.minY : observedFrame.maxY
        }
        return (start, end)
    }
}
