"""
MT5 Trade Split Manager - MCP server

Exposes the REST bridge (server.py) as Model Context Protocol tools over stdio,
so an LLM client (Claude Code, Claude Desktop) can inspect and control MT5.

Design notes:
- FastMCP (package `mcp`), stdio transport. NOTHING is printed to stdout: stdio
  carries the MCP protocol, so any stray print would corrupt the stream.
- The bridge's JSON is passed straight through on success. HTTP/connection
  failures are returned as short human-readable strings, never raw tracebacks,
  so the model gets a usable message instead of an exception.
- Read-only tools are always registered. The trading tools (place/close/cancel/
  shutdown) are registered only when MT5_MCP_ENABLE_TRADING is '1' or 'true',
  so a default install cannot move money.

Env:
- MT5_BRIDGE_URL         base URL of the REST bridge (default http://127.0.0.1:8080)
- MT5_API_KEY            optional; sent as X-API-Key on every request
- MT5_MCP_ENABLE_TRADING '1'/'true' registers the trading tools (default off)
"""

import os
from typing import List, Optional

import httpx
from mcp.server.fastmcp import FastMCP

BRIDGE_URL = os.environ.get("MT5_BRIDGE_URL", "http://127.0.0.1:8080").rstrip("/")
API_KEY = os.environ.get("MT5_API_KEY", "")
TRADING_ENABLED = os.environ.get("MT5_MCP_ENABLE_TRADING", "").lower() in ("1", "true")

# The bridge abandons a command after ~10s (REQUEST_TIMEOUT); give it headroom.
TIMEOUT = 15.0

mcp = FastMCP("MT5 Trade Split Manager")


def _headers() -> dict:
    return {"X-API-Key": API_KEY} if API_KEY else {}


def _format_http_error(resp: httpx.Response):
    """Turn a >=400 response into a readable string, preferring the bridge's
    own error detail (FastAPI puts it under "detail")."""
    try:
        body = resp.json()
    except Exception:
        return f"bridge returned HTTP {resp.status_code}: {resp.text}"
    detail = body.get("detail", body) if isinstance(body, dict) else body
    return f"bridge returned HTTP {resp.status_code}: {detail}"


def _request(method: str, path: str, json_body: Optional[dict] = None):
    """Call the REST bridge and return parsed JSON, or a readable error string.
    All httpx failures are caught here so tools never leak a traceback."""
    try:
        resp = httpx.request(
            method,
            f"{BRIDGE_URL}{path}",
            json=json_body,
            headers=_headers(),
            timeout=TIMEOUT,
        )
    except httpx.ConnectError:
        return f"bridge unreachable at {BRIDGE_URL}"
    except httpx.TimeoutException:
        return f"bridge timed out after {TIMEOUT:.0f}s at {BRIDGE_URL}"
    except httpx.HTTPError as e:
        return f"bridge request failed: {e}"

    if resp.status_code >= 400:
        return _format_http_error(resp)
    try:
        return resp.json()
    except Exception:
        return resp.text


# --- Read-only tools (always registered) -----------------------------------

@mcp.tool()
def list_positions():
    """List all open MT5 positions (the filled legs of split orders).

    Returns the bridge JSON as-is: each position carries its ticket, symbol,
    volume in lots, open price, current SL/TP, and floating profit in the
    account currency. Read-only; places nothing.
    """
    return _request("GET", "/positions")


@mcp.tool()
def list_pending_orders():
    """List all pending (not-yet-filled) MT5 orders, e.g. the stop/limit legs
    of a split order that price has not reached yet.

    Returns the bridge JSON as-is: ticket, symbol, order type, requested price,
    volume in lots, and SL/TP. Read-only; places nothing.
    """
    return _request("GET", "/orders")


@mcp.tool()
def account_stats():
    """Get MT5 account statistics: balance, equity, margin, free margin, and
    open profit, all in the account's deposit currency. Read-only.
    """
    return _request("GET", "/stats")


