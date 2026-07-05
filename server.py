"""
MT5 TCP Server - Python listens on socket, MQL5 connects as client
Client -> FastAPI -> per-request envelope -> TCP Server -> MQL5 EA

Safety notes:
- Every API request gets its own response Event, so concurrent requests can
  never receive each other's response (the old shared-queue design could).
- A request that times out is marked "abandoned" so its command is NOT sent
  to the EA later - important for a trading system (no surprise late orders).
- Optional API-key auth (set API_KEY) and localhost-only binding by default.
"""

import json
import os
import socket
import threading
import queue
import time

from fastapi import FastAPI, HTTPException, Header, Depends
from pydantic import BaseModel, field_validator, model_validator
from typing import List, Optional
import uvicorn

# Load config
with open('config.json', 'r') as f:
    config = json.load(f)

# TCP server (MQL5 connects here)
TCP_HOST = '127.0.0.1'
TCP_PORT = config['mt5']['zmq_port']

# HTTP server. Default to localhost so trades can't be placed by anyone on the
# network. Override with HOST=0.0.0.0 (e.g. in Docker) only behind auth.
HTTP_HOST = os.environ.get('HOST', '127.0.0.1')
HTTP_PORT = int(os.environ.get('PORT', '8080'))

# Optional shared secret. If set, every trading endpoint requires the matching
# X-API-Key header. Strongly recommended whenever HOST is not localhost.
API_KEY = os.environ.get('API_KEY', '')

REQUEST_TIMEOUT = int(os.environ.get('REQUEST_TIMEOUT', '10'))

print(f"✅ Config loaded - TCP Server will listen on {TCP_HOST}:{TCP_PORT}")
if not API_KEY and HTTP_HOST != '127.0.0.1':
    print("⚠️  WARNING: HOST is not localhost and API_KEY is unset - the trading API is UNAUTHENTICATED.")

app = FastAPI(title="MT5 TCP Bridge", version="4.2.0")


class OrderCommand(BaseModel):
    action: str = "PLACE_ORDER"
    order_type: str
    symbol: str
    price: float
    sl: float
    tp_levels: List[float]
    volume_split: Optional[List[float]] = None
    lot_size: float = 0.1
    deviation: int = 3
    comment: str = "Claude AI"
    magic_number: int = 20250117
    partial_close_percent: float = 20.0

    @field_validator("tp_levels")
    @classmethod
    def _validate_tp_levels(cls, v: List[float]) -> List[float]:
        if not 1 <= len(v) <= 10:
            raise ValueError(f"tp_levels must contain 1 to 10 prices (got {len(v)})")
        return v

    @model_validator(mode="after")
    def _validate_volume_split(self) -> "OrderCommand":
        # An omitted split is filled in with the default at send time.
        if self.volume_split is None:
            return self
        split = self.volume_split
        if len(split) != len(self.tp_levels):
            raise ValueError(
                f"volume_split length ({len(split)}) must match tp_levels "
                f"length ({len(self.tp_levels)})"
            )
        if any(x < 0 for x in split):
            raise ValueError("volume_split entries must all be >= 0")
        if not any(x > 0 for x in split):
            raise ValueError("volume_split must have at least one entry > 0")
        total = sum(split)
        if not 0.99 <= total <= 1.01:
            raise ValueError(
                f"volume_split must sum to ~1.0 within [0.99, 1.01] (got {total:.4f})"
            )
        return self


def default_volume_split(n: int) -> List[float]:
    """Legacy-compatible default split for N levels: N=1 -> [1.0]; otherwise
    TP1 = 0.60 and each remaining level = 0.40 / (N-1). For N=5 this is the
    original 60/10/10/10/10 weighting, so existing clients are unchanged."""
    if n == 1:
        return [1.0]
    return [0.60] + [0.40 / (n - 1)] * (n - 1)


class Envelope:
    """One in-flight command plus the machinery to deliver its response back to
    exactly the request that issued it."""
    __slots__ = ("cmd", "event", "result", "abandoned")

    def __init__(self, cmd: dict):
        self.cmd = cmd
        self.event = threading.Event()
        self.result = None
        self.abandoned = False


# Queue of Envelopes waiting to be handed to the EA on its next poll.
command_queue: "queue.Queue[Envelope]" = queue.Queue()


def _read_json_response(sock: socket.socket) -> dict:
    """Read from the EA until a complete JSON object has arrived."""
    sock.settimeout(REQUEST_TIMEOUT)
    data = b''
    while True:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        data += chunk
        try:
            return json.loads(data.decode('utf-8'))
        except json.JSONDecodeError:
            continue
    try:
        return json.loads(data.decode('utf-8'))
    except Exception:
        return {"success": False, "message": "Invalid or empty response from EA"}


