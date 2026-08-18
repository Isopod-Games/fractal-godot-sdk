# Issue #336 test plan: analytics batches vanish silently on permanent rejection

## Bug

Investigation on #336 (missing Linux playtester data) exhausted both forensic
avenues (ClickHouse, confirmed no Linux events ever arrived; collector logs
wiped by container restarts; Prometheus, was down for the whole retention
window, now fixed by #338/#339). The pipeline itself was exonerated: platform
detection and the collector are both correct.

That leaves the SDK's own failure handling as the last open gap. Comparing
`analytics.gd::_on_request_failed` against the equivalent, already-hardened
path in `errors.gd::_on_request_failed` (added for #337) shows an
inconsistency:

- `errors.gd`: a permanent 4xx (bad/blocked API key, malformed payload, etc.)
  moves the rejected batch to a **dead-letter queue on disk**
  (`errors_dead_letter.json`) and calls `push_error`, loud, and recoverable
  out-of-band from the player's `user://fractal/` folder.
- `analytics.gd`: the same class of failure just drops the batch
  (`_queue.clear_sent_events`) with only a `push_warning`, invisible in a
  release export with no attached console, and nothing is left on disk. Once
  dropped, there is no way to ever learn why a player's analytics stopped
  reporting.

This matches the #336 symptom exactly: a build with a bad/misconfigured API
key would send batches that are rejected and silently vanish, with zero trace
anywhere, on the server (nothing was ever accepted) or on the client
(nothing persisted). It cannot retroactively explain the specific missing
Linux session (that forensic window is gone), but it is a real, reproducible
gap that would make any future occurrence of this exact failure mode equally
undiagnosable.

## Repro steps

1. Configure `FractalAnalytics` against a mock server.
2. Queue a batch and have the mock server return `400` (or any permanent 4xx
   other than 429, unlike the errors/minidump/symbols subsystems, analytics
   has no plan-gated feature and the collector never sends analytics a 402,
   so there's nothing to exclude there).
3. Call `analytics._on_request_failed("HTTP 400: ...", 400)` directly (unit
   level, mirrors `tests/unit/test_errors_dead_letter.gd`).
4. **Expected:** the rejected batch is written to a dead-letter file on disk
   and the retry queue is cleared.
5. **Actual (pre-fix):** the retry queue is cleared, but the batch is
   discarded, no dead-letter file exists, nothing persists.

## Verification

- New test: `tests/unit/test_analytics_dead_letter.gd`
  - `test_400_moves_persisted_batch_to_dead_letter_and_clears_retry_queue`
  - `test_500_retains_persisted_batch_for_retry` (regression guard, 5xx must
    keep the existing retry-next-session behavior, unchanged)
- Run via the project's gdUnit4 harness (`ci/` runner /
  `config/ci.rb`).
