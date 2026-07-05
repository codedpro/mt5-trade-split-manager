"""Unit tests for the FastAPI/TCP bridge in server.py.

Environment facts these tests are built around:
- server.py loads config.json and binds the TCP listener (port 5555) inside a
  daemon thread at IMPORT time, so we chdir to the repo root before importing it
  and import it exactly once for the whole session. We never importlib.reload it
  (that would try to re-bind the port and fail).
- API_KEY is read into a module global at import. require_key reads that global
  at call time, so the auth test patches server.API_KEY directly (monkeypatch
  restores it) rather than reloading the module.
"""

import asyncio
import json
import os
import queue
import socket
import sys
import threading
import time

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

# server.py does open('config.json') and binds the TCP port at import time, so
# be in the repo root and importable before importing it.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(_REPO_ROOT)
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

import server  # noqa: E402  (import must follow the chdir above)


# --------------------------------------------------------------------------- #
# Fixtures
# --------------------------------------------------------------------------- #
@pytest.fixture(scope="session", autouse=True)
def _tcp_ready():
    """Block until the background TCP server thread is accepting connections."""
    deadline = time.time() + 10
    last_err = None
    while time.time() < deadline:
        try:
            with socket.create_connection((server.TCP_HOST, server.TCP_PORT), timeout=1):
                return
        except OSError as exc:  # not listening yet
            last_err = exc
            time.sleep(0.05)
    raise RuntimeError(f"TCP bridge never started listening: {last_err}")


@pytest.fixture(autouse=True)
def _drain_queue():
    """Drain any leftover (possibly abandoned) command between tests so state
    from one test - e.g. the abandoned envelope left by the timeout test - can
    never leak into the next one."""
    _drain(server.command_queue)
    yield
    _drain(server.command_queue)


@pytest.fixture(scope="session")
def client():
    return TestClient(server.app)


# --------------------------------------------------------------------------- #
# Socket / helper utilities
# --------------------------------------------------------------------------- #
def _drain(q):
    while True:
        try:
            q.get_nowait()
        except queue.Empty:
            return


def _recv_json(sock, timeout=3):
    """Read from a socket until a complete JSON object arrives (mirrors how the
    bridge itself frames messages) or the peer closes / times out."""
    sock.settimeout(timeout)
    data = b""
    while True:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        data += chunk
        try:
            return json.loads(data.decode("utf-8"))
        except json.JSONDecodeError:
            continue
    try:
        return json.loads(data.decode("utf-8"))
    except Exception:
        return None


def _poll_once(timeout=3):
    """Act as the EA polling the bridge exactly once; return what it sends back."""
    with socket.create_connection((server.TCP_HOST, server.TCP_PORT), timeout=timeout) as sock:
        return _recv_json(sock, timeout=timeout)


def _fake_ea_serve(count, deadline):
    """Stand in for the EA: connect to the bridge repeatedly and, for each real
    command received, echo a response tagged with the command's own ``tag`` so a
    test can verify each caller gets back *its own* response. Empty-queue
    ("waiting") replies are skipped and retried until ``count`` commands have
    been served or the deadline passes. Returns the number actually served."""
    served = 0
    while served < count and time.time() < deadline:
        try:
            sock = socket.create_connection((server.TCP_HOST, server.TCP_PORT), timeout=1)
        except OSError:
            time.sleep(0.02)
            continue
        try:
            msg = _recv_json(sock, timeout=2)
            if not msg or msg.get("status") == "waiting" or "action" not in msg:
                continue  # empty queue - reconnect and retry
            reply = {"success": True, "tag": msg.get("tag"), "seen_action": msg.get("action")}
            sock.sendall(json.dumps(reply).encode("utf-8"))
            served += 1
        finally:
            sock.close()
        if served < count:
            time.sleep(0.01)
    return served


def _order_payload(**overrides):
    """A minimal, otherwise-valid POST /order body; override individual fields."""
    payload = {
        "order_type": "BUY_LIMIT",
        "symbol": "XAUUSD",
        "price": 2000.0,
        "sl": 1990.0,
        "tp_levels": [2010.0, 2020.0],
    }
    payload.update(overrides)
    return payload


# --------------------------------------------------------------------------- #
# 1. Envelope correlation under concurrent requests
# --------------------------------------------------------------------------- #
def test_envelope_correlation_concurrent():
    """Two concurrent callers must each receive the response to their *own*
    command, never each other's (the per-request Envelope guarantee)."""
    results = {}
    errors = {}

    def _caller(tag):
        try:
            results[tag] = server.send_command_to_mt5({"action": "PING", "tag": tag}, timeout=5)
        except Exception as exc:  # noqa: BLE001 - surfaced via the errors dict
            errors[tag] = exc

    threads = [threading.Thread(target=_caller, args=(tag,)) for tag in ("A", "B")]
    for thread in threads:
        thread.start()

    served = _fake_ea_serve(count=2, deadline=time.time() + 8)

    for thread in threads:
        thread.join(timeout=8)

    assert served == 2, f"fake EA only served {served}/2 commands"
    assert not errors, f"callers raised unexpectedly: {errors}"
    assert results["A"]["tag"] == "A"
    assert results["B"]["tag"] == "B"
    assert results["A"]["seen_action"] == "PING"


