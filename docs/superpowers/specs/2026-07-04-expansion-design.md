# Expansion design: variable splits, any-symbol, MCP server, tests + CI

Date: 2026-07-04
Status: approved (user), pre-implementation
Scope: one release; four components. Compile + unit-test verified; live trading behavior must be demo-tested by the user.

## 1. API contract (server.py)

- `tp_levels`: list of 1–10 prices (previously exactly 5).
- `volume_split` (new, optional): list of floats, same length as `tp_levels`.
  - Each entry >= 0; at least one entry > 0; sum within [0.99, 1.01].
  - An entry of 0 means "skip this level" (no order placed for it).
  - If omitted, the server injects the default: N=1 -> `[1.0]`; N>=2 -> TP1 = 0.60,
    each remaining level = `0.40 / (N-1)`. For N=5 this reproduces the legacy
    60/10/10/10/10 exactly, so existing clients are unchanged.
- The command sent to the EA always contains an explicit `volume_split`.
- Validation failures are 422s with messages that state the rule violated.
- All other endpoints unchanged. Version bump to 4.2.0.

## 2. EA (bulk-add-signals.mq5)

Constraints: source stays pure ASCII with CRLF line endings (MetaEditor treats
no-BOM UTF-8 as ANSI on some builds). No new #includes. Fixed-capacity arrays,
not dynamic arrays inside structs.

- `#define MAX_SPLITS 10`. `SplitOrderGroup` gains `int count`; `tickets`,
  `tp_prices` widen to `[MAX_SPLITS]`.
- `TradeCommand` gains `double volume_split[MAX_SPLITS]` and `int tp_count`.
  Parser reads up to 10 entries from `tp_levels` and `volume_split`; if
  `volume_split` is absent, apply the same default formula as the server
  (defense in depth for direct TCP callers).
- EA-side validation mirrors the server: 1..10 levels, split length matches,
  each provided TP on the correct side of entry, SL side check as today.
- Volume computation (any-symbol correct):
  - `step = SYMBOL_VOLUME_STEP` (fallback 0.01 if broker reports 0),
    `minLot = SYMBOL_VOLUME_MIN`.
  - `vol_i = MathFloor(lot_size * ratio_i / step + 1e-9) * step`.
  - If `ratio_i > 0` and `vol_i < minLot`: reject the whole order; the error
    message names the level and the minimum viable `lot_size`.
  - Flooring leftover (`lot_size - sum(vol_i)`, floored to step) is added to
    the first level having the largest ratio (deterministic on ties).
- Price normalization: entry, SL, and every TP normalized to
  `SymbolInfoInteger(sym, SYMBOL_DIGITS)` before `OrderOpen`. This removes the
  last symbol-specific assumptions; XAUUSD/XAGUSD become examples, not limits.
- Order comment stays `<groupId>#<idx>` with idx now 1..10; the parser must
  read all consecutive digits after `#` (the current code reads exactly one
  character and would break at `#10`). Legacy `|GROUP:...|TP:n` parsing kept.
- Trailing semantics unchanged: when the level-2 ticket disappears, move SL of
  levels 3..count to the recorded TP1 price. Groups with count < 3, or with
  `volume_split[1] == 0`, never trigger (the existing `ticket == 0` guard
  already handles this). Safe-shutdown consolidates levels 2..count to the
  recorded TP2 price; skipped/unknown levels are ignored.
- Recovery: rebuilt groups set `count = MAX_SPLITS` and rely on `ticket == 0`
  guards; fresh groups carry the real count. tp2_reached inference: ticket[1]
  gone while any of tickets[2..MAX-1] survive.
- Chart drawing: loop `count`, 10-entry color palette, labels show the actual
  volume per level instead of hardcoded percentages.

## 3. MCP server (mcp_server.py, new file)

- FastMCP (package `mcp`), stdio transport, wraps the REST API over httpx.
- Env: `MT5_BRIDGE_URL` (default `http://127.0.0.1:8080`), `MT5_API_KEY`
  (optional; sent as `X-API-Key`), `MT5_MCP_ENABLE_TRADING` (default off).
- Always-on read-only tools: `list_positions`, `list_pending_orders`,
  `account_stats`, `bridge_health`.
- Registered only when `MT5_MCP_ENABLE_TRADING=1`: `place_split_order`
  (mirrors /order incl. volume_split), `close_position`, `cancel_order`,
  `safe_shutdown`.
- Tool docstrings written for LLM consumption; responses are the bridge's JSON
  passed through, with HTTP errors surfaced as readable messages.
- `requirements-mcp.txt`: `mcp`, `httpx`. README gains setup for Claude Code
  (`claude mcp add`) and Claude Desktop (config JSON snippet).

## 4. Tests + CI

- `tests/test_bridge.py` (pytest + fastapi TestClient + httpx):
  - Envelope correlation under two concurrent requests (fake-EA socket helper).
  - Timeout -> 504 and the abandoned command is never delivered to a later poll.
  - Empty queue poll -> `{"status":"waiting"}`.
  - API key: 401 on wrong/missing when set; open when unset.
  - Validation matrix: 0 and 11 tp_levels; volume_split length mismatch;
    sum out of range; negative entry; all-zero; valid 3-level custom split
    (command carries it); legacy 5-level request gets the default injected.
- `requirements-dev.txt`: `pytest`, `httpx`.
- `.github/workflows/ci-python.yml`: ubuntu-latest, Python 3.11, install
  requirements + dev, run pytest. Path-triggered on `server.py`,
  `mcp_server.py`, `tests/**`, `requirements*.txt`, and the workflow itself.
- Existing compile-ea.yml continues to guard the EA (with /portable).

## 5. Rollout

Feature branch -> Opus subagents implement with strict file ownership (no two
agents share a file) -> adversarial review pass -> local EA compile via Wine
MetaEditor /portable + local pytest -> push -> both workflows green -> PR ->
squash-merge (user's standing preference). README documents all new behavior
and keeps a "demo-test before live" warning.

## Out of scope (deliberate)

- Configurable trailing trigger/target levels (stays TP2 -> TP1).
- Variable TP counts above 10; per-level SL; strategy-tester support.
- Wiring the currently unused `MaxSpreadPips` input (pre-existing, unchanged).
