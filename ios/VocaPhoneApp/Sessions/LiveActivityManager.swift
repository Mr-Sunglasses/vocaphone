import ActivityKit
import Foundation
import os
import UIKit

@MainActor
final class LiveActivityManager: @unchecked Sendable {
    static let shared = LiveActivityManager()

    private var activeSessionID: String?
    private var recordingStartedAt: Date?
    private var standbyExpiresAt: Date?
    private var standbyRequested = false
    private var transitionGeneration = 0
    private var pendingStandbyTask: Task<Void, Never>?
    private var activityMutationTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isAppExiting = false
    private let logger = Logger(
        subsystem: "com.vocahq.vocaphone",
        category: "LiveActivity"
    )

    private init() {
        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(
                forName: UIScene.didDisconnectNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.endBeforeProcessExit(reason: "scene disconnected")
                }
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.endBeforeProcessExit(reason: "app terminating")
                }
            }
        )
    }

    /// Keeps a branded Live Activity in the Dynamic Island while Quick
    /// Dictation owns the microphone in standby. If a recording is still being
    /// processed, remember the request and return to Ready after it finishes.
    func startStandby(expiresAt: Date) {
        isAppExiting = false
        standbyRequested = true
        standbyExpiresAt = expiresAt
        guard activeSessionID == nil else { return }

        beginTransition()
        present(
            state: VocaPhoneActivityAttributes.ContentState(
                status: "Quick Dictation on standby",
                canFinish: false,
                phase: .standby
            ),
            staleDate: expiresAt
        )
        DiagnosticLog.record(
            .liveActivityStarted,
            metadata: .phase(.standby)
        )
    }

    /// How far the stale date has to have moved before it is worth telling the
    /// system. The standby lease is renewed every couple of seconds, and an
    /// ActivityKit update per heartbeat would burn the whole day redrawing a
    /// card whose text never changes. Two minutes still leaves the stale date
    /// minutes ahead of now, so a live window never renders as stale.
    private static let standbyRenewalInterval: TimeInterval = 120

    /// Pushes the standby activity's stale date forward for a window the user
    /// asked to last as long as the app does.
    ///
    /// Deliberately not `present`: that requests a new activity when none
    /// exist, which would resurrect a card the user swiped away and keep
    /// resurrecting it for as long as standby ran. A renewal updates what is on
    /// screen or does nothing.
    func renewStandby(expiresAt: Date) {
        guard standbyRequested, activeSessionID == nil else { return }
        if let standbyExpiresAt,
           expiresAt.timeIntervalSince(standbyExpiresAt) < Self.standbyRenewalInterval
        {
            return
        }
        standbyExpiresAt = expiresAt
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let content = ActivityContent(
            state: VocaPhoneActivityAttributes.ContentState(
                status: "Quick Dictation on standby",
                canFinish: false,
                phase: .standby
            ),
            staleDate: expiresAt
        )
        enqueueActivityMutation {
            for activity in Activity<VocaPhoneActivityAttributes>.activities {
                await activity.update(content)
            }
        }
    }

    /// Removes the standby Live Activity when Quick Dictation releases the
    /// microphone. An active recording keeps its own activity until completion.
    func stopStandby() {
        standbyRequested = false
        standbyExpiresAt = nil
        pendingStandbyTask?.cancel()
        pendingStandbyTask = nil
        guard activeSessionID == nil else { return }

        beginTransition()
        endAll(
            state: VocaPhoneActivityAttributes.ContentState(
                status: "Quick Dictation off",
                canFinish: false,
                phase: .finished
            ),
            dismissalPolicy: .immediate
        )
        DiagnosticLog.record(
            .liveActivityEnded,
            metadata: .reason(.quickDictationOff)
        )
    }

    func start(sessionID: UUID) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        isAppExiting = false
        standbyRequested = false
        standbyExpiresAt = nil
        activeSessionID = sessionID.uuidString
        recordingStartedAt = Date()
        beginTransition()
        present(
            state: VocaPhoneActivityAttributes.ContentState(
                status: "Recording",
                canFinish: true,
                phase: .recording,
                sessionID: activeSessionID,
                startedAt: recordingStartedAt
            ),
            staleDate: nil
        )
        DiagnosticLog.record(
            .liveActivityStarted,
            metadata: .phase(.recording)
        )
    }

    func update(status: String, canFinish: Bool) {
        guard activeSessionID != nil else { return }

        beginTransition()
        present(
            state: VocaPhoneActivityAttributes.ContentState(
                status: status,
                canFinish: canFinish,
                phase: canFinish ? .recording : .processing,
                sessionID: activeSessionID,
                startedAt: recordingStartedAt
            ),
            staleDate: nil
        )
    }

    func end(status: String, dismissAfter seconds: TimeInterval = 2) {
        guard activeSessionID != nil else { return }

        let finishedState = VocaPhoneActivityAttributes.ContentState(
            status: status,
            canFinish: false,
            phase: .finished,
            sessionID: activeSessionID,
            startedAt: recordingStartedAt
        )

        activeSessionID = nil
        recordingStartedAt = nil
        beginTransition()
        DiagnosticLog.record(
            .liveActivityEnded,
            metadata: .reason(.sessionFinished)
        )

        guard standbyRequested, let standbyExpiresAt, standbyExpiresAt > Date() else {
            endAll(
                state: finishedState,
                dismissalPolicy: seconds > 0
                    ? .after(Date().addingTimeInterval(seconds))
                    : .immediate
            )
            return
        }

        guard seconds > 0 else {
            present(
                state: VocaPhoneActivityAttributes.ContentState(
                    status: "Quick Dictation on standby",
                    canFinish: false,
                    phase: .standby
                ),
                staleDate: standbyExpiresAt
            )
            return
        }

        present(state: finishedState, staleDate: nil)
        let generation = transitionGeneration
        pendingStandbyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled,
                  self.transitionGeneration == generation,
                  self.standbyRequested,
                  self.activeSessionID == nil
            else { return }

            self.pendingStandbyTask = nil
            self.beginTransition()
            guard let expiresAt = self.standbyExpiresAt, expiresAt > Date() else {
                self.endAll(state: finishedState, dismissalPolicy: .immediate)
                return
            }
            self.present(
                state: VocaPhoneActivityAttributes.ContentState(
                    status: "Quick Dictation on standby",
                    canFinish: false,
                    phase: .standby
                ),
                staleDate: expiresAt
            )
        }
    }

    /// Clears a Live Activity left behind by a process that never got to end it
    /// — a jetsam kill or a crash during recording. The activity belongs to the
    /// system, so it survives its app and keeps offering Finish for a session
    /// that no longer exists; the only place that can notice is the next launch.
    ///
    /// The caller establishes that no session is live. This adds what only the
    /// manager knows: an activity this process is itself driving is not an
    /// orphan, and neither is a standby one that was deliberately armed.
    func discardOrphanedActivities() {
        guard activeSessionID == nil, !standbyRequested else { return }
        let orphans = Activity<VocaPhoneActivityAttributes>.activities
        guard !orphans.isEmpty else { return }

        isAppExiting = false
        logger.info("Discarding \(orphans.count) orphaned Live Activities")
        DiagnosticLog.record(
            .liveActivityEnded,
            metadata: .reason(.orphanRecovered)
        )
        beginTransition()
        endAll(
            state: VocaPhoneActivityAttributes.ContentState(
                status: "Recording ended",
                canFinish: false,
                phase: .finished
            ),
            dismissalPolicy: .immediate
        )
    }

    private func beginTransition() {
        pendingStandbyTask?.cancel()
        pendingStandbyTask = nil
        transitionGeneration &+= 1
    }

    private func present(
        state: VocaPhoneActivityAttributes.ContentState,
        staleDate: Date?
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let content = ActivityContent(state: state, staleDate: staleDate)
        enqueueActivityMutation {
            if !Activity<VocaPhoneActivityAttributes>.activities.isEmpty {
                var isPrimary = true
                for activity in Activity<VocaPhoneActivityAttributes>.activities {
                    if isPrimary {
                        isPrimary = false
                        await activity.update(content)
                    } else {
                        await activity.end(content, dismissalPolicy: .immediate)
                    }
                }
                return
            }

            let attributes = VocaPhoneActivityAttributes(
                // Kept for compatibility with activities created by older builds;
                // current views read the mutable session ID from ContentState.
                sessionID: state.sessionID ?? UUID().uuidString,
                startedAt: state.startedAt ?? Date()
            )
            do {
                _ = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } catch {
                // Dictation must continue when the system declines to present
                // a Live Activity.
            }
        }
    }

    private func endAll(
        state: VocaPhoneActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        let content = ActivityContent(state: state, staleDate: nil)
        enqueueActivityMutation {
            for activity in Activity<VocaPhoneActivityAttributes>.activities {
                await activity.end(content, dismissalPolicy: dismissalPolicy)
            }
        }
    }

    /// ActivityKit mutations are asynchronous. Keeping them ordered prevents a
    /// late "off" operation from ending a newly rearmed standby activity.
    private func enqueueActivityMutation(
        _ mutation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let precedingMutation = activityMutationTask
        activityMutationTask = Task { @MainActor [weak self] in
            await precedingMutation?.value
            guard let self, !Task.isCancelled, !self.isAppExiting else { return }
            await mutation()
        }
    }

    /// A Live Activity belongs to the system and otherwise survives its app.
    /// Scene disconnection is the force-quit signal for a scene-based app; the
    /// termination notification is a fallback while background audio keeps the
    /// process running. ActivityKit's end operation is asynchronous, so briefly
    /// servicing the main run loop gives it time to reach the system before iOS
    /// tears down this process.
    private func endBeforeProcessExit(reason: String) {
        guard !isAppExiting else { return }
        isAppExiting = true
        standbyRequested = false
        standbyExpiresAt = nil
        activeSessionID = nil
        recordingStartedAt = nil
        beginTransition()
        activityMutationTask?.cancel()
        activityMutationTask = nil
        try? SharedStore.shared.clearQuickDictationAvailability()
        KeyboardPreferences.containingAppIsForeground = false

        let activities = Activity<VocaPhoneActivityAttributes>.activities
        guard !activities.isEmpty else { return }

        logger.info("Ending \(activities.count) Live Activities before \(reason, privacy: .public)")
        DiagnosticLog.record(
            .liveActivityEnded,
            metadata: .reason(.processExit)
        )
        let content = ActivityContent(
            state: VocaPhoneActivityAttributes.ContentState(
                status: "VocaPhone closed",
                canFinish: false,
                phase: .finished
            ),
            staleDate: nil
        )
        Task { @MainActor in
            for activity in Activity<VocaPhoneActivityAttributes>.activities {
                await activity.end(content, dismissalPolicy: .immediate)
            }
        }

        let deadline = Date().addingTimeInterval(0.75)
        while Date() < deadline {
            RunLoop.current.run(
                until: min(deadline, Date().addingTimeInterval(0.01))
            )
        }
        logger.info("Finished the exit dismissal window")
    }
}