@mcp.tool()
def bridge_health():
    """Check that the REST bridge is up and reachable before trading.

    Returns the bridge's health JSON (status, TCP host/port it listens on for
    the EA, and whether API-key auth is required). If the bridge process is
    down this returns "bridge unreachable at <url>". Note: a healthy bridge
    does not guarantee the MT5 EA is connected - that only shows up when a
    command times out.
    """
    return _request("GET", "/health")


# --- Trading tools (registered only when MT5_MCP_ENABLE_TRADING is on) -------

if TRADING_ENABLED:

    @mcp.tool()
    def place_split_order(
        symbol: str,
        order_type: str,
        price: float,
        sl: float,
        tp_levels: List[float],
        lot_size: float = 0.1,
        volume_split: Optional[List[float]] = None,
        comment: str = "Claude AI",
    ):
        """Place one pending order that the EA splits into several positions,
        each closing at a different take-profit level.

        Arguments (prices are in the symbol's quote price, volumes in lots):
        - symbol: e.g. "XAUUSD", "EURUSD", "BTCUSD" - any broker symbol.
        - order_type: one of BUY_STOP, SELL_STOP, BUY_LIMIT, SELL_LIMIT.
          Wrong-side requests are REJECTED by the EA:
            * BUY_STOP  price must be ABOVE the current ask.
            * SELL_STOP price must be BELOW the current bid.
            * BUY_LIMIT price must be BELOW the current ask.
            * SELL_LIMIT price must be ABOVE the current bid.
        - price: the entry price for the pending order.
        - sl: stop-loss price. For BUY orders it must be below entry; for SELL
          orders above entry, or the EA rejects the order.
        - tp_levels: 1 to 10 take-profit prices. For BUY orders every TP must be
          above entry; for SELL orders below entry (wrong-side TPs are rejected).
        - lot_size: total volume in lots. It is SPLIT across the tp_levels (it is
          not per-level). By default TP1 gets 60% and the rest share 40% evenly.
        - volume_split (optional): fractions of lot_size, one per tp_level, same
          length as tp_levels. Each entry is >= 0, at least one is > 0, and they
          must sum to ~1.0 (0.99-1.01). An entry of 0 SKIPS that level (no order
          is placed for it). Omit this to use the default 60/40 split.
        - comment: label attached to the order group.

        Returns the bridge JSON (per-leg tickets on success). Requires the EA to
        be connected; if it is not, this reports a bridge timeout. ALWAYS
        demo-test on a demo account before using on a live account.
        """
        payload = {
            "order_type": order_type,
            "symbol": symbol,
            "price": price,
            "sl": sl,
            "tp_levels": tp_levels,
            "lot_size": lot_size,
            "comment": comment,
        }
        if volume_split is not None:
            payload["volume_split"] = volume_split
        return _request("POST", "/order", payload)

    @mcp.tool()
    def close_position(ticket: int):
        """Close an open MT5 position by its ticket number (one leg of a split
        order). Get ticket numbers from list_positions. This closes at market;
        it is immediate and cannot be undone.
        """
        return _request("DELETE", f"/position/{ticket}")

    @mcp.tool()
    def cancel_order(ticket: int):
        """Cancel a pending (not-yet-filled) MT5 order by its ticket number. Get
        ticket numbers from list_pending_orders. This only removes an unfilled
        order; it does not touch already-open positions.
        """
        return _request("DELETE", f"/order/{ticket}")

    @mcp.tool()
    def safe_shutdown():
        """Consolidate the remaining take-profit legs before the bridge/EA goes
        offline: the EA moves the TP of levels 2..N to the recorded TP2 price so
        open positions still have protection when no software is watching.
        Skipped or unknown levels are ignored. Does not close positions.
        """
        return _request("POST", "/safe-shutdown")


if __name__ == "__main__":
    mcp.run()
