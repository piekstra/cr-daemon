import Foundation

/// Result of one watch cycle.
public struct PollOutcome: Sendable {
    public let discovered: Int
    public let withdrawn: Int
    /// If the GitHub bucket/circuit told us to hold off, when we may try again.
    public let throttledUntil: Date?
    public let error: String?
}

/// The Search-API poller — the *source of truth* for which PRs currently have
/// the reviewer requested. One poll = search → filter by the org allowlist +
/// optional author allowlist → reconcile into the queue. Stateless aside from
/// the store/client it's handed, so it's easy to test.
public enum AssignmentWatcher {
    public static func pollOnce(
        client: GitHubClient, store: QueueStore, config: Config, log: Logger = .shared
    ) async -> PollOutcome {
        do {
            let prs = try await client.searchOpenReviewRequested(login: config.reviewerLogin)
            let allowed = prs.filter {
                config.isOrgAllowed($0.key.owner) && config.isAuthorAllowed($0.author)
            }

            var currentKeys = Set<String>()
            var discovered = 0
            for pr in allowed {
                currentKeys.insert(pr.key.description)
                let existed = store.get(pr.key) != nil
                store.upsertDiscovered(pr, org: pr.key.owner.lowercased())
                if !existed { discovered += 1 }
            }
            // Anything pending we previously tracked but is no longer requested
            // (withdrawn / closed / merged) is skipped. Only safe on a clean poll.
            store.markWithdrawnPending(currentKeys: currentKeys)

            if discovered > 0 {
                log.info("watch.discovered", ["count": discovered, "total_requested": allowed.count])
            }
            return PollOutcome(
                discovered: discovered, withdrawn: 0, throttledUntil: nil, error: nil)
        } catch let GitHubError.throttled(resource, until) {
            log.info("watch.throttled", ["resource": resource.rawValue])
            return PollOutcome(discovered: 0, withdrawn: 0, throttledUntil: until, error: "floor")
        } catch let GitHubError.secondaryLimit(until) {
            return PollOutcome(
                discovered: 0, withdrawn: 0, throttledUntil: until, error: "secondary_limit")
        } catch let GitHubError.circuitOpen(until) {
            return PollOutcome(
                discovered: 0, withdrawn: 0, throttledUntil: until, error: "circuit_open")
        } catch GitHubError.noToken {
            log.error("watch.no_token", [:])
            return PollOutcome(discovered: 0, withdrawn: 0, throttledUntil: nil, error: "no_token")
        } catch {
            log.warn("watch.poll_error", ["error": String(describing: error)])
            return PollOutcome(
                discovered: 0, withdrawn: 0, throttledUntil: nil,
                error: String(describing: error))
        }
    }
}
