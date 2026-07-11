import Foundation

/// The guidance comment posted to a PR when a review run is killed at its
/// wall-clock timeout. Without it the PR is left silent — the author sees a
/// pending request that never resolves and has no idea what to do next.
///
/// Pure string-building so the wording is unit-testable; the posting side
/// effect lives in `Coordinator`.
public enum TimeoutNotice {
    /// Marker so tooling (and re-runs) can recognize the comment.
    public static let marker = "<!-- cr-daemon:timeout-guidance -->"

    /// - Parameters:
    ///   - minutes: the budget the run was killed at, in whole minutes.
    ///   - usedLargeTier: whether this run was already tier-routed (so the
    ///     "add the label" suggestion would be useless).
    ///   - largeLabel: the configured tier label to suggest (nil = no tier
    ///     routing configured, skip that suggestion).
    public static func body(minutes: Int, usedLargeTier: Bool, largeLabel: String?) -> String {
        var lines = [
            marker,
            "⏱️ **Automated review timed out** after \(minutes) minute\(minutes == 1 ? "" : "s"), so no review was posted.",
            "",
            "Ways to get this PR reviewed:",
        ]
        if !usedLargeTier, let label = largeLabel {
            lines.append(
                "- Add the `\(label)` label and re-request the review — it routes to a larger model tier with a longer time budget.")
        }
        lines.append(
            "- Split this PR into smaller, focused PRs — large diffs are the usual cause of review timeouts\(usedLargeTier ? ", even on the large tier" : "").")
        lines.append(
            "- Re-request the review to retry as-is (occasionally a run is just unlucky).")
        return lines.joined(separator: "\n")
    }
}
