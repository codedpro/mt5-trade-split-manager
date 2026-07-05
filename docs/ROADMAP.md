# Roadmap: known gaps and next features

Last updated: 2026-07-06 (post v4.2.0 expansion). Ordered by (risk x demand).
Each item is small enough for one focused PR.

## Known bugs / correctness gaps

1. **`MaxSpreadPips` input is dead code.** Declared in the EA inputs and
   documented in the README, but never checked anywhere. Either wire it into
   `ValidateCommand` (reject when `(ask-bid)` exceeds the limit, converting
   pips per symbol digits) or remove the input and the README row.
2. **`MaxPositions` counts positions, not pending orders.** A burst of split
   groups can queue 10 groups x 10 pending orders while `CountOpenPositions()`
   returns 0. Count pending orders with the EA's magic number toward the cap
   (or add a separate `MaxPendingOrders`).
3. **Recovered groups don't restore `count`** (set to `MAX_SPLITS` with
   guards). Harmless today, but `UpdateTPLevelClosed` gray-marks slots that
   never existed and the all-alive scan does extra `OrderSelect` calls.
   Persisting group state (item 6) fixes this properly.
4. **`partial_close_percent` rides through the whole stack unused.** It's in
   the API model, forwarded to the EA, and ignored there. Remove it or
   implement partial closes.
5. **Daily-loss day boundary uses server time, not broker midnight.**
   `TimeCurrent() % 86400` resets at UTC-day of the server clock; brokers with
   offset timezones reset mid-session. Consider `iTime(_Symbol, PERIOD_D1, 0)`
   as the boundary.
6. **Group state lives only in RAM + order comments.** If a broker rewrites
   comments (some do on partial fills), recovery loses the group. Persist
   `orderGroups` to a file (e.g. `MQL5/Files/split_groups.json`) on change and
   prefer it during recovery, falling back to comments.

## Incomplete / promised features

7. **Trailing trigger/target are hardcoded (TP2 -> TP1).** Natural follow-up
   to variable splits: optional `trailing` object in the API
   (`{"trigger_level": 2, "sl_to_level": 1}` semantics, breakeven option).
   Deliberately out of scope in the v4.2.0 spec.
8. **Safe-shutdown consolidation level is fixed at TP2.** Same
   generalization as (7).
9. **Modify-order endpoint.** The API can place, list, close, delete - but
   not modify SL/TP of an existing group. AI-agent workflows want
   `PATCH /group/{groupId}` (move SL, shift remaining TPs).
10. **Group-level API.** `GET /groups` (tracked split groups with per-level
    status) and `DELETE /group/{groupId}` (cancel/close a whole group). Today
    callers must correlate tickets themselves from `/positions` + `/orders`.
11. **Telegram/webhook notifications** (README roadmap promise): order
    placed/filled, TP hit, trailing applied, safe-shutdown done.
12. **Trade journal** (README roadmap promise): append fills/closures to CSV
    or SQLite via the EA's `OnTradeTransaction`, expose `GET /journal`.
13. **Web dashboard** (README roadmap promise): small single-page UI over the
    existing REST API - positions, groups, safe-shutdown button.
14. **MCP: group-aware tools.** Once (10) exists, add `list_groups` /
    `close_group` tools; also a `dry_run` flag on `place_split_order` that
    returns the computed per-level volumes without placing.

## Infrastructure / quality

15. **EA integration harness.** The socket protocol is testable without a
    broker: a pytest fixture can speak the EA's TCP protocol (fake EA), and a
    stub bridge can drive the EA in the Strategy Tester via a compile-time
    `#ifdef` transport shim. Would finally cover the EA's JSON parser.
16. **Release automation.** Tag-triggered workflow attaching the compiled
    `.ex5` (already built by compile-ea.yml) to a GitHub Release.
17. **CONTRIBUTING.md + issue templates** - the repo is viral; convert stars
    into safe PRs (note the ASCII/CRLF rule for the .mq5, CI expectations).
18. **Rotate the exposed PAT** (owner action; noted 2026-07-04).
19. **Modernize pinned Python deps.** requirements.txt pins fastapi 0.109 /
    pydantic 2.5.3 / uvicorn 0.27 (early-2024). Newer fastapi drops the
    TestClient `app=` kwarg problem (tests currently pin httpx<0.28 to stay
    compatible) and picks up security fixes. One PR: bump pins, rerun CI.
