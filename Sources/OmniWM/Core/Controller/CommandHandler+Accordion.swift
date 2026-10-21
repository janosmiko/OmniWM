// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension CommandHandler {
    func toggleAccordion() {
        guard let controller, let workspace = controller.activeWorkspace() else { return }
        var configs = controller.settings.workspaces.configurations
        guard let index = configs.firstIndex(where: { $0.name == workspace.name }) else { return }

        let enabled = !configs[index].accordion
        configs[index] = configs[index].with(accordion: enabled)
        controller.settings.workspaces.configurations = configs
        controller.niriLayoutHandler.syncAccordion(enabled, in: workspace.id)
        // The columns overlap after this relayout, so the focused window must be on top of them.
        var postLayout: LayoutRefreshController.PostLayoutAction?
        if enabled, let token = controller.workspaceManager.preferredFocusToken(in: workspace.id) {
            postLayout = { [weak controller] in _ = controller?.focusWindow(token) }
        }
        controller.niriLayoutHandler.requestLayoutCommandRelayout(in: workspace.id, postLayout: postLayout)
        if let ipcApplicationBridge = controller.ipcApplicationBridge {
            Task {
                await ipcApplicationBridge.publishEvent(.layoutChanged)
            }
        }
    }
}
