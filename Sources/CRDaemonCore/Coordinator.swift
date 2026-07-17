import Foundation

/// The engine. Owns the control loop that ties the watcher, queue, review
/// runner, and power/network monitor together, and enforces every safety
/// guard. MainActor-isolated so UI callbacks are thread-safe; long awaits
/// (GitHub calls, `cr` runs) hop off the main thread automatically.
@MainActor
public final class Coordinator {
    public private(set) var config: Config
    public let store: QueueStore
    private let client: GitHubClient
    private let runner: ReviewRunner
    private let monitor: PowerNetworkMonitor
    private let updater: Updater
    private let log: Logger
    private let nowFn: () -> Date

    public private(set) var runtimeState: RuntimeState = .starting {
        didSet {
            if runtimeState != oldValue {
                // Log every transition. The daemon spends most ticks silently
                // returning early when offline/rate-limited (tick()), so without
                // this a wedged-idle state is invisible in the log — exactly the
                // case that made a poll-loop stall undiagnosable.
                log.info("state.change", ["to": runtimeState.label, "from": oldValue.label])
                onStateChange?(runtimeState)
            }
        }
    }

    // UI hooks (set by the AppKit shell).
    public var onStateChange: ((RuntimeState) -> Void)?
    public var onChange: (() -> Void)?
    public var onNotify: ((String, String) -> Void)?

    // Rate snapshot cached for synchronous menu reads.
    public private(set) var rateCore: RateBudget?
    public private(set) var rateSearch: RateBudget?
    public private(set) var identityResolved: String?
    public private(set) var identityOK = false
    public private(set) var safeMode = false

    // cr-version + self-update state, cached for synchronous menu reads.
    /// Parsed installed `cr` version (e.g. "0.4.161"), set at startup.
    public private(set) var crVersionString: String?
    /// A newer `cr` version if one is available upstream, else nil.
    public private(set) var crUpdateAvailable: String?
    /// True while a `brew upgrade` of `cr` is in flight (menu shows "Upgrading cr…").
    public private(set) var upgrading = false

    private var loopTask: Task<Void, Never>?
    /// Reviews currently in flight, keyed by PR. Reviews run in parallel up to
    /// `config.maxConcurrentReviews`, never two PRs of the same repo (they
    /// share a managed checkout).
    private var inFlight: [PRKey: Task<Void, Never>] = [:]
    /// Pids of adopted (restart-surviving) runs — not runner-owned, so sleep
    /// cancellation and deadline kills must reach them explicitly.
    private var adoptedPids: [PRKey: Int32] = [:]
    private var nextPollAt: Date = .distantPast
    private var rateLimitedUntil: Date?
    private let retryCooldown: TimeInterval = 300
    /// label → profile routes that validated to the reviewer login at startup.
    private var activeTierProfiles: [String: String] = [:]
    /// Review-comment thread roots we've already notified about (in-memory).
    private var seenReplyThreadIDs: Set<Int> = []
    private var nextReplyCheckAt: Date = .distantPast
    private var replyCheckInFlight = false
    /// Next due time for the ~6-hourly `cr` update check (network, detached).
    private var nextUpdateCheckAt: Date = .distantPast
    private var updateCheckInFlight = false
    /// Next due time for the ~30-min failed-PR retry sweep (re-attempts hourly).
    private var nextFailureRetryAt: Date = .distantPast
    /// Next due time to re-resolve identity while latched in an identity error,
    /// so a transient `cr me` blip (Keychain settling after a cr upgrade) recovers.
    private var nextIdentityRecheckAt: Date = .distantPast
    /// #326 reply-check is disabled by default: it triggered a recurring control-
    /// loop stall that resisted root-causing even after bounding client timeouts
    /// and detaching the call. Re-enable once the wedge is understood.
    private let replyCheckEnabled = false
    /// Wall-clock of the last completed poll; the watchdog uses it to detect a
    /// wedged loop.
    private var lastPollAt: Date = .distantPast
    private var watchdogTask: Task<Void, Never>?
    /// Wall-clock of daemon.start; stamps daemon.shutdown with an uptime so a
    /// short-lived exit (something forcing us down) is legible in the log.
    private var daemonStartedAt: Date = .distantPast
    /// Set by the menu "Quit" so shutdown logging can tell a deliberate user quit
    /// from an OS-delivered SIGTERM — both reach applicationWillTerminate -> stop().
    public var userQuitRequested = false

    public init(
        config: Config,
        client: GitHubClient,
        store: QueueStore,
        runner: ReviewRunner,
        monitor: PowerNetworkMonitor,
        updater: Updater = Updater(),
        log: Logger = .shared,
        now: @escaping () -> Date = { Date() }
    ) {
        self.config = config
        self.client = client
        self.store = store
        self.runner = runner
        self.monitor = monitor
        self.updater = updater
        self.log = log
        self.nowFn = now
    }

    // MARK: - Lifecycle