def tcp_server():
    """TCP Server thread - the MQL5 EA connects here on each poll."""
    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind((TCP_HOST, TCP_PORT))
    server_socket.listen(5)

    print(f"🚀 TCP Server listening on {TCP_HOST}:{TCP_PORT}")

    while True:
        client_socket = None
        env = None
        try:
            client_socket, address = server_socket.accept()

            # Pull the next live (non-abandoned) command, if any.
            env = None
            while not command_queue.empty():
                candidate = command_queue.get()
                if candidate.abandoned:
                    continue
                env = candidate
                break

            if env is None or env.abandoned:
                client_socket.sendall(b'{"status":"waiting"}')
                client_socket.close()
                continue

            print(f"📡 MQL5 connected from {address}")
            command_json = json.dumps(env.cmd)
            client_socket.sendall(command_json.encode('utf-8'))
            print(f"📤 Sent to MQL5: {command_json[:100]}...")

            response = _read_json_response(client_socket)
            print(f"📥 Received from MQL5: {response}")

            # Deliver the response to the exact request that is waiting on it.
            env.result = response
            env.event.set()

        except Exception as e:
            print(f"❌ TCP Server error: {e}")
            if env is not None and not env.event.is_set():
                env.result = {"success": False, "message": f"bridge error: {e}"}
                env.event.set()
        finally:
            if client_socket is not None:
                try:
                    client_socket.close()
                except Exception:
                    pass


# Start TCP server in background thread
tcp_thread = threading.Thread(target=tcp_server, daemon=True)
tcp_thread.start()


def require_key(x_api_key: Optional[str] = Header(default=None)):
    """Enforce the API key on trading endpoints when one is configured."""
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


def send_command_to_mt5(command: dict, timeout: int = REQUEST_TIMEOUT) -> dict:
    """Queue a command and wait for its own response. On timeout the command is
    abandoned so it will not be executed by the EA on a later poll."""
    env = Envelope(command)
    command_queue.put(env)

    if env.event.wait(timeout):
        return env.result

    # Timed out: prevent this command from firing late.
    env.abandoned = True
    raise HTTPException(status_code=504, detail="MT5 timeout - EA not connecting")


@app.get("/")
async def root():
    return {"status": "online", "service": "MT5 TCP Bridge"}


@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "tcp_host": TCP_HOST,
        "tcp_port": TCP_PORT,
        "auth_required": bool(API_KEY),
    }


@app.post("/order", dependencies=[Depends(require_key)])
async def create_order(order: OrderCommand):
    """Place order on MT5 via TCP (split into 1-10 positions by the EA)."""
    # The command sent to the EA always carries an explicit volume_split; when
    # the client omits it we inject the legacy-compatible default here.
    volume_split = order.volume_split
    if volume_split is None:
        volume_split = default_volume_split(len(order.tp_levels))
    command = {
        "action": "PLACE_ORDER",
        "data": {
            "order_type": order.order_type,
            "symbol": order.symbol,
            "price": order.price,
            "sl": order.sl,
            "tp_levels": order.tp_levels,
            "volume_split": volume_split,
            "lot_size": order.lot_size,
            "deviation": order.deviation,
            "comment": order.comment,
            "magic_number": order.magic_number,
            "partial_close_percent": order.partial_close_percent,
        },
    }
    return send_command_to_mt5(command)


@app.get("/positions", dependencies=[Depends(require_key)])
async def get_positions():
    return send_command_to_mt5({"action": "GET_POSITIONS"})


@app.get("/orders", dependencies=[Depends(require_key)])
async def get_orders():
    return send_command_to_mt5({"action": "GET_ORDERS"})


@app.delete("/order/{ticket}", dependencies=[Depends(require_key)])
async def delete_order(ticket: int):
    return send_command_to_mt5({"action": "DELETE_ORDER", "data": {"ticket": ticket}})


@app.delete("/position/{ticket}", dependencies=[Depends(require_key)])
async def close_position(ticket: int):
    return send_command_to_mt5({"action": "CLOSE_POSITION", "data": {"ticket": ticket}})


@app.get("/stats", dependencies=[Depends(require_key)])
async def get_stats():
    return send_command_to_mt5({"action": "GET_STATS"})


@app.post("/safe-shutdown", dependencies=[Depends(require_key)])
async def safe_shutdown():
    """Consolidate remaining TPs (TP2-TP5) to the TP2 level before going away."""
    return send_command_to_mt5({"action": "SAFE_SHUTDOWN"})


if __name__ == "__main__":
    print("🚀 Starting MT5 TCP Bridge Server...")
    print(f"   HTTP API: http://{HTTP_HOST}:{HTTP_PORT}  (auth: {'on' if API_KEY else 'off'})")
    uvicorn.run(app, host=HTTP_HOST, port=HTTP_PORT, reload=False, log_level="info")
