// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
extension AXEventHandler {
    func admissionProtectionDump() -> String {
        var lines: [String] = []
        for (windowId, state) in admissionRetryStateByWindowId.sorted(by: { $0.key < $1.key }) {
            lines.append(
                "retry win=\(windowId) trigger=\(Self.triggerKind(state.trigger))"
                    + " protects=\(state.trigger.protectsMissingEntriesDuringAdmission && !state.exhausted)"
                    + " pids=\(Self.pidList(state.trigger.protectionPIDs))"
                    + " expected=\(state.expectedToken.map { "\($0.pid):\($0.windowId)" } ?? "nil")"
                    + " reason=\(state.reason.rawValue) attempt=\(state.attempt)"
                    + " generation=\(state.generation) phase=\(state.executionPhase)"
                    + " task=\(state.task == nil ? "nil" : "live") exhausted=\(state.exhausted)"
                    + " aliases=\(Self.pidList(identityAliasesByWindowId[Int(windowId)]?.pids ?? []))"
            )
        }
        for windowId in deferredCreatedWindowIds.sorted() {
            lines.append(
                "deferredCreated win=\(windowId)"
                    + " aliases=\(Self.pidList(identityAliasesByWindowId[Int(windowId)]?.pids ?? []))"
            )
        }
        for (windowId, protection) in deferredReplacementProtectionsByWindowId.sorted(by: { $0.key < $1.key }) {
            lines.append(
                "replacementProtection win=\(windowId)"
                    + " tokens=\(Self.tokenList(protection.protectedTokens))"
                    + " fallback=\(Self.tokenList(protection.fallbackProtectedTokens))"
                    + " pidFallback=\(protection.permitsPIDFallback)"
                    + " scopePIDs=\(Self.pidList(protection.scope.appPIDs))"
            )
        }
        return lines.isEmpty ? "none" : lines.joined(separator: "\n")
    }

    private static func triggerKind(_ trigger: AdmissionRetryTrigger) -> String {
        switch trigger {
        case .create: "create"
        case .candidate: "candidate"
        case .focused: "focused"
        case .identityRebind: "identityRebind"
        case .ruleReevaluation: "ruleReevaluation"
        }
    }

    private static func pidList(_ pids: Set<pid_t>) -> String {
        pids.isEmpty ? "none" : pids.sorted().map(String.init).joined(separator: ",")
    }

    private static func tokenList(_ tokens: Set<WindowToken>) -> String {
        tokens.isEmpty
            ? "none"
            : tokens.map { "\($0.pid):\($0.windowId)" }.sorted().joined(separator: ",")
    }
}

@MainActor
extension LayoutRefreshController {
    func missingRetirementDump() -> String {
        let misses = layoutState.consecutiveMissCountByHandle
            .map { "\($0.key.id.pid):\($0.key.id.windowId)=\($0.value)" }
            .sorted()
        return [
            "barrierActive=\(layoutState.inventoryStabilityBarrierActive)",
            "holdFullRescans=\(layoutState.inventoryStabilityHoldFullRescans)",
            "confirmationTask=\(layoutState.missingConfirmationTask == nil ? "nil" : "live")",
            "pendingConfirmation=\(layoutState.pendingMissingConfirmationScope.map { "\($0)" } ?? "nil")",
            "missCounts=\(misses.isEmpty ? "none" : misses.joined(separator: ","))"
        ].joined(separator: "\n")
    }
}