    public func start(safeMode: Bool = false) {
        Paths.ensureDirectories()
        daemonStartedAt = nowFn()
        self.safeMode = safeMode
        log.info("daemon.start", ["version": crDaemonVersion, "cr": runner.crBinaryPath, "safe_mode": safeMode])
        let rawCrVersion = runner.crVersion()
        log.info("cr.version", ["version": rawCrVersion])
        crVersionString = Updater.parseSemver(rawCrVersion)

        // Detect a `cr` upgrade across runs: if the installed version changed since
        // last startup, a fix may have landed (the #13 case), so un-stick every
        // previously-failing PR for a fresh attempt. Persist the new version.
        let lastSeen = try? String(contentsOf: Paths.lastCrVersionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = crVersionString, let prev = lastSeen, !prev.isEmpty, prev != current {
            let n = store.resetFailedForRetry()
            log.info("cr.version_changed", ["from": prev, "to": current, "requeued": n])
        }
        if let current = crVersionString {
            try? current.write(to: Paths.lastCrVersionFile, atomically: true, encoding: .utf8)
        }

        // Hard identity guard: never let cr post as anyone but the reviewer login.
        // A *transient* `cr me` failure (e.g. the Keychain ACL re-settling right
        // after a cr upgrade — which the daemon can trigger itself) would latch
        // this into .error for the whole session. recheckIdentityIfNeeded() in the
        // loop re-resolves on a slow cadence and recovers once identity comes back,
        // so no manual restart is needed.
        if !resolveIdentityAndTiers() {
            log.error("daemon.identity_mismatch", ["resolved": identityResolved ?? "nil"])
            runtimeState = .error(identityMismatchMessage)
        }
        if safeMode { runtimeState = .safeMode(reason: "crash loop — auto-work paused") }

        monitor.onSleep = { [weak self] in Task { @MainActor in self?.handleSleep() } }
        monitor.onWake = { [weak self] in Task { @MainActor in self?.handleWake() } }
        monitor.onNetworkChange = { [weak self] online in
            Task { @MainActor in self?.log.info("net.change", ["online": online]); self?.onChange?() }
        }
        monitor.start()

        Task { await self.reconcileOrphans() }

        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        lastPollAt = nowFn()
        startWatchdog()
    }

    public func stop() {
        // The one shutdown path that isn't otherwise logged: applicationWillTerminate,
        // reached by both a user Quit and an OS SIGTERM (logout, launchctl kill,
        // memory pressure). Record which, plus uptime — a short-lived "signal" exit
        // is the fingerprint of something forcing us down. (watchdog.wedged and
        // daemon.already_running already explain their own exits.)
        let uptime = daemonStartedAt == .distantPast
            ? -1 : Int(nowFn().timeIntervalSince(daemonStartedAt))
        log.info(
            "daemon.shutdown",
            ["reason": userQuitRequested ? "user_quit" : "signal", "uptime_s": uptime])
        log.flush()  // we're about to exit; don't let the async queue drop this line
        loopTask?.cancel()
        watchdogTask?.cancel()
        monitor.stop()
    }

    // MARK: - Identity

    private var identityMismatchMessage: String {
        "cr profile '\(config.crProfile)' resolves to "
            + "\(identityResolved ?? "nil"), expected \(config.reviewerLogin)"
    }

    /// Resolve the reviewer identity and validate tier-routing profiles (e.g.
    /// cr:large → reviewer-large). Sets identityResolved/identityOK and keeps only
    /// tier profiles that resolve to the reviewer login (a bad/missing one drops
    /// so a labeled PR falls back to the default profile). Returns whether the
    /// primary identity matches. Blocking (`cr me`); run at startup and, while
    /// latched in an identity error, from the loop via recheckIdentityIfNeeded.
    @discardableResult
    private func resolveIdentityAndTiers() -> Bool {
        identityResolved = runner.resolvedIdentity()
        identityOK = identityResolved?.caseInsensitiveCompare(config.reviewerLogin) == .orderedSame

        var validTiers: [String: String] = [:]
        for (label, prof) in config.tierLabelProfiles {
            if runner.resolvedIdentity(profile: prof)?.caseInsensitiveCompare(config.reviewerLogin)
                == .orderedSame
            {
                validTiers[label] = prof
            } else {
                log.warn("tier_profile.invalid", ["label": label, "profile": prof])
            }
        }
        activeTierProfiles = validTiers
        if !validTiers.isEmpty {
            log.info(
                "tier_profiles.active", ["routes": validTiers.keys.sorted().joined(separator: ",")])
        }
        return identityOK
    }

    /// Self-heal a latched identity error. The startup guard can fail on a
    /// transient `cr me` blip — most commonly the Keychain ACL re-settling right
    /// after a cr upgrade (which the daemon's own auto-upgrade can trigger). Left
    /// alone that strands the daemon in .error until a manual restart; here we
    /// re-resolve on a slow cadence and recover to active once identity returns.
    private func recheckIdentityIfNeeded() {
        guard !identityOK, nowFn() >= nextIdentityRecheckAt else { return }
        nextIdentityRecheckAt = nowFn().addingTimeInterval(60)
        if resolveIdentityAndTiers() {
            log.info("daemon.identity_recovered", ["resolved": identityResolved ?? "?"])
            refreshWorkState()  // identityOK is now true, so this promotes .error → active
        }
    }

    // MARK: - Watchdog

    /// Independent safety net. If the control loop goes silent while it should be
    /// polling (not reviewing, online, not paused/rate-limited), exit so launchd
    /// relaunches us into a clean, reconciled state. Guarantees the daemon
    /// self-heals from any loop wedge regardless of cause — a stall must never be
    /// a permanent outage. Runs detached so a busy main actor can't disable it.
    private func startWatchdog() {
        watchdogTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                if await self.controlLoopWedged() { await self.recoverFromWedge() }
            }
        }
    }

    private func controlLoopWedged() -> Bool {
        guard !config.paused, monitor.isOnline, !safeMode else { return false }
        if let until = rateLimitedUntil, nowFn() < until { return false }
        // Polls run every ~searchPollIntervalSeconds (default 90s). Reviews no
        // longer block the loop (they run as tracked tasks), so polling must
        // stay fresh even while reviewing — five minutes of silence means the
        // loop is wedged, not merely between polls.
        return nowFn().timeIntervalSince(lastPollAt) > 300
    }

    private func recoverFromWedge() {
        log.error(
            "watchdog.wedged",
            [
                "last_poll_age_s": Int(nowFn().timeIntervalSince(lastPollAt)),
                "action": "exit_for_relaunch",
            ])
        // Non-zero exit → launchd (KeepAlive=true) relaunches us; startup
        // reconciliation recovers any interrupted review. Flush first so the
        // wedge line survives the immediate exit.
        log.flush()
        exit(1)
    }

    // MARK: - Control loop

    private func tick() async {
        if safeMode { return }
        if config.paused {
            setState(.paused)
            return
        }
        if !monitor.isOnline {
            setState(.offline)
            return
        }
        recheckIdentityIfNeeded()  // self-heal a latched identity error before working
        let now = nowFn()
        if let until = rateLimitedUntil, now < until {
            setState(.rateLimited(until: until))
            return
        }
        rateLimitedUntil = nil

        if now >= nextPollAt {
            let outcome = await AssignmentWatcher.pollOnce(
                client: client, store: store, config: config, log: log)
            await refreshRate()
            // Heartbeat: proves the authenticated poll ran and surfaces both
            // rate buckets (the numbers come from GitHub's response headers).
            log.info("watch.poll", [
                "core_remaining": rateCore?.remaining ?? -1,
                "search_remaining": rateSearch?.remaining ?? -1,
                "active": store.active().count,
                "discovered": outcome.discovered,
            ])
            if let until = outcome.throttledUntil {
                throttle(until: until)
                nextPollAt = rateLimitedUntil ?? now
            } else {
                nextPollAt = now.addingTimeInterval(jitteredInterval())
            }
            lastPollAt = now
            onChange?()
        }

        // Watch for human replies to our review threads (#326), on a slow cadence.
        // Detached with a single-flight guard: a slow or hung reply fetch must
        // never block the poll+review loop (it once wedged the daemon for ~50min,
        // because this was awaited inline). Bounded client timeouts guarantee the
        // detached task always completes and clears the flag.
        if replyCheckEnabled, identityOK, !runner.isRunning, !replyCheckInFlight,
            now >= nextReplyCheckAt
        {
            nextReplyCheckAt = now.addingTimeInterval(300)
            replyCheckInFlight = true
            Task { [weak self] in
                await self?.checkThreadReplies()
                self?.replyCheckInFlight = false
            }
        }

        // Check upstream for a newer `cr` once at startup, then ~every 6h. Detached
        // with a single-flight guard so a slow network call never blocks the loop
        // (mirrors the reply-check). Sets crUpdateAvailable for the menu.
        if !updateCheckInFlight, now >= nextUpdateCheckAt {
            nextUpdateCheckAt = now.addingTimeInterval(6 * 3600)
            updateCheckInFlight = true
            Task { [weak self] in
                await self?.checkForCRUpdate()
                self?.updateCheckInFlight = false
            }
        }

        // Re-attempt failed PRs on a slow cadence (sweep every ~30min; eligible
        // when the failure is >1h old) so a transient/random failure eventually
        // succeeds instead of staying permanently quarantined.
        if now >= nextFailureRetryAt {
            nextFailureRetryAt = now.addingTimeInterval(30 * 60)
            let requeued = store.retryEligibleFailures(now: now, backoff: 3600)
            if requeued > 0 {
                log.info("failures.requeued", ["count": requeued])
                onChange?()
            }
        }

        processQueueStep()

        // Reaching here means we're on the active path (paused/offline/rate-limited
        // returned early); reflect idle-but-watching or the in-flight set.
        refreshWorkState()
    }

    /// Fill free review slots from the pending queue. Enforces: the concurrency
    /// cap, one-review-per-repo (shared checkout), daily cap, per-PR attempt
    /// cap + cooldown, confirm-mode parking, and an execution-time allowlist
    /// re-check (a safety boundary, not just a filter). Reviews are launched as
    /// tracked tasks so the control loop keeps polling while they run.
    private func processQueueStep() {
        guard identityOK, !safeMode else { return }
        let slots = config.maxConcurrentReviews - inFlight.count
        guard slots > 0 else { return }
        let started24h = store.reviewStartsInLast24h()
        // dailyReviewCap == 0 disables the runaway guard entirely (no cap).
        let capEnabled = config.dailyReviewCap > 0
        if capEnabled && started24h >= config.dailyReviewCap {
            log.warn("review.daily_cap", ["cap": config.dailyReviewCap])
            return
        }
        let capSlots = capEnabled ? min(slots, config.dailyReviewCap - started24h) : slots
        let picks = Coordinator.selectCandidates(
            pending: store.pending(),
            inFlight: Set(inFlight.keys),
            slots: capSlots,
            now: nowFn(),
            attemptCap: config.perPrAttemptCap,
            cooldown: retryCooldown)
        for next in picks {
            guard config.isOrgAllowed(next.org) else {
                store.update(next.key) {
                    $0.state = .skipped
                    $0.lastError = "org not allowlisted"
                }
                log.warn("review.blocked_org", ["pr": next.key.description, "org": next.org])
                continue
            }
            launchReview(next)
        }
    }

    /// Pure slot-filling selection, extracted for unit tests: eligible pending
    /// PRs, oldest first, skipping anything in flight and never choosing two
    /// PRs of the same repo (concurrent runs would collide in the managed
    /// checkout — the "workbench has local changes" failure).
    nonisolated public static func selectCandidates(
        pending: [Assignment], inFlight: Set<PRKey>, slots: Int, now: Date,
        attemptCap: Int, cooldown: TimeInterval
    ) -> [Assignment] {
        var chosen: [Assignment] = []
        var busyRepos = Set(inFlight.map { $0.slug.lowercased() })
        for a in pending {
            if chosen.count >= slots { break }
            if a.awaitingConfirm == true { continue }
            if a.attempts >= attemptCap { continue }
            if let started = a.startedAt, a.attempts > 0,
                now < started.addingTimeInterval(cooldown) { continue }
            if inFlight.contains(a.key) { continue }
            let repo = a.key.slug.lowercased()
            if busyRepos.contains(repo) { continue }
            busyRepos.insert(repo)
            chosen.append(a)
        }
        return chosen
    }

    /// Launch a review as a tracked in-flight task and reflect it in the state.
    private func launchReview(_ assignment: Assignment, forceLive: Bool = false) {
        let key = assignment.key
        guard inFlight[key] == nil else { return }
        inFlight[key] = Task { [weak self] in
            guard let self else { return }
            await self.runReview(assignment, forceLive: forceLive)
            self.inFlight[key] = nil
            self.refreshWorkState()
            self.onChange?()
        }
        refreshWorkState()
    }

    /// Reflect the in-flight set in the runtime state (active when idle).
    /// Never overrides paused/offline/error states — callers are on the
    /// active path.
    private func refreshWorkState() {
        guard identityOK, !safeMode, !config.paused else { return }
        if inFlight.isEmpty {
            setState(.active)
        } else {
            setState(.reviewing(inFlight.keys.sorted { $0.description < $1.description }))
        }
    }

    // MARK: - Review execution

    private func runReview(_ assignment: Assignment, forceLive: Bool = false) async {
        let key = assignment.key
        let confirm = (config.autonomy == .confirm) && !forceLive
        // Route by label (e.g. cr:large → Opus profile); falls back to the default.
        // Tier-routed runs also get the larger wall-clock budget — big diffs on
        // the big model legitimately take longer than the default timeout.
        let tierLabel = Config.matchedTierLabel(
            labels: assignment.labels ?? [], tierMap: activeTierProfiles)
        let chosenProfile = Config.selectProfile(
            labels: assignment.labels ?? [], tierMap: activeTierProfiles, fallback: config.crProfile)
        let runTimeout = TimeInterval(
            tierLabel != nil ? config.reviewTimeoutLargeSeconds : config.reviewTimeoutSeconds)
        // Head + our prior review, fetched up front (both are needed below anyway).
        let detail = try? await client.pullRequest(key)
        let priorReview = try? await client.latestReviewState(key, by: config.reviewerLogin)

        // No-op guard: GitHub can keep listing a PR as review-requested after we
        // post a COMMENTED/CHANGES_REQUESTED review, and discovery treats any
        // still-listed done PR past the settle window as a re-request. Without
        // this check that loops forever: requeue → review → done → requeue,
        // burning an attempt, a daily-cap slot, and a cr spawn every few minutes.
        // Same head + review already posted ⇒ no new work; finish quietly. A
        // prior APPROVED still gets the deliberate fresh pass (--rerun) below —
        // unless this row was re-queued by an automatic retry sweep, which is
        // never a human re-request: an existing approval fully satisfies it
        // (observed live: an already-approved heavy PR was redundantly
        // re-reviewed for 30 minutes after a sweep). A moved head reviews
        // normally either way.
        let sweepRetry = store.get(key)?.retryRequeue == true
        if !confirm, let d = detail, let prior = priorReview,
            prior.uppercased() != "APPROVED" || sweepRetry,
            store.get(key)?.headShaReviewed == d.headSHA
        {
            store.update(key) {
                $0.state = .done
                $0.finishedAt = nowFn()
                $0.lastOutcome = ReviewOutcome.from(reviewState: prior)
                $0.crPid = nil
            }
            store.appendEvent(
                "review.noop_same_head", ["pr": key.description, "review_state": prior])
            log.info("review.noop_same_head", ["pr": key.description, "review_state": prior])
            return
        }

        let token = UUID().uuidString
        store.update(key) {
            $0.state = .reviewing
            $0.attempts += 1
            $0.startedAt = nowFn()
            $0.runToken = token
            $0.awaitingConfirm = nil
            $0.lastError = nil
        }
        store.recordReviewStart()
        store.appendEvent(
            "review.start", ["pr": key.description, "confirm": confirm, "profile": chosenProfile])
        onChange?()

        if let detail {
            store.update(key) {
                $0.headShaReviewed = detail.headSHA
                $0.headShaSeen = detail.headSHA
            }
        }

        // cr exits early if the reviewer has already approved (even on a stale
        // approval). So if a prior approval exists, force a fresh pass — otherwise
        // a re-requested review would be a no-op instead of a real re-review.
        let needsRerun = priorReview?.uppercased() == "APPROVED"

        let onLaunch: @Sendable (Int32) -> Void = { pid in
            // Record the live pid so restart reconciliation can tell a
            // still-running review (adopt it) from a dead one (requeue it).
            Task { @MainActor [weak self] in
                self?.store.update(key) { $0.crPid = pid }
            }
        }
        var result = await runner.runReview(
            url: assignment.url, profile: chosenProfile, dryRun: confirm, rerun: needsRerun,
            timeoutOverride: runTimeout, onLaunch: onLaunch)

        // Two stale-session cases are recoverable right now with a fresh pass,
        // not real failures — without this retry the PR burns attempts on the
        // identical error every lap:
        // - cr refuses to resume a session whose inputs changed underneath it
        //   ("input fingerprint changed; pass --rerun").
        // - claude can't find a session created under a different transport or
        //   cleaned up since ("No conversation found with session ID") — e.g.
        //   the ledger holds a bg-mode session id but reviews now run foreground.
        let combined = result.stderr + result.stdout
        if !confirm, !needsRerun, !result.succeeded,
            combined.contains("input fingerprint changed")
                || combined.contains("No conversation found with session ID")
        {
            log.info("review.rerun_fingerprint", ["pr": key.description])
            store.appendEvent("review.rerun_fingerprint", ["pr": key.description])
            result = await runner.runReview(
                url: assignment.url, profile: chosenProfile, dryRun: confirm, rerun: true,
                timeoutOverride: runTimeout, onLaunch: onLaunch)
        }

        if result.timedOut {
            // A timed-out run resumes cheaply via its per-PR --session (the
            // next attempt picks up the prior run's work), so grant one more
            // budget window before declaring the PR over-budget and posting
            // the escalation guidance.
            let attempts = store.get(key)?.attempts ?? config.perPrAttemptCap
            if attempts < config.perPrAttemptCap {
                finishFailure(key, exit: result.exitCode, error: "timed out", terminal: false)
                return
            }
            await postTimeoutGuidance(
                key: key, usedLargeTier: tierLabel != nil, budgetSeconds: Int(runTimeout))
            finishFailure(key, exit: result.exitCode, error: "timed out", terminal: true)
            return
        }
        if !result.succeeded {
            let raw = result.stderr.isEmpty ? result.stdout : result.stderr
            let tail = Redact.scrub(String(raw.suffix(300)))
            let attempts = store.get(key)?.attempts ?? config.perPrAttemptCap
            finishFailure(key, exit: result.exitCode, error: tail,
                terminal: attempts >= config.perPrAttemptCap)
            return
        }

        if confirm {
            let plan = Redact.scrub(String(result.stdout.suffix(800)))
            store.update(key) {
                $0.state = .pending
                $0.awaitingConfirm = true
                $0.lastSummary = plan
            }
            store.appendEvent("review.dry_run", ["pr": key.description])
            notify("Review ready to post", "\(key) — open the menu to approve/post")
            onChange?()
            setState(.active)
            return
        }

        // Authoritative outcome: what review did the reviewer actually submit?
        let reviewState = try? await client.latestReviewState(key, by: config.reviewerLogin)
        let outcome = ReviewOutcome.from(reviewState: reviewState)
        store.update(key) {
            $0.state = .done
            $0.finishedAt = nowFn()
            $0.lastOutcome = outcome
            $0.lastExitCode = result.exitCode
            $0.attempts = 0  // successful pass; only consecutive failures count toward the cap
            $0.awaitingConfirm = nil
            $0.crPid = nil
            $0.lastSummary = "cr exited 0; review=\(reviewState ?? "none")"
        }
        store.appendEvent("review.done", [
            "pr": key.description, "outcome": outcome.rawValue,
            "review_state": reviewState ?? "none",
        ])
        notifyOutcome(key, outcome)
        onChange?()
    }

    /// Leave next-step guidance on the PR after a timeout kill. Best-effort: a
    /// failed post is logged, never fatal — the review failure path proceeds
    /// regardless.
    private func postTimeoutGuidance(key: PRKey, usedLargeTier: Bool, budgetSeconds: Int) async {
        guard config.timeoutGuidanceComment else { return }
        let body = TimeoutNotice.body(
            minutes: max(1, budgetSeconds / 60),
            usedLargeTier: usedLargeTier,
            largeLabel: activeTierProfiles.keys.sorted().first)
        do {
            try await client.postIssueComment(key, body: body)
            store.appendEvent(
                "review.timeout_notice", ["pr": key.description, "posted": true])
        } catch {
            store.appendEvent(
                "review.timeout_notice",
                ["pr": key.description, "posted": false,
                 "reason": Redact.scrub(String(describing: error))])
            log.warn("review.timeout_notice_failed", ["pr": key.description])
        }
    }

    private func finishFailure(_ key: PRKey, exit: Int32, error: String, terminal proposedTerminal: Bool) {
        let reason = Coordinator.classifyFailure(exit: exit, error: error)
        // A transient upstream blip (GitHub 5xx, model overload — cr exit 5) must
        // not be quarantined for an outage it didn't cause: never terminal, and pin
        // the attempt count below the cap so the retry cooldown keeps pacing
        // attempts (~5min) until the dependency recovers. Real failures keep their
        // incremented count and can still hit the terminal cap.
        let transient = reason.kind == .upstream
        let terminal = proposedTerminal && !transient
        store.update(key) {
            $0.state = terminal ? .failed : .pending
            $0.lastExitCode = exit
            $0.lastError = error
            $0.crPid = nil
            // Re-anchor the retry cooldown at the failure, not the launch: a
            // run that outlives its own cooldown would otherwise relaunch the
            // instant it fails (and collide with its just-killed run's lock).
            $0.startedAt = nowFn()
            if transient { $0.attempts = min($0.attempts, 1) }
            if terminal {
                $0.finishedAt = nowFn()
                $0.lastOutcome = .failed
            }
        }
        // Log WHY, not just the exit code. cr's exit 5 (`exitUpstream`) covers a
        // GitHub 5xx *and* a model-provider failure — without the reason text a
        // 502 burst is indistinguishable from a quota wall, and a confident wrong
        // guess fills the gap. `kind` makes failures triage-able at a glance.
        let fields: [String: Any] = [
            "pr": key.description, "exit": Int(exit), "terminal": terminal,
            "kind": reason.kind.rawValue, "reason": reason.summary,
        ]
        store.appendEvent("review.fail", fields)
        log.warn("review.fail", fields)
        if terminal, config.notifyOn.errors {
            notify("Review failed", "\(key) — \(reason.summary)")
        }
        onChange?()
    }

    /// How a `cr` failure should be read. Derived from the exit code plus the
    /// error tail so the log/menu/notification name a cause instead of a bare
    /// number. `upstream` = a transient dependency blip (GitHub 5xx, model
    /// overload/rate-limit) that the failure-retry sweep will recover on its own.
    public enum FailureKind: String { case upstream, timeout, auth, other }
    public struct FailureReason { public let kind: FailureKind; public let summary: String }

    public nonisolated static func classifyFailure(exit: Int32, error: String) -> FailureReason {
        // Compact one-line summary: the last non-empty line of cr's output tail
        // (the GetPR/upstream message), already redaction-scrubbed upstream.
        var summary = String(
            (error.split(whereSeparator: \.isNewline).last.map(String.init) ?? error)
                .trimmingCharacters(in: .whitespaces).prefix(160))
        let e = error.lowercased()
        let kind: FailureKind
        if e.contains("background job timed out"), e.contains("starting") {
            // The LLM job never reported a state before its task deadline. In
            // practice the session often did start and then died mid-turn on the
            // CLI/provider side without ever writing its state file — a stall in
            // the layer below cr, not anything wrong with the PR. Upstream ⇒
            // retries don't burn the terminal attempt cap, and completed sibling
            // tasks are banked in cr's ledger, so successive retries converge.
            kind = .upstream
            summary += " — provider/CLI session stall; retrying (completed tasks are reused)"
        } else if e.contains("timed out") || e.contains("timeout") {
            kind = .timeout
        } else if e.contains("status 401") || e.contains("status 403")
            || e.contains("unauthorized") || e.contains("forbidden")
            || e.contains("credential") || e.contains("identity")
        {
            kind = .auth
        } else if exit == 5 || e.contains("upstream") || e.contains("overloaded")
            || e.contains("rate limit") || e.contains("status 500")
            || e.contains("status 502") || e.contains("status 503")
            || e.contains("status 504") || e.contains("status 529")
        {
            kind = .upstream
        } else {
            kind = .other
        }
        return FailureReason(kind: kind, summary: summary)
    }

    // MARK: - Crash recovery

    /// Recover reviewing rows whose `cr` process died (crash/sleep/restart): try
    /// `--retry-posts` to finish partial posts; if that can't recover, re-queue.
    /// Rows whose `cr` process is still alive are adopted instead — the run
    /// completes on its own and posts its review; relaunching it would only
    /// collide with its run lock.
    public func reconcileOrphans() async {
        adoptLiveReviews()
        let orphans = store.orphanedReviewing(isPidAlive: Supervisor.isPidAlive)
        guard !orphans.isEmpty else { return }
        log.info("reconcile.orphans", ["count": orphans.count])
        for a in orphans {
            let r = await runner.retryPosts(url: a.url)
            if r.succeeded {
                let reviewState = try? await client.latestReviewState(a.key, by: config.reviewerLogin)
                let outcome = ReviewOutcome.from(reviewState: reviewState)
                store.update(a.key) {
                    $0.state = .done
                    $0.finishedAt = nowFn()
                    $0.lastOutcome = outcome
                    $0.crPid = nil
                    $0.lastSummary = "recovered via retry-posts; review=\(reviewState ?? "none")"
                }
            } else {
                store.update(a.key) {
                    $0.state = .pending
                    $0.crPid = nil
                    $0.lastError = "recovered after interruption — re-queued"
                    // An interruption (daemon restart/sleep) is not the PR's
                    // fault. At the cap the row would be permanently
                    // unrunnable-pending — the queue filter skips attempts >=
                    // cap but only .failed rows get swept — so pin below the
                    // cap to guarantee at least one more real attempt.
                    $0.attempts = min($0.attempts, self.config.perPrAttemptCap - 1)
                }
            }
        }
        onChange?()
    }

    // MARK: - Thread replies (#326)

    /// Detect human replies to review threads the reviewer started on recently
    /// reviewed PRs, and surface them (notification + event). This is the trigger
    /// half of conversational replies; generating + posting the reply is the next
    /// increment (the cr engine).
    private func checkThreadReplies() async {
        let cutoff = nowFn().addingTimeInterval(-24 * 3600)
        let recent = store.all().filter {
            $0.state == .done && ($0.finishedAt ?? .distantPast) >= cutoff
        }
        for assignment in recent {
            let threads = try? await client.unansweredReplyThreads(
                assignment.key, reviewerLogin: config.reviewerLogin)
            for thread in threads ?? [] where !seenReplyThreadIDs.contains(thread.rootCommentID) {
                seenReplyThreadIDs.insert(thread.rootCommentID)
                log.info(
                    "thread.reply", ["pr": assignment.key.description, "from": thread.lastReplyAuthor])
                store.appendEvent(
                    "thread.reply",
                    [
                        "pr": assignment.key.description, "from": thread.lastReplyAuthor,
                        "comment": thread.rootCommentID,
                    ])
                if config.notifyOn.findings {
                    notify(
                        "New reply on \(assignment.key)",
                        "\(thread.lastReplyAuthor): \(String(thread.lastReplyBody.prefix(80)))")
                }
            }
        }
        onChange?()
    }

    // MARK: - cr self-update

    /// Ask GitHub for the latest `cr` release; if it's newer than the installed
    /// version, surface it in the menu. Network call runs on this detached task,
    /// never inline in the loop. No-op (clears the flag) on any error.
    private func checkForCRUpdate() async {
        guard let installed = crVersionString,
            let latest = await updater.latestReleaseVersion()
        else { return }
        if Updater.isNewer(latest, than: installed) {
            crUpdateAvailable = latest
            log.info("cr.update_available", ["installed": installed, "latest": latest])
        } else {
            crUpdateAvailable = nil
        }
        onChange?()
    }

    /// One-click upgrade of `cr` via Homebrew. Runs detached (minutes-long); the
    /// `upgrading` flag drives the menu. Upgrading mid-review is safe: the in-flight
    /// `cr` process keeps its already-loaded binary, so only the *next* review uses
    /// the new one — we deliberately do NOT block on or cancel the current review.
    /// On success we re-read the version, clear the update flag, and un-stick failed
    /// PRs (a fix may have landed) so newly-fixable PRs get re-reviewed.
    public func upgradeCR() {
        guard !upgrading else { return }
        upgrading = true
        log.info("cr.upgrade_start", [:])
        onChange?()
        Task { [weak self] in
            guard let self else { return }
            let result = await self.updater.upgradeCR()
            await MainActor.run {
                self.upgrading = false
                let raw = self.runner.crVersion()
                self.crVersionString = Updater.parseSemver(raw)
                self.crUpdateAvailable = nil
                if let current = self.crVersionString {
                    try? current.write(
                        to: Paths.lastCrVersionFile, atomically: true, encoding: .utf8)
                }
                let n = self.store.resetFailedForRetry()
                self.log.info(
                    "cr.upgrade_done",
                    ["ok": result.ok, "version": self.crVersionString ?? "?", "requeued": n])
                if result.ok {
                    self.notify("cr upgraded", "Now \(self.crVersionString ?? "?") — re-queued \(n) PR(s)")
                } else {
                    self.notify("cr upgrade failed", String(result.output.suffix(120)))
                }
                self.onChange?()
            }
        }
    }

    // MARK: - Power / network

    /// Adopt reviews that survived a daemon restart: the row is `.reviewing`
    /// and its recorded pid is alive. Hold the PR in the in-flight set (so the
    /// scheduler won't double-launch it or its repo) and watch the pid; when
    /// the process exits, resolve the outcome from GitHub like a normal run.
    /// Adopted runs get a fresh wall-clock deadline — the original run's
    /// timeout died with the old daemon, and a run frozen through a sleep
    /// cycle would otherwise squat on its slot, repo, and run lock forever.
    private func adoptLiveReviews() {
        let live = store.reviewingWithLivePid(isPidAlive: Supervisor.isPidAlive)
        for a in live {
            let key = a.key
            guard inFlight[key] == nil, let pid = a.crPid else { continue }
            log.info("reconcile.adopted", ["pr": key.description, "pid": Int(pid)])
            adoptedPids[key] = pid
            // Same tier-appropriate budget as an owned run — a healthy review
            // finishes in well under 10 minutes, so blanket-granting the Large
            // budget here let a stalled adopted run squat for 90 minutes.
            let adoptedTier = Config.matchedTierLabel(
                labels: a.labels ?? [], tierMap: activeTierProfiles)
            let deadline = nowFn().addingTimeInterval(
                TimeInterval(
                    adoptedTier != nil
                        ? config.reviewTimeoutLargeSeconds : config.reviewTimeoutSeconds))
            inFlight[key] = Task { [weak self] in
                var sentTerm = false
                while Supervisor.isPidAlive(pid), !Task.isCancelled {
                    guard let self else { return }
                    // A healthy review can't be told from a wedged one by process
                    // tree — cr runs its reviewers as detached processes, so it has
                    // zero descendants either way. Bound the run by the deadline
                    // only, but escalate the kill so a run that ignores SIGTERM
                    // doesn't survive it.
                    if self.nowFn() > deadline {
                        if sentTerm {
                            Subprocess.killTree(pid, signal: SIGKILL)
                        } else {
                            self.log.warn(
                                "reconcile.adopted_timeout",
                                ["pr": key.description, "pid": Int(pid)])
                            Subprocess.killTree(pid, signal: SIGTERM)
                            sentTerm = true
                        }
                    }
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
                self?.adoptedPids[key] = nil
                guard let self else { return }
                let reviewState = try? await self.client.latestReviewState(
                    key, by: self.config.reviewerLogin)
                let outcome = ReviewOutcome.from(reviewState: reviewState)
                self.store.update(key) {
                    $0.state = reviewState == nil ? .pending : .done
                    $0.finishedAt = self.nowFn()
                    $0.lastOutcome = reviewState == nil ? nil : outcome
                    $0.crPid = nil
                    $0.startedAt = self.nowFn()  // cooldown anchor if re-queued
                    $0.lastSummary = "adopted run finished; review=\(reviewState ?? "none")"
                }
                self.store.appendEvent("review.adopted_done", [
                    "pr": key.description, "review_state": reviewState ?? "none",
                ])
                self.inFlight[key] = nil
                self.refreshWorkState()
                self.onChange?()
            }
        }
        if !live.isEmpty { refreshWorkState() }
    }

    private func handleSleep() {
        log.info("power.sleep", [:])
        // Let in-flight reviews be interrupted; each runReview flow re-queues its
        // own PR, and recovery happens on wake. Adopted runs aren't runner-owned,
        // so cancel them explicitly — a run frozen through sleep never finishes.
        if runner.isRunning { runner.cancelAll() }
        for (key, pid) in adoptedPids {
            log.warn("review.cancel_adopted", ["pr": key.description, "pid": Int(pid)])
            Subprocess.killTree(pid, signal: SIGTERM)
        }
    }

    private func handleWake() {
        log.info("power.wake", [:])
        // Don't poll instantly — wait for the network to come back (tick gates on
        // monitor.isOnline). Re-derive next poll from wall-clock, with a small delay.
        nextPollAt = nowFn().addingTimeInterval(5)
        Task { await self.reconcileOrphans() }
    }

    // MARK: - User actions (from the menu)

    public func pause() {
        config.paused = true
        try? config.save()
        log.info("daemon.paused", [:])
        setState(.paused)
        onChange?()
    }

    public func resume() {
        config.paused = false
        try? config.save()
        nextPollAt = nowFn()
        log.info("daemon.resumed", [:])
        onChange?()
    }

    public func pollNow() {
        nextPollAt = .distantPast
        onChange?()
    }

    /// Force a live review now (menu "Review now" / confirm-mode "Approve & post").
    public func reviewNow(_ key: PRKey) {
        guard identityOK, let a = store.get(key) else { return }
        launchReview(a, forceLive: true)
    }

    public func skip(_ key: PRKey) {
        store.update(key) {
            $0.state = .skipped
            $0.awaitingConfirm = nil
            $0.lastError = "skipped by user"
        }
        log.info("assignment.skip_user", ["pr": key.description])
        onChange?()
    }

    public func reloadConfig() {
        config = Config.load(from: Paths.configFile)
        Task { await client.updateFloors(core: config.coreRateFloor, search: config.searchRateFloor) }
        log.info("config.reloaded", [:])
        onChange?()
    }

    // MARK: - Helpers

    private func jitteredInterval() -> TimeInterval {
        let base = Double(config.searchPollIntervalSeconds)
        return base + Double.random(in: 0...(base * 0.2))
    }

    private func refreshRate() async {
        let snap = await client.snapshot()
        rateCore = snap.core
        rateSearch = snap.search
        if let until = snap.circuitOpenUntil { throttle(until: until) }
    }

    /// Set the rate-limit backoff deadline, capped so a bad or absurd value
    /// (e.g. a misparsed `X-RateLimit-Reset`, or a circuit-breaker bug) can never
    /// wedge the daemon idle indefinitely — a legitimate GitHub reset is always
    /// within the hour. Paired with state-transition logging, a stall is now both
    /// bounded and visible.
    private func throttle(until: Date) {
        let cap = nowFn().addingTimeInterval(3600)
        rateLimitedUntil = min(until, cap)
    }

    private func setState(_ s: RuntimeState) {
        runtimeState = s
    }

    private func notify(_ title: String, _ body: String) {
        onNotify?(title, body)
    }

    private func notifyOutcome(_ key: PRKey, _ outcome: ReviewOutcome) {
        switch outcome {
        case .approved:
            if config.notifyOn.approvals {
                notify("Approved \(key)", "cr-daemon approved as \(config.reviewerLogin)")
            }
        case .changesRequested, .commented:
            if config.notifyOn.findings { notify("Reviewed \(key)", "Outcome: \(outcome.rawValue)") }
        default:
            break
        }
    }
}
