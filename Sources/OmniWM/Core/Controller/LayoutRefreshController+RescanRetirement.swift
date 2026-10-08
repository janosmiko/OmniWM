// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension LayoutRefreshController {
    func retireFullRescanWindows(
        context: FullRescanMutationContext,
        hadNativeFullscreenLifecycleContextAtStart: Bool,
        permitsMissingRetirement: Bool,
        progress: inout FullRescanProgress
    ) {
        let controller = context.controller
        let enumerationSnapshot = context.enumerationSnapshot
        let scope = context.scope
        let focusedWorkspaceId = context.focusedWorkspaceId
        controller.axEventHandler.updateIdentityAliases(
            enumerationSnapshot.identityAliasesByWindowId
        )

        for token in progress.decisionBasedRemovals {
            guard let entry = controller.workspaceManager.entry(for: token) else { continue }
            controller.axEventHandler.retireManagedWindowAfterDecisionRejection(entry)
        }

        controller.workspaceManager.promoteLifetimeAuthorityForObservedTopLevelWindows(
            progress.observedTopLevelInventoryTokens
        )

        let shouldPreserveMissingWindows = hadNativeFullscreenLifecycleContextAtStart
            || controller.workspaceManager.hasNativeFullscreenLifecycleContext
        let trackedEntries = controller.workspaceManager.allEntries()
        let nativeFullscreenRetirementKeys = exactNativeFullscreenRetirementKeys(
            scope: scope,
            trackedEntries: trackedEntries
        )
        let retirement = FullRescanRetirementContext(
            shouldPreserveMissingWindows: shouldPreserveMissingWindows,
            nativeFullscreenRetirementKeys: nativeFullscreenRetirementKeys,
            permitsMissingRetirement: permitsMissingRetirement
        )
        preserveFullRescanWindows(
            trackedEntries, context: context,
            retirement: retirement, progress: &progress
        )
        let eligibleKeys = fullRescanRetirementEligibility(trackedEntries, context: context)
        let retiredMissingWindows = retireMissingFullRescanWindows(
            trackedEntries, context: context, retirement: retirement,
            eligibleKeys: eligibleKeys, progress: &progress
        )
        if !shouldPreserveMissingWindows,
           scope == .all || !progress.decisionBasedRemovals.isEmpty || retiredMissingWindows
        {
            controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWorkspaceId)
        }
    }

    private func preserveFullRescanWindows(
        _ trackedEntries: [WindowState],
        context: FullRescanMutationContext,
        retirement: FullRescanRetirementContext,
        progress: inout FullRescanProgress
    ) {
        let nativeFullscreenRetirementKeys = retirement.nativeFullscreenRetirementKeys
        if retirement.shouldPreserveMissingWindows {
            let preservedEntries = trackedEntries.filter { !nativeFullscreenRetirementKeys.contains($0.token) }
            let orderedOutTokens = orderedOutMissingTokens(preservedEntries, context: context, progress: progress)
            for entry in preservedEntries where !orderedOutTokens.contains(entry.token) {
                progress.seenKeys.insert(.init(pid: entry.pid, windowId: entry.windowId))
            }
            preserveHiddenOrUnenumeratedWindows(
                preservedEntries.filter { orderedOutTokens.contains($0.token) },
                context: context, retirement: retirement, progress: &progress
            )
        } else {
            preserveHiddenOrUnenumeratedWindows(
                trackedEntries, context: context, retirement: retirement, progress: &progress
            )
        }
    }

    // Native fullscreen hides other Spaces from AX, so missing windows are kept. Slack and Spark
    // order a window out on close instead, and the window server still reports it on a Space.
    private func orderedOutMissingTokens(
        _ entries: [WindowState],
        context: FullRescanMutationContext,
        progress: FullRescanProgress
    ) -> Set<WindowToken> {
        let axEventHandler = context.controller.axEventHandler
        let topology = context.controller.workspaceManager.spaceTopology
        return Set(entries.lazy.filter { entry in
            // Inactive-Space windows can never retire, so skip their window server query.
            guard !progress.seenKeys.contains(entry.token),
                  context.enumerationSnapshot.successfullyEnumeratedPIDs.contains(entry.pid),
                  !topology.isWindowOnKnownInactiveSpace(entry.windowId),
                  let windowId = UInt32(exactly: entry.windowId),
                  let info = axEventHandler.windowInfoProvider(windowId)
            else { return false }
            return info.pid == entry.pid && info.attributes & 0x2 == 0
        }.map(\.token))
    }

    private func preserveHiddenOrUnenumeratedWindows(
        _ entries: [WindowState],
        context: FullRescanMutationContext,
        retirement: FullRescanRetirementContext,
        progress: inout FullRescanProgress
    ) {
        let controller = context.controller
        let enumerationSnapshot = context.enumerationSnapshot
        let nativeFullscreenRetirementKeys = retirement.nativeFullscreenRetirementKeys
        for entry in entries
            where controller.workspaceManager.isAppHidden(pid: entry.pid)
            || (
                controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen
                    && !nativeFullscreenRetirementKeys.contains(entry.token)
            )
        {
            progress.seenKeys.insert(.init(pid: entry.pid, windowId: entry.windowId))
        }

        for entry in entries
            where enumerationSnapshot.failedPIDs.contains(entry.pid)
        {
            progress.seenKeys.insert(.init(pid: entry.pid, windowId: entry.windowId))
        }

        preserveScratchpadHiddenWindowsDuringFullRescan(
            entries,
            windowServerInfoByWindowId: enumerationSnapshot.windowServerInfoByWindowId,
            seenKeys: &progress.seenKeys
        )
    }

    private func fullRescanRetirementEligibility(
        _ trackedEntries: [WindowState],
        context: FullRescanMutationContext
    ) -> Set<WindowToken>? {
        let scope = context.scope
        let enumerationSnapshot = context.enumerationSnapshot
        let eligibleKeys: Set<WindowToken>? = switch scope {
        case .all:
            nil
        case let .targeted(appPIDs, _, nativeSpaceWindowIdsByPID):
            Set(
                trackedEntries.lazy
                    .filter {
                        enumerationSnapshot.authoritativeTargetPIDs.contains($0.pid)
                            && (
                                appPIDs.contains($0.pid)
                                    || nativeSpaceWindowIdsByPID[$0.pid]?.contains($0.windowId) == true
                            )
                    }
                    .map(\.token)
            )
        }
        return eligibleKeys
    }

    private func retireMissingFullRescanWindows(
        _ trackedEntries: [WindowState],
        context: FullRescanMutationContext,
        retirement: FullRescanRetirementContext,
        eligibleKeys: Set<WindowToken>?,
        progress: inout FullRescanProgress
    ) -> Bool {
        let controller = context.controller
        let scope = context.scope
        let enumerationSnapshot = context.enumerationSnapshot
        let nativeFullscreenRetirementKeys = retirement.nativeFullscreenRetirementKeys
        let permitsMissingRetirement = retirement.permitsMissingRetirement
        if let eligibleKeys {
            preserveHiddenWindowsDuringTargetedFullRescan(
                trackedEntries,
                eligibleKeys: eligibleKeys,
                windowServerInfoByWindowId: enumerationSnapshot.windowServerInfoByWindowId,
                seenKeys: &progress.seenKeys
            )
        }
        let missingCandidateKeys = eligibleKeys ?? Set(trackedEntries.map(\.token))
        let admissionProtectedMissingKeys = permitsMissingRetirement
            ? controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: missingCandidateKeys.subtracting(progress.seenKeys),
                scope: scope
            )
            : []
        let missingDetectionEligibleKeys = missingCandidateKeys
            .subtracting(admissionProtectedMissingKeys)
        let missingCandidates = missingFullRescanCandidates(
            missingDetectionEligibleKeys, context: context, retirement: retirement, seenKeys: progress.seenKeys
        )
        let missingEntries = confirmedMissingEntriesDuringFullRescan(
            seenKeys: progress.seenKeys,
            eligibleKeys: missingDetectionEligibleKeys,
            nativeFullscreenRetirementKeys: nativeFullscreenRetirementKeys,
            permitsMissingRetirement: permitsMissingRetirement
        )
        for entry in missingEntries {
            controller.axEventHandler.retireManagedWindowFromAuthoritativeRescan(entry)
        }
        let unresolvedMissingCandidates = missingCandidates
            .subtracting(missingEntries.map(\.token))
        if permitsMissingRetirement, !unresolvedMissingCandidates.isEmpty {
            scheduleMissingConfirmation(scope: scope)
        }
        return !missingEntries.isEmpty
    }

    private func missingFullRescanCandidates(
        _ missingDetectionEligibleKeys: Set<WindowToken>,
        context: FullRescanMutationContext,
        retirement: FullRescanRetirementContext,
        seenKeys: Set<WindowToken>
    ) -> Set<WindowToken> {
        let controller = context.controller
        let nativeFullscreenRetirementKeys = retirement.nativeFullscreenRetirementKeys
        let permitsMissingRetirement = retirement.permitsMissingRetirement
        return if permitsMissingRetirement {
            Set(missingDetectionEligibleKeys.filter { token in
                guard !seenKeys.contains(token),
                      let entry = controller.workspaceManager.entry(for: token)
                else { return false }
                return (
                    entry.layoutReason != .nativeFullscreen
                        || nativeFullscreenRetirementKeys.contains(token)
                )
                    && !controller.workspaceManager.spaceTopology
                    .isWindowOnKnownInactiveSpace(entry.windowId)
            })
        } else {
            Set<WindowToken>()
        }
    }
}
