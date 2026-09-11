import ActivityKit
import Foundation
import os
import UIKit

@MainActor
final class LiveActivityManager: @unchecked Sendable {
    static let shared = LiveActivityManager()

    /// The activity this process asked for, held rather than looked up.
    ///
    /// `Activity.activities` is the reason the Dynamic Island flickered between
    /// two faces: the array does not contain an activity the instant
    /// `Activity.request` returns, so two presentations close together — arming
    /// standby twice, or standby followed by a recording — each saw an empty
    /// list and each requested one. Two activities is not one activity shown
    /// twice: iOS splits the island between them and cycles, which is the
    /// microphone in one glance and the app icon in the next.
    private var currentActivityID: String?

    private var activeSessionID: String?
    private var recordingStartedAt: Date?
    private var standbyExpiresAt: Date?
    private var standbyRequested = false
    private var transitionGeneration = 0
    private var pendingStandbyTask: Task<Void, Never>?
    private var pendingEndTask: Task<Void, Never>?
    /// What a deferred end would say, so that backgrounding can say it now.
    private var pendingEnd: (
        state: VocaPhoneActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    )?
    /// When ``currentActivityID`` was requested, so a stale id is not waited on.
    private var requestedAt: Date?
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
        // A deferred end waits a second for something to take the activity
        // over. The app is usually in the background while all of this happens
        // — the keyboard's switch turning VocaPhone off is exactly that — and a
        // process suspended inside that second would leave the island showing a
        // window that has ended, until the next launch noticed the orphan.
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingEnd() }
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
        scheduleEndAll(
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
            scheduleEndAll(
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
        // Whatever is starting now takes over the activity a deferred end was
        // about to destroy. See ``scheduleEndAll``.
        pendingEndTask?.cancel()
        pendingEndTask = nil
        pendingEnd = nil
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
        enqueueActivityMutation { [weak self] in
            guard let self else { return }
            // The one this process is driving, waiting out the moment after a
            // request in which the system has not listed it yet.
            if let liveID = await self.presentableActivityID() {
                self.currentActivityID = liveID
                // Through a nonisolated helper, which is what keeps an
                // `Activity` — not a `Sendable` type — from being handed from
                // this actor to ActivityKit's own.
                await Self.update(id: liveID, to: content)
                return
            }

            let attributes = VocaPhoneActivityAttributes(
                // Kept for compatibility with activities created by older builds;
                // current views read the mutable session ID from ContentState.
                sessionID: state.sessionID ?? UUID().uuidString,
                startedAt: state.startedAt ?? Date()
            )
            do {
                self.currentActivityID = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                ).id
                self.requestedAt = Date()
            } catch {
                // Dictation must continue when the system declines to present
                // a Live Activity.
                self.currentActivityID = nil
                self.requestedAt = nil
            }
        }
    }

    /// The activity to update: the one this process requested, or one left
    /// listed by a previous process of this app.
    ///
    /// The wait is the whole point. `Activity.request` returns before the
    /// activity is necessarily in `Activity.activities`, so a second
    /// presentation arriving in that gap used to find an empty list and request
    /// a second activity — which is the island showing two faces in turn. A
    /// presentation is already asynchronous and off the user's path, so waiting
    /// out that gap costs nothing a person can see.
    ///
    /// An activity the user has swiped away, or that the system has retired, is
    /// not one to update: updating it shows nothing and stops a new one from
    /// being requested.
    private func presentableActivityID() async -> String? {
        if let listed = Self.listedActivity(currentActivityID) { return listed.id }
        // Only an activity this process asked for *just now* is worth waiting
        // for. An id left over from one the system has since retired is not
        // coming back, and waiting on it was a delay the user could feel: every
        // dictation that followed a finished one paid it before ActivityKit was
        // so much as asked.
        if currentActivityID != nil, let requestedAt, requestedAt.timeIntervalSinceNow > -Self.registrationWindow {
            for _ in 0..<Self.registrationPolls {
                try? await Task.sleep(for: Self.registrationPollInterval)
                if let listed = Self.listedActivity(currentActivityID) { return listed.id }
            }
        }
        // It never arrived, or it has already gone. Either way this process is
        // not driving it any more.
        currentActivityID = nil
        requestedAt = nil
        return Activity<VocaPhoneActivityAttributes>.activities
            .first(where: Self.isPresentable)?.id
    }

    /// Six polls of fifty milliseconds: three hundred in the worst case, and
    /// only in the moments right after a request.
    private static let registrationPolls = 6
    private static let registrationPollInterval: Duration = .milliseconds(50)
    /// How long after a request the system list is still worth waiting on.
    private static let registrationWindow: TimeInterval = 2

    private static func listedActivity(
        _ id: String?
    ) -> Activity<VocaPhoneActivityAttributes>? {
        guard let id else { return nil }
        return Activity<VocaPhoneActivityAttributes>.activities
            .first { $0.id == id && isPresentable($0) }
    }

    /// Updates the one activity this app is driving and ends every other.
    ///
    /// Anything else carrying these attributes is from a process that died
    /// mid-recording, or is a duplicate: two activities are not one activity
    /// shown twice, they are two faces the island cycles between.
    private nonisolated static func update(
        id: String,
        to content: ActivityContent<VocaPhoneActivityAttributes.ContentState>
    ) async {
        for activity in Activity<VocaPhoneActivityAttributes>.activities {
            if activity.id == id {
                await activity.update(content)
            } else {
                await activity.end(content, dismissalPolicy: .immediate)
            }
        }
    }

    private static func isPresentable(_ activity: Activity<VocaPhoneActivityAttributes>) -> Bool {
        switch activity.activityState {
        case .active, .stale: true
        default: false
        }
    }

    private func endAll(
        state: VocaPhoneActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        let content = ActivityContent(state: state, staleDate: nil)
        enqueueActivityMutation { [weak self] in
            // Cleared first: a presentation that arrives while these ends are
            // in flight must make a new activity rather than update a dying one.
            self?.currentActivityID = nil
            self?.requestedAt = nil
            await Self.endEverything(with: content, dismissalPolicy: dismissalPolicy)
        }
    }

    /// The gap between "standby is over" and "recording has begun".
    ///
    /// Those two arrive within the same second of each other, in that order,
    /// for every dictation: the window is cleared as the microphone is taken,
    /// and the session's own presentation follows. Ending the activity in
    /// between destroyed the one the next presentation would have updated, so
    /// the island blinked out and a new one grew back — twice a dictation, once
    /// each way. Waiting this long before ending means the next presentation
    /// finds it and updates it, and the island simply changes what it says.
    ///
    /// Long enough to cover that handover, short enough that an activity nobody
    /// takes over still goes promptly.
    private static let endGrace: Duration = .seconds(1)

    /// Ends every activity unless something claims the island first.
    private func scheduleEndAll(
        state: VocaPhoneActivityAttributes.ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        pendingEndTask?.cancel()
        pendingEnd = (state, dismissalPolicy)
        pendingEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.endGrace)
            guard !Task.isCancelled, let self else { return }
            self.pendingEndTask = nil
            self.pendingEnd = nil
            // A standby that re-armed, or a session that started, has taken it.
            guard !self.standbyRequested, self.activeSessionID == nil else { return }
            self.endAll(state: state, dismissalPolicy: dismissalPolicy)
        }
    }

    /// Ends now what was going to be ended in a moment.
    private func flushPendingEnd() {
        guard let pending = pendingEnd else { return }
        pendingEndTask?.cancel()
        pendingEndTask = nil
        pendingEnd = nil
        guard !standbyRequested, activeSessionID == nil else { return }
        endAll(state: pending.state, dismissalPolicy: pending.dismissalPolicy)
    }

    private nonisolated static func endEverything(
        with content: ActivityContent<VocaPhoneActivityAttributes.ContentState>,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        for activity in Activity<VocaPhoneActivityAttributes>.activities {
            await activity.end(content, dismissalPolicy: dismissalPolicy)
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
