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

    public init(
        config: Config,
        client: GitHubClient,
        store: QueueStore,
        runner: ReviewRunner,
        monitor: PowerNetworkMonitor,
        log: Logger = .shared,
        now: @escaping () -> Date = { Date() }
    ) {
        self.config = config
        self.client = client
        self.store = store
        self.runner = runner
        self.monitor = monitor
        self.log = log
        self.nowFn = now
    }

    // MARK: - Lifecycle

    public func start(safeMode: Bool = false) {
        Paths.ensureDirectories()
        self.safeMode = safeMode
        log.info("daemon.start", ["version": crDaemonVersion, "cr": runner.crBinaryPath, "safe_mode": safeMode])
        log.info("cr.version", ["version": runner.crVersion()])

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
    }

    public func stop() {
        loopTask?.cancel()
        monitor.stop()
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
            onChange?()
        }

        // Watch for human replies to our review threads (#326), on a slow cadence.
        // Detached with a single-flight guard: a slow or hung reply fetch must
        // never block the poll+review loop (it once wedged the daemon for ~50min,
        // because this was awaited inline). Bounded client timeouts guarantee the
        // detached task always completes and clears the flag.
        if identityOK, !runner.isRunning, !replyCheckInFlight, now >= nextReplyCheckAt {
            nextReplyCheckAt = now.addingTimeInterval(300)
            replyCheckInFlight = true
            Task { [weak self] in
                await self?.checkThreadReplies()
                self?.replyCheckInFlight = false
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
