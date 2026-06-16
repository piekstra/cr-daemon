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
    /// #326 reply-check is disabled by default: it triggered a recurring control-
    /// loop stall that resisted root-causing even after bounding client timeouts
    /// and detaching the call. Re-enable once the wedge is understood.
    private let replyCheckEnabled = false
    /// Wall-clock of the last completed poll; the watchdog uses it to detect a
    /// wedged loop.
    private var lastPollAt: Date = .distantPast
    private var watchdogTask: Task<Void, Never>?

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
        identityResolved = runner.resolvedIdentity()
        identityOK = identityResolved?.caseInsensitiveCompare(config.reviewerLogin) == .orderedSame
        if !identityOK {
            let msg = "cr profile '\(config.crProfile)' resolves to "
                + "\(identityResolved ?? "nil"), expected \(config.reviewerLogin)"
            log.error("daemon.identity_mismatch", ["resolved": identityResolved ?? "nil"])
            runtimeState = .error(msg)
        }
        if safeMode { runtimeState = .safeMode(reason: "crash loop — auto-work paused") }

        // Validate tier-routing profiles (e.g. cr:large → reviewer-large). Keep only
        // those that resolve to the reviewer login; a bad/missing one is dropped so
        // a labeled PR safely falls back to the default profile.
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
        loopTask?.cancel()
        watchdogTask?.cancel()
        monitor.stop()
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
        guard !runner.isRunning, !config.paused, monitor.isOnline, !safeMode else { return false }
        if let until = rateLimitedUntil, nowFn() < until { return false }
        // Polls run every ~searchPollIntervalSeconds (default 90s). Five minutes of
        // silence while idle means the loop is wedged, not merely between polls.
        return nowFn().timeIntervalSince(lastPollAt) > 300
    }

    private func recoverFromWedge() {
        log.error(
            "watchdog.wedged",
            [
                "last_poll_age_s": Int(nowFn().timeIntervalSince(lastPollAt)),
                "action": "exit_for_relaunch",
            ])
        // Non-zero exit → launchd (KeepAlive SuccessfulExit=false) relaunches us;
        // startup reconciliation recovers any interrupted review.
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

        await processQueueStep()

        // Reaching here means we're on the active path (paused/offline/rate-limited
        // returned early); reflect idle-but-watching unless a review just started.
        if identityOK, !runner.isRunning { setState(.active) }
    }

    /// Pick at most one eligible pending PR and review it. Enforces: serialization,
    /// daily cap, per-PR attempt cap + cooldown, confirm-mode parking, and an
    /// execution-time allowlist re-check (a safety boundary, not just a filter).
    private func processQueueStep() async {
        guard identityOK, !safeMode, !runner.isRunning else { return }
        if store.reviewStartsInLast24h() >= config.dailyReviewCap {
            log.warn("review.daily_cap", ["cap": config.dailyReviewCap])
            return
        }
        let now = nowFn()
        let candidate = store.pending().first { a in
            if a.awaitingConfirm == true { return false }
            if a.attempts >= config.perPrAttemptCap { return false }
            if let started = a.startedAt, a.attempts > 0,
                now < started.addingTimeInterval(retryCooldown) { return false }
            return true
        }
        guard let next = candidate else { return }
        guard config.isOrgAllowed(next.org) else {
            store.update(next.key) {
                $0.state = .skipped
                $0.lastError = "org not allowlisted"
            }
            log.warn("review.blocked_org", ["pr": next.key.description, "org": next.org])
            return
        }
        await runReview(next)
    }

    // MARK: - Review execution

    private func runReview(_ assignment: Assignment, forceLive: Bool = false) async {
        let key = assignment.key
        let confirm = (config.autonomy == .confirm) && !forceLive
        // Route by label (e.g. cr:large → Opus profile); falls back to the default.
        let chosenProfile = Config.selectProfile(
            labels: assignment.labels ?? [], tierMap: activeTierProfiles, fallback: config.crProfile)
        setState(.reviewing(key))
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

        if let detail = try? await client.pullRequest(key) {
            store.update(key) {
                $0.headShaReviewed = detail.headSHA
                $0.headShaSeen = detail.headSHA
            }
        }

        // cr exits early if the reviewer has already approved (even on a stale
        // approval). So if a prior approval exists, force a fresh pass — otherwise
        // a re-requested review would be a no-op instead of a real re-review.
        let priorReview = try? await client.latestReviewState(key, by: config.reviewerLogin)
        let needsRerun = priorReview?.uppercased() == "APPROVED"

        let result = await runner.runReview(
            url: assignment.url, profile: chosenProfile, dryRun: confirm, rerun: needsRerun)

        if result.timedOut {
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
        setState(.active)
    }

    private func finishFailure(_ key: PRKey, exit: Int32, error: String, terminal: Bool) {
        store.update(key) {
            $0.state = terminal ? .failed : .pending
            $0.lastExitCode = exit
            $0.lastError = error
            $0.crPid = nil
            if terminal {
                $0.finishedAt = nowFn()
                $0.lastOutcome = .failed
            }
        }
        store.appendEvent("review.fail", [
            "pr": key.description, "exit": Int(exit), "terminal": terminal,
        ])
        log.warn("review.fail", ["pr": key.description, "exit": Int(exit), "terminal": terminal])
        if terminal, config.notifyOn.errors {
            notify("Review failed", "\(key) — \(String(error.prefix(120)))")
        }
        onChange?()
        if identityOK { setState(.active) }
    }

    // MARK: - Crash recovery

    /// Recover reviewing rows whose `cr` process died (crash/sleep/restart): try
    /// `--retry-posts` to finish partial posts; if that can't recover, re-queue.
    public func reconcileOrphans() async {
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

    private func handleSleep() {
        log.info("power.sleep", [:])
        // Let an in-flight review be interrupted; the runReview flow re-queues it,
        // and recovery happens on wake.
        if runner.isRunning { runner.cancelCurrent() }
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
        Task { @MainActor in
            guard identityOK, !runner.isRunning, let a = store.get(key) else { return }
            await runReview(a, forceLive: true)
        }
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
