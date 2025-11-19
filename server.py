"""
MT5 TCP Server - Python listens on socket, MQL5 connects as client
Claude AI → FastAPI → Queue → TCP Server → MQL5 EA
"""

import json
import socket
import threading
import queue
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import List
import uvicorn

# Load config
with open('config.json', 'r') as f:
    config = json.load(f)

# Queue for commands
command_queue = queue.Queue()
response_queue = queue.Queue()

# TCP Server settings
TCP_HOST = '127.0.0.1'
TCP_PORT = config['mt5']['zmq_port']

print(f"✅ Config loaded - TCP Server will listen on {TCP_HOST}:{TCP_PORT}")

# FastAPI app
app = FastAPI(title="MT5 TCP Bridge", version="4.0.0")


class OrderCommand(BaseModel):
    action: str = "PLACE_ORDER"
    order_type: str
    symbol: str
    price: float
    sl: float
    tp_levels: List[float]
    lot_size: float = 0.1
    deviation: int = 3
    comment: str = "Claude AI"
    magic_number: int = 20250117
    partial_close_percent: float = 20.0


def tcp_server():
    """
    TCP Server thread - listens for MQL5 connections
    """
    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind((TCP_HOST, TCP_PORT))
    server_socket.listen(5)

    print(f"🚀 TCP Server listening on {TCP_HOST}:{TCP_PORT}")

    while True:
        try:
            # Accept connection from MQL5
            client_socket, address = server_socket.accept()
            print(f"📡 MQL5 connected from {address}")

            # Check if there's a command waiting
            if not command_queue.empty():
                command = command_queue.get()

                # Send command to MQL5
                command_json = json.dumps(command)
                client_socket.sendall(command_json.encode('utf-8'))
                print(f"📤 Sent to MQL5: {command_json[:100]}...")

                # Receive response from MQL5
                response_data = b''
                while True:
                    chunk = client_socket.recv(4096)
                    if not chunk:
                        break
                    response_data += chunk
                    # Check if we received complete JSON
                    try:
                        response = json.loads(response_data.decode('utf-8'))
                        break
                    except:
                        continue

                print(f"📥 Received from MQL5: {response}")
                response_queue.put(response)
            else:
                # No command, send empty response
                client_socket.sendall(b'{"status":"waiting"}')

            client_socket.close()

        except Exception as e:
            print(f"❌ TCP Server error: {e}")


# Start TCP server in background thread
tcp_thread = threading.Thread(target=tcp_server, daemon=True)
tcp_thread.start()


@app.get("/")
async def root():
    return {"status": "online", "service": "MT5 TCP Bridge"}


@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "tcp_host": TCP_HOST,
        "tcp_port": TCP_PORT
    }


def send_command_to_mt5(command: dict, timeout: int = 10):
    """
    Helper function to send command to MT5 and wait for response
    """
    import time

    # Add command to queue
    command_queue.put(command)

    # Wait for response
    start = time.time()
    while time.time() - start < timeout:
        if not response_queue.empty():
            response = response_queue.get()
            return response
        time.sleep(0.1)

    raise HTTPException(status_code=504, detail="MT5 timeout - EA not connecting")


@app.post("/order")
async def create_order(order: OrderCommand):
    """
    Place order on MT5 via TCP
    """
    command = {
        "action": "PLACE_ORDER",
        "data": {
            "order_type": order.order_type,
            "symbol": order.symbol,
            "price": order.price,
            "sl": order.sl,
            "tp_levels": order.tp_levels,
            "lot_size": order.lot_size,
            "deviation": order.deviation,
            "comment": order.comment,
            "magic_number": order.magic_number,
            "partial_close_percent": order.partial_close_percent
        }
    }

    try:
        response = send_command_to_mt5(command)
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/positions")
async def get_positions():
    """
    Get all open positions from MT5
    """
    command = {"action": "GET_POSITIONS"}

    try:
        response = send_command_to_mt5(command)
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/orders")
async def get_orders():
    """
    Get all pending orders from MT5
    """
    command = {"action": "GET_ORDERS"}

    try:
        response = send_command_to_mt5(command)
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/order/{ticket}")
async def delete_order(ticket: int):
    """
    Delete/cancel a pending order by ticket number
    """
    command = {
        "action": "DELETE_ORDER",
        "data": {"ticket": ticket}
    }

    try:
        response = send_command_to_mt5(command)
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/position/{ticket}")
async def close_position(ticket: int):
    """
    Close an open position by ticket number
    """
    command = {
        "action": "CLOSE_POSITION",
        "data": {"ticket": ticket}
    }

    try:
        response = send_command_to_mt5(command)
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/stats")
async def get_stats():
    """
    Get account statistics and EA status
    """
    command = {"action": "GET_STATS"}

    try:
        response = send_command_to_mt5(command)
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/safe-shutdown")
async def safe_shutdown():
    """
    Safe shutdown mode - consolidates all TPs (TP2-TP5) to TP2 level (45 pips)
    Protects positions when you need to close MT5 and go to sleep/away
    """
    command = {"action": "SAFE_SHUTDOWN"}

    try:
        response = send_command_to_mt5(command)
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    print("🚀 Starting MT5 TCP Bridge Server...")
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8080,
        reload=False,
        log_level="info"
    )
