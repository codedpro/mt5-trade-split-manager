# MT5 Trade Split Manager 🤖

[![MetaTrader 5](https://img.shields.io/badge/MetaTrader-5-blue.svg)](https://www.metatrader5.com/)
[![Python 3.8+](https://img.shields.io/badge/python-3.8+-blue.svg)](https://www.python.org/downloads/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.109.0-green.svg)](https://fastapi.tiangolo.com/)
[![AI Agent Friendly](https://img.shields.io/badge/AI%20Agent-Friendly-brightgreen.svg)](https://claude.ai)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**🤖 AI-Agent Friendly** | **Professional-grade MetaTrader 5 Expert Advisor with intelligent order splitting, automatic trailing stop loss, and REST API integration for Gold (XAUUSD) and Silver (XAGUSD) trading. Built for seamless integration with Claude AI and other AI agents.**

## 🤖 Why AI-Agent Friendly?

This system is designed for seamless integration with AI agents like **Claude AI**, **ChatGPT**, and other LLMs:

- 🔌 **REST API First** - Simple JSON endpoints that AI agents can easily call
- 📝 **Natural Language Processing** - AI agents can parse trading signals and convert to API calls
- 🔄 **Stateless Design** - Each API call is independent, perfect for AI workflows
- 📊 **Structured Responses** - JSON responses that AI can parse and act upon
- 🛡️ **Safe Defaults** - Smart order type detection prevents common AI mistakes
- 📚 **Well-Documented** - Complete API docs for AI agent training/prompts

**Example AI Agent Workflow:**
```
User: "Buy Gold at 4100 with 30-pip TPs"
AI Agent: Parses signal → Calls REST API → Monitors response
System: Splits order → Manages positions → Returns status
```

## 🚀 Key Features

- ✅ **Automatic Order Splitting** - Splits single order into 5 positions with optimized volume distribution (60%, 10%, 10%, 10%, 10%)
- ✅ **Smart Trailing Stop Loss** - Automatically moves SL to breakeven when TP2 is reached
- ✅ **Dual TP Structures** - Supports both 15-pip and 30-pip initial TP configurations
- ✅ **Safe Shutdown Mode** - Protects positions when EA is offline
- ✅ **REST API Integration** - FastAPI server for external signal processing
- ✅ **TCP Socket Communication** - High-performance bidirectional communication
- ✅ **Smart Order Type Detection** - Automatically converts STOP/LIMIT based on market price
- ✅ **Position Recovery** - Rebuilds tracking from existing orders on restart
- ✅ **Multi-Symbol Support** - Optimized for Gold (XAUUSD) and Silver (XAGUSD)
- ✅ **Risk Management** - Daily loss limits, max positions, spread checks
- ✅ **AI Agent Ready** - Perfect for Claude AI, ChatGPT, and automation workflows

## 📋 Table of Contents

- [Quick Start](#-quick-start)
- [Architecture](#-architecture)
- [Split Order System](#-split-order-system)
- [Trailing Stop Logic](#-trailing-stop-logic)
- [Safe Shutdown Mode](#-safe-shutdown-mode)
- [API Documentation](#-api-documentation)
- [Configuration](#-configuration)
- [Installation](#-installation)
- [Usage Examples](#-usage-examples)
- [Troubleshooting](#-troubleshooting)
- [FAQ](#-faq)
- [License](#-license)

## 🎯 Quick Start

### Prerequisites

- MetaTrader 5 terminal
- Python 3.8 or higher
- Basic understanding of Forex/CFD trading

### 1. Install Python Dependencies

```bash
pip install -r requirements.txt
```

### 2. Start the Server

```bash
python server.py
```

The server will start on:
- **REST API**: http://localhost:8080
- **TCP Server**: 127.0.0.1:5555

### 3. Load EA in MT5

1. Open MetaEditor (F4 in MT5)
2. Compile `bulk-add-signals.mq5` (F7)
3. Drag EA onto any chart
4. Enable "Allow DLL imports" in EA settings
5. Check Experts tab for connection confirmation

### 4. Place Your First Order

```bash
curl -X POST http://localhost:8080/order \
  -H "Content-Type: application/json" \
  -d '{
    "symbol": "XAUUSD",
    "order_type": "BUY_STOP",
    "price": 4100.0,
    "sl": 4096.0,
    "tp_levels": [4103.0, 4106.0, 4109.0, 4112.0, 4115.0],
    "lot_size": 0.1
  }'
```

## 🏗️ Architecture

```
┌─────────────┐      REST API       ┌──────────────┐      TCP Socket      ┌─────────────┐
│   External  │ ─────────────────> │    Python    │ ──────────────────> │   MT5 EA    │
│   Client    │   POST /order      │ FastAPI +    │   JSON Commands     │  (Client)   │
│  (Claude AI)│                     │  TCP Server  │                     │             │
└─────────────┘ <───────────────── └──────────────┘ <────────────────── └─────────────┘
                   JSON Response         :5555              Response           Execute
                   (ticket #)            Queue                                  Trade
```

### Communication Flow

1. **External client** sends REST API request to FastAPI (port 8080)
2. **Python server** queues command and waits for MT5 connection
3. **MT5 EA** connects via TCP socket every 500ms (configurable)
4. **Server** sends queued command as JSON
5. **EA** parses, validates, and executes trade
6. **EA** sends response back through socket
7. **Server** returns response to original API caller

## 💡 Split Order System

### Why Split Orders?

Traditional single-TP orders force you to choose between:
- Taking profit early (leaving money on the table)
- Holding for larger profit (risking reversal)

**Solution**: Split one order into 5 positions with different TPs!

### Volume Distribution

When you place 0.1 lot, the EA creates 5 separate orders:

| Order | Volume | % of Total | Take Profit | Purpose |
|-------|--------|------------|-------------|---------|
| TP1   | 0.06   | 60%        | 15 pips     | Secure majority profit quickly |
| TP2   | 0.01   | 10%        | 45 pips     | Trailing SL trigger point |
| TP3   | 0.01   | 10%        | 75 pips     | Medium-term profit |
| TP4   | 0.01   | 10%        | 105 pips    | Extended profit |
| TP5   | 0.01   | 10%        | 135 pips    | Maximum profit target |

### TP Structure Options

**Option 1: Standard Structure (15-pip initial)**
- TP1: 15 pips
- TP2: 45 pips (+30)
- TP3: 75 pips (+30)
- TP4: 105 pips (+30)
- TP5: 135 pips (+30)

**Option 2: Aggressive Structure (30-pip initial)**
- TP1: 30 pips
- TP2: 60 pips (+30)
- TP3: 90 pips (+30)
- TP4: 120 pips (+30)
- TP5: 150 pips (+30)

### Pip Value Calibration

The EA automatically adjusts pip values based on symbol:
- **Gold (XAUUSD)**: 1 pip = 0.10 (e.g., 2650.00 → 2651.00)
- **Silver (XAGUSD)**: 1 pip = 0.01 (e.g., 29.50 → 29.51)

## 🎢 Trailing Stop Logic

### Automatic Breakeven Protection

**When TP2 closes (45 pips profit):**
1. EA detects TP2 position is closed
2. Automatically moves SL to TP1 price (15 pips from entry)
3. Remaining 30% of position (TP3, TP4, TP5) is now **risk-free**
4. Even if market reverses, you keep 15 pips profit on remaining positions

### Example Scenario

**Entry**: Sell Stop @ 50.051 (Silver)
**Initial SL**: 50.101 (5 pips above entry)

**Trade Progression:**

```
Price drops to 49.901 → TP1 closes (0.06 lots, 60% profit = +15 pips)
Price drops to 49.601 → TP2 closes (0.01 lots, 10% profit = +45 pips)
                      → EA MOVES SL to 49.901 for TP3/TP4/TP5
                      → Position now RISK-FREE!

Price drops to 49.301 → TP3 closes (0.01 lots, protected, +75 pips)
Price drops to 49.001 → TP4 closes (0.01 lots, protected, +105 pips)
Price drops to 48.701 → TP5 closes (0.01 lots, protected, +135 pips)
```

**If price reverses after TP2:**
- Worst case: Remaining 30% closes at TP1 (49.901) = +15 pips
- You still profit on 60% at TP1 + 10% at TP2 + 30% at TP1
- **Total locked profit**: Better than breaking even!

## 🛡️ Safe Shutdown Mode

### The Problem

When you close MT5 and the EA stops running:
- If TP2 gets hit while you're away, trailing SL won't activate
- TP3, TP4, TP5 remain at the original SL → **risky!**
- Market reversal could hit your SL instead of protecting profit

### The Solution

Before closing MT5, activate safe shutdown mode:

```bash
curl -X POST http://localhost:8080/safe-shutdown
```

### What It Does

1. Scans all order groups that haven't reached TP2 yet
2. Modifies **TP2, TP3, TP4, TP5** → all moved to TP2 price level
3. Keeps **TP1** unchanged (your quick profit)
4. Works on both **pending orders** and **open positions**

### Before vs After

**Before Safe Shutdown:**
```
TP1: 15 pips (0.06 lots, 60%)
TP2: 45 pips (0.01 lots, 10%)
TP3: 75 pips (0.01 lots, 10%)
TP4: 105 pips (0.01 lots, 10%)
TP5: 135 pips (0.01 lots, 10%)
```

**After Safe Shutdown:**
```
TP1: 15 pips (0.06 lots, 60%) ← unchanged
TP2: 45 pips (0.01 lots, 10%)
TP3: 45 pips (0.01 lots, 10%) ← moved to TP2!
TP4: 45 pips (0.01 lots, 10%) ← moved to TP2!
TP5: 45 pips (0.01 lots, 10%) ← moved to TP2!
```

### Benefits

✅ All remaining positions (40%) will close at maximum 45 pips
✅ No manual monitoring needed while away
✅ Safe to close MT5 and sleep/leave
✅ Guarantees minimum profit even if EA is offline

### Response Format

```json
{
  "success": true,
  "message": "Safe shutdown applied",
  "groups_modified": 3,
  "pending_orders_modified": 12,
  "open_positions_modified": 8,
  "details": [
    {"group": "XAUUSD_4065.000_1234567890", "modified": 4},
    {"group": "XAUUSD_4053.000_1234567891", "modified": 4},
    {"group": "XAUUSD_4012.000_1234567892", "modified": 4}
  ]
}
```

## 📚 API Documentation

### Base URL

```
http://localhost:8080
```

### Endpoints

#### 1. Health Check

**GET** `/health`

Check if server is running.

**Response:**
```json
{
  "status": "healthy",
  "tcp_host": "127.0.0.1",
  "tcp_port": 5555
}
```

#### 2. Place Order

**POST** `/order`

Place a new order with automatic splitting.

**Request Body:**
```json
{
  "symbol": "XAUUSD",
  "order_type": "BUY_STOP",
  "price": 4100.0,
  "sl": 4096.0,
  "tp_levels": [4103.0, 4106.0, 4109.0, 4112.0, 4115.0],
  "lot_size": 0.1,
  "deviation": 3,
  "comment": "My Trade",
  "magic_number": 20250117
}
```

**Parameters:**
- `symbol` (string): Trading symbol ("XAUUSD" or "XAGUSD")
- `order_type` (string): "BUY_STOP" or "SELL_STOP"
- `price` (float): Entry price
- `sl` (float): Stop loss price
- `tp_levels` (array): 5 take profit levels
- `lot_size` (float): Total volume (will be split into 5 orders)
- `deviation` (int, optional): Maximum price deviation in pips
- `comment` (string, optional): Order comment
- `magic_number` (int, optional): Magic number for identification

**Response:**
```json
{
  "success": true,
  "message": "Order placed successfully",
  "ticket": 171645717
}
```

#### 3. Get Positions

**GET** `/positions`

Get all open positions.

**Response:**
```json
{
  "success": true,
  "positions": [
    {
      "ticket": 123456,
      "symbol": "XAUUSD",
      "type": "BUY",
      "volume": 0.06,
      "price_open": 4100.0,
      "sl": 4096.0,
      "tp": 4103.0,
      "profit": 18.50
    }
  ]
}
```

#### 4. Get Pending Orders

**GET** `/orders`

Get all pending orders.

**Response:**
```json
{
  "success": true,
  "orders": [
    {
      "ticket": 171645717,
      "symbol": "XAUUSD",
      "type": "BUY_STOP",
      "volume": 0.06,
      "price": 4100.0,
      "sl": 4096.0,
      "tp": 4103.0
    }
  ]
}
```

#### 5. Delete Order

**DELETE** `/order/{ticket}`

Cancel a pending order.

**Response:**
```json
{
  "success": true,
  "message": "Order deleted",
  "ticket": 171645717
}
```

#### 6. Close Position

**DELETE** `/position/{ticket}`

Close an open position.

**Response:**
```json
{
  "success": true,
  "message": "Position closed",
  "ticket": 123456
}
```

#### 7. Get Statistics

**GET** `/stats`

Get account statistics and EA status.

**Response:**
```json
{
  "success": true,
  "stats": {
    "balance": 10000.00,
    "equity": 10050.00,
    "margin": 500.00,
    "free_margin": 9550.00,
    "profit": 50.00,
    "total_positions": 5,
    "total_orders": 15,
    "tracked_groups": 3,
    "magic_number": 20250117
  }
}
```

#### 8. Safe Shutdown

**POST** `/safe-shutdown`

Activate safe shutdown mode - consolidate all TPs to TP2 level.

**Response:**
```json
{
  "success": true,
  "message": "Safe shutdown applied",
  "groups_modified": 3,
  "pending_orders_modified": 12,
  "open_positions_modified": 8
}
```

## ⚙️ Configuration

### config.json

```json
{
  "mt5": {
    "zmq_port": 5555,
    "default_lot_size": 0.1
  },
  "symbols": {
    "gold": "XAUUSD",
    "silver": "XAGUSD"
  },
  "risk_management": {
    "max_daily_loss_percent": 5.0,
    "max_positions": 10
  }
}
```

### EA Input Parameters

Configure in MT5 when attaching EA to chart:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ServerHost` | "127.0.0.1" | Python server IP address |
| `ServerPort` | 5555 | TCP server port |
| `MagicNumber` | 20250117 | Unique identifier for EA orders |
| `SocketCheckIntervalMs` | 500 | How often to check for commands (ms) |
| `MaxSpreadPips` | 10 | Maximum allowed spread in pips |
| `MaxDailyLossPercent` | 5.0 | Stop trading if daily loss exceeds % |

## 📦 Installation

### Option 1: Manual Installation

1. **Clone the repository:**
```bash
git clone https://github.com/yourusername/mt5-bulk-order-manager.git
cd mt5-bulk-order-manager
```

2. **Install Python dependencies:**
```bash
pip install -r requirements.txt
```

3. **Copy MQL5 files to MT5:**
```bash
cp bulk-add-signals.mq5 "~/MetaTrader 5/MQL5/Experts/"
```

4. **Start the server:**
```bash
python server.py
```

### Option 2: Docker Installation

```bash
docker-compose up -d
```

The server will be available at `http://localhost:8080`

## 💻 Usage Examples

### Example 1: Gold Buy Stop Order

```bash
curl -X POST http://localhost:8080/order \
  -H "Content-Type: application/json" \
  -d '{
    "symbol": "XAUUSD",
    "order_type": "BUY_STOP",
    "price": 4100.0,
    "sl": 4096.0,
    "tp_levels": [4103.0, 4106.0, 4109.0, 4112.0, 4115.0],
    "lot_size": 0.1
  }'
```

This creates 5 orders:
- 0.06 lots @ TP 4103.0 (30 pips)
- 0.01 lots @ TP 4106.0 (60 pips)
- 0.01 lots @ TP 4109.0 (90 pips)
- 0.01 lots @ TP 4112.0 (120 pips)
- 0.01 lots @ TP 4115.0 (150 pips)

### Example 2: Silver Sell Stop Order

```bash
curl -X POST http://localhost:8080/order \
  -H "Content-Type: application/json" \
  -d '{
    "symbol": "XAGUSD",
    "order_type": "SELL_STOP",
    "price": 29.50,
    "sl": 29.65,
    "tp_levels": [29.35, 29.05, 28.75, 28.45, 28.15],
    "lot_size": 0.5
  }'
```

### Example 3: Check All Positions

```bash
curl http://localhost:8080/positions
```

### Example 4: Activate Safe Shutdown

```bash
curl -X POST http://localhost:8080/safe-shutdown
```

## 🔧 Troubleshooting

### EA Not Connecting to Server

**Symptoms:** EA shows "Not connected" in Experts tab

**Solutions:**
1. Check Python server is running: `curl http://localhost:8080/health`
2. Verify port 5555 is listening: `netstat -an | grep 5555`
3. Check firewall allows local connections
4. Ensure "Allow DLL imports" is enabled in EA settings
5. Check EA logs in MT5 Experts tab for error messages

### Orders Failing with "Invalid Price"

**Symptoms:** All split orders fail immediately

**Cause:** Order type doesn't match price position relative to market

**Solution:** The EA now auto-detects and converts:
- SELL STOP above market → SELL LIMIT
- BUY STOP below market → BUY LIMIT

Recompile the EA with the latest code.

### Port Already in Use

**Symptoms:** Server fails to start with "Address already in use"

**Solution:**
```bash
# Find and kill process using port 8080
lsof -ti:8080 | xargs kill -9

# Find and kill process using port 5555
lsof -ti:5555 | xargs kill -9

# Restart server
python server.py
```

### Trailing Stop Not Activating

**Symptoms:** TP2 closes but SL doesn't move to TP1

**Possible Causes:**
1. EA was restarted after orders placed (group tracking lost)
2. Orders placed manually instead of through API
3. Comment format doesn't match expected pattern

**Solution:**
- Always place orders through the API
- Don't restart EA while positions are open
- Check order comments include GROUP and TP fields

### Safe Shutdown Not Working

**Symptoms:** Command succeeds but TPs not modified

**Cause:** EA not compiled with latest code

**Solution:**
1. Open MetaEditor (F4)
2. Open bulk-add-signals.mq5
3. Press F7 to recompile
4. Restart EA on chart
5. Try safe shutdown command again

## ❓ FAQ

**Q: Can I use this with other symbols besides Gold and Silver?**
A: The code is optimized for XAUUSD and XAGUSD pip values. For other symbols, you'll need to adjust the `pipValue` calculation in the MQL5 code.

**Q: What happens if I restart MT5 while positions are open?**
A: The EA has position recovery logic that rebuilds order group tracking from position comments. However, trailing SL won't trigger during the restart period.

**Q: Can I change the volume distribution (60/10/10/10/10)?**
A: Yes, edit the `volumes[]` array in the `ExecuteOrder()` function in bulk-add-signals.mq5.

**Q: Does this work on MT4?**
A: No, this is specifically designed for MT5. MT4 uses a different API and doesn't support the same socket operations.

**Q: Can I run multiple EAs with different magic numbers?**
A: Yes, each EA instance can have a unique magic number. Configure it in the EA input parameters.

**Q: Is there a web interface?**
A: Currently, the system uses a REST API. You can build a web frontend that calls the API endpoints.

**Q: How do I backtest this EA?**
A: The EA uses socket communication which isn't available in Strategy Tester. For backtesting, you'd need to modify the code to use simulated data instead of TCP sockets.

**Q: What's the minimum lot size?**
A: Depends on your broker. Since orders are split into 0.01 lot increments, your broker must support 0.01 lots (micro lots).

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details

## 🤝 Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## ⚠️ Disclaimer

**This software is for educational purposes only. Trading forex and CFDs involves substantial risk of loss. Past performance is not indicative of future results. Always test on a demo account first.**

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/yourusername/mt5-bulk-order-manager/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourusername/mt5-bulk-order-manager/discussions)
- **Documentation**: [Wiki](https://github.com/yourusername/mt5-bulk-order-manager/wiki)

## 🎯 Roadmap

- [ ] Web-based dashboard for monitoring positions
- [ ] Telegram bot integration for alerts
- [ ] Support for additional symbols
- [ ] Advanced risk management presets
- [ ] Trade journal and analytics
- [ ] Multi-account support

## 🙏 Acknowledgments

- Built with [FastAPI](https://fastapi.tiangolo.com/)
- MetaTrader 5 by [MetaQuotes](https://www.metaquotes.net/)
- Inspired by professional trading strategies

---

**Made with ❤️ for algorithmic traders**

**Keywords:** MetaTrader 5, MT5, Expert Advisor, EA, Gold Trading, XAUUSD, Silver Trading, XAGUSD, Forex Bot, Trading Bot, Algorithmic Trading, Automated Trading, Split Orders, Trailing Stop, Risk Management, FastAPI, Python Trading, MQL5, Trading API, REST API, Socket Trading