# --------------------------------------------------------------------------- #
# 2. Timeout -> 504 and the abandoned command is never delivered
# --------------------------------------------------------------------------- #
def test_timeout_abandons_command():
    # No EA is polling, so the request must time out as a 504.
    with pytest.raises(HTTPException) as excinfo:
        server.send_command_to_mt5({"action": "PING", "tag": "orphan"}, timeout=1)
    assert excinfo.value.status_code == 504

    # The abandoned command must never be handed to the EA: the next poll, which
    # pulls and skips the abandoned envelope, sees an empty queue instead.
    assert _poll_once() == {"status": "waiting"}


# --------------------------------------------------------------------------- #
# 3. Empty-queue poll -> waiting
# --------------------------------------------------------------------------- #
def test_empty_queue_poll_returns_waiting():
    assert _poll_once() == {"status": "waiting"}


# --------------------------------------------------------------------------- #
# 4. API-key auth
# --------------------------------------------------------------------------- #
def test_api_key_enforced_when_set(client, monkeypatch):
    monkeypatch.setattr(server, "API_KEY", "s3cret")

    # Missing key on a trading endpoint -> 401.
    assert client.get("/positions").status_code == 401
    # Wrong key -> 401.
    assert client.get("/positions", headers={"X-API-Key": "nope"}).status_code == 401

    # /health never requires a key, even while auth is active.
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["auth_required"] is True


# --------------------------------------------------------------------------- #
# 5a. Validation matrix (fails fast at pydantic -> 422, no EA needed)
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    "overrides",
    [
        {"tp_levels": []},                                                    # 0 levels
        {"tp_levels": [float(i) for i in range(1, 12)]},                      # 11 levels
        {"tp_levels": [2010.0, 2020.0, 2030.0], "volume_split": [0.6, 0.4]},  # length mismatch
        {"tp_levels": [2010.0, 2020.0], "volume_split": [0.3, 0.2]},          # sum 0.5, out of range
        {"tp_levels": [2010.0, 2020.0], "volume_split": [-0.1, 1.1]},         # negative entry
        {"tp_levels": [2010.0, 2020.0], "volume_split": [0.0, 0.0]},          # all-zero
    ],
    ids=[
        "zero-tp-levels",
        "eleven-tp-levels",
        "split-length-mismatch",
        "split-sum-out-of-range",
        "split-negative-entry",
        "split-all-zero",
    ],
)
def test_order_validation_rejected(client, overrides):
    resp = client.post("/order", json=_order_payload(**overrides))
    assert resp.status_code == 422, resp.text


# --------------------------------------------------------------------------- #
# 5b. Happy paths - assert the built command dict directly (not over HTTP, which
#     would block waiting on the EA). We invoke the real handler with the TCP
#     send patched out and inspect the command it built.
# --------------------------------------------------------------------------- #
def _capture_command(monkeypatch, order):
    captured = {}

    def _fake_send(command, timeout=None):
        captured["command"] = command
        return {"success": True}

    monkeypatch.setattr(server, "send_command_to_mt5", _fake_send)
    asyncio.run(server.create_order(order))
    return captured["command"]


def test_custom_split_carried_through(monkeypatch):
    order = server.OrderCommand(
        order_type="BUY_LIMIT",
        symbol="XAUUSD",
        price=2000.0,
        sl=1990.0,
        tp_levels=[2010.0, 2020.0, 2030.0],
        volume_split=[0.5, 0.3, 0.2],
    )
    # A valid custom split survives validation unchanged...
    assert order.volume_split == [0.5, 0.3, 0.2]
    # ...and reaches the EA command verbatim.
    command = _capture_command(monkeypatch, order)
    assert command["data"]["volume_split"] == [0.5, 0.3, 0.2]
    assert command["data"]["tp_levels"] == [2010.0, 2020.0, 2030.0]


def test_legacy_default_split_injected(monkeypatch):
    order = server.OrderCommand(
        order_type="BUY_LIMIT",
        symbol="XAUUSD",
        price=2000.0,
        sl=1990.0,
        tp_levels=[2010.0, 2020.0, 2030.0, 2040.0, 2050.0],
    )
    # The client omitted volume_split, so the model leaves it None...
    assert order.volume_split is None
    # ...and the default is the legacy 60/10/10/10/10 weighting for N=5.
    assert server.default_volume_split(5) == [0.6, 0.1, 0.1, 0.1, 0.1]
    # The handler injects that default into the command it sends to the EA.
    command = _capture_command(monkeypatch, order)
    assert command["data"]["volume_split"] == [0.6, 0.1, 0.1, 0.1, 0.1]
    assert sum(command["data"]["volume_split"]) == 1.0
