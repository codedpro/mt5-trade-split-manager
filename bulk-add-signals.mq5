//+------------------------------------------------------------------+
//|                                             bulk-add-signals.mq5 |
//|                                Bulk Signal Processing via TCP    |
//|                                          https://www.mql5.com    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      "https://www.mql5.com"
#property version   "4.20"
#property description "Receives trading signals via TCP sockets (MQL5 as client)"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/AccountInfo.mqh>

//--- Maximum number of split levels supported per order group.
//    Fixed-capacity arrays are used everywhere (no dynamic arrays inside
//    structs); every loop respects the group's real count or guards on
//    ticket==0 / tp_price<=0 for the unused tail.
#define MAX_SPLITS 10

//--- Input parameters
input string ServerHost = "127.0.0.1";       // Python server host
input int ServerPort = 5555;                  // Python server port
input int MagicNumber = 20250117;            // Magic number for orders
input double DefaultLotSize = 0.1;           // Default lot size
input int MaxSpreadPips = 10;                // Max spread in pips (0 disables the check)
input int MaxPositions = 50;                 // Max open positions + pending orders (combined)
input double MaxDailyLossPercent = 5.0;      // Max daily loss %
input int SocketCheckIntervalMs = 500;       // Socket check interval (ms)
input int SocketTimeout = 3000;              // Socket timeout (ms)

//--- Global variables
CTrade trade;
CPositionInfo position;
CAccountInfo account;

double dailyStartBalance = 0;
datetime dailyStartDay = 0;    // Start of the current trading day (for daily loss reset)
int g_groupCounter = 0;        // Monotonic counter to keep group IDs unique
bool g_groupsDirty = false;    // Set when orderGroups changes; flushed to disk by OnTimer

//--- Structures
struct TradeCommand {
    string action;
    string order_type;
    string symbol;
    double price;
    double sl;
    double tp_levels[MAX_SPLITS];    // Requested TP prices (tp_count of them are valid)
    double volume_split[MAX_SPLITS]; // Fraction of total lot per level (parallel to tp_levels)
    int tp_count;                    // Number of TP levels actually provided (1..MAX_SPLITS)
    double lot_size;
    int deviation;
    string comment;
};

struct SplitOrderGroup {
    string groupId;           // Unique identifier for the group (based on entry price + symbol)
    ulong tickets[MAX_SPLITS];  // Tickets for all split orders (0 = missing/skipped)
    double tp_prices[MAX_SPLITS]; // Actual TP price placed for each split (source of truth)
    int count;                // Number of split levels in this group (1..MAX_SPLITS)
    bool tp2_reached;         // Flag to track if TP2 was reached
    double entry_price;       // Entry price
    string symbol;            // Symbol
    ENUM_ORDER_TYPE order_type; // Order type
};

SplitOrderGroup orderGroups[];

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("==== Bulk Add Signals EA Initializing (TCP Client) ====");

    // Set trade parameters
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_RETURN);  // Changed from FOK to RETURN for better broker compatibility
    trade.SetAsyncMode(false);

    // Store starting balance and current trading day (for daily loss reset)
    dailyStartBalance = account.Balance();
    dailyStartDay = BrokerDayStart();

    // Recover existing positions for split order tracking
    RecoverSplitOrders();

    // Start timer
    EventSetMillisecondTimer(SocketCheckIntervalMs);

    Print("==== EA Initialized Successfully ====");
    Print("Magic Number: ", MagicNumber);
    Print("Python Server: ", ServerHost, ":", ServerPort);
    Print("Socket check interval: ", SocketCheckIntervalMs, "ms");

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("==== EA Shutting Down ====");
    EventKillTimer();

    // Persist any pending group-state change before we stop.
    if(g_groupsDirty)
    {
        SaveGroups();
        g_groupsDirty = false;
    }

    // Clean up all chart objects created by this EA
    for(int i = ArraySize(orderGroups) - 1; i >= 0; i--)
    {
        RemoveTPObjects(orderGroups[i].groupId);
    }
}

//+------------------------------------------------------------------+
//| Timer function - connects to Python TCP server                    |
//+------------------------------------------------------------------+
void OnTimer()
{
    // Run trailing from the timer as well as OnTick: OnTick only fires for
    // the chart's own symbol, so groups on other symbols would otherwise not
    // trail until this chart happened to tick.
    CheckTP2ForTrailingSL();

    // Flush group state to disk when it changed (at most once per timer tick).
    if(g_groupsDirty)
    {
        SaveGroups();
        g_groupsDirty = false;
    }

    // Create TCP socket
    int socket = SocketCreate();
    if(socket == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create socket");
        return;
    }

    // Connect to Python server
    if(!SocketConnect(socket, ServerHost, ServerPort, SocketTimeout))
    {
        int error = GetLastError();
        if(error != 0 && error != 4014)  // Only log errors other than URL not allowed
        {
            Print("ERROR: SocketConnect failed - Error code: ", error);
        }
        SocketClose(socket);
        return;
    }

    // Receive command from Python server
    uchar buffer[];
    ArrayResize(buffer, 8192);

    string commandJson = "";
    uint timeout_start = GetTickCount();

    while(GetTickCount() - timeout_start < (uint)SocketTimeout)
    {
        uint len = SocketIsReadable(socket);
        if(len > 0)
        {
            int received = SocketRead(socket, buffer, len, SocketTimeout);
            if(received > 0)
            {
                commandJson += CharArrayToString(buffer, 0, received);

                // Check if we have complete JSON
                if(StringFind(commandJson, "}") >= 0)
                {
                    break;
                }
            }
        }
        Sleep(10);
    }

    if(StringLen(commandJson) < 10)
    {
        SocketClose(socket);
        return;
    }

    // Check if it's just a waiting status - silently ignore
    if(StringFind(commandJson, "\"status\":\"waiting\"") >= 0)
    {
        SocketClose(socket);
        return;
    }

    // Only log actual trading commands
    Print("[NET] Connected - Received command: ", StringSubstr(commandJson, 0, MathMin(100, StringLen(commandJson))), "...");

    // Process command
    string response = ProcessCommand(commandJson);

    // Send response back to Python
    uchar responseBuffer[];
    int strLen = StringToCharArray(response, responseBuffer, 0, StringLen(response));

    int sent = SocketSend(socket, responseBuffer, strLen);
    if(sent < 0)
    {
        Print("ERROR: Failed to send response to Python");
    }

    // Close socket
    SocketClose(socket);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    CheckTP2ForTrailingSL();
}

//+------------------------------------------------------------------+
//| Process command                                                    |
//+------------------------------------------------------------------+
string ProcessCommand(string commandJson)
{
    // Extract action
    string action = ExtractString(commandJson, "action");

    Print("Processing action: ", action);

    // Route to appropriate handler
    if(action == "PLACE_ORDER")
    {
        return HandlePlaceOrder(commandJson);
    }
    else if(action == "GET_POSITIONS")
    {
        return HandleGetPositions();
    }
    else if(action == "GET_ORDERS")
    {
        return HandleGetOrders();
    }
    else if(action == "DELETE_ORDER")
    {
        return HandleDeleteOrder(commandJson);
    }
    else if(action == "CLOSE_POSITION")
    {
        return HandleClosePosition(commandJson);
    }
    else if(action == "GET_STATS")
    {
        return HandleGetStats();
    }
    else if(action == "SAFE_SHUTDOWN")
    {
        return HandleSafeShutdown();
    }
    else
    {
        return "{\"success\":false,\"message\":\"Unknown action\"}";
    }
}

//+------------------------------------------------------------------+
//| Apply the default volume split when the caller omits one.         |
//| N==1 -> [1.0]; N>=2 -> TP1=0.60, each remaining = 0.40/(N-1).     |
//| For N==5 this reproduces the legacy 60/10/10/10/10 exactly.       |
//+------------------------------------------------------------------+
void ApplyDefaultVolumeSplit(TradeCommand &cmd)
{
    for(int i = 0; i < MAX_SPLITS; i++)
        cmd.volume_split[i] = 0;

    int n = cmd.tp_count;
    if(n <= 0) return;

    if(n == 1)
    {
        cmd.volume_split[0] = 1.0;
        return;
    }

    cmd.volume_split[0] = 0.60;
    double rest = 0.40 / (double)(n - 1);
    for(int i = 1; i < n; i++)
        cmd.volume_split[i] = rest;
}

//+------------------------------------------------------------------+
//| Handle place order command                                        |
//+------------------------------------------------------------------+
string HandlePlaceOrder(string commandJson)
{
    TradeCommand cmd;

    // Check for nested "data" object
    string dataJson = commandJson;
    int dataPos = StringFind(commandJson, "\"data\"");
    if(dataPos >= 0)
    {
        int dataStart = StringFind(commandJson, "{", dataPos);
        if(dataStart >= 0)
        {
            // Extract just the data portion
            dataJson = StringSubstr(commandJson, dataStart);
        }
    }

    // Extract fields
    cmd.order_type = ExtractString(dataJson, "order_type");
    cmd.symbol = ExtractString(dataJson, "symbol");
    cmd.comment = ExtractString(dataJson, "comment");
    cmd.price = ExtractDouble(dataJson, "price");
    cmd.sl = ExtractDouble(dataJson, "sl");
    cmd.lot_size = ExtractDouble(dataJson, "lot_size");
    cmd.deviation = (int)ExtractDouble(dataJson, "deviation");

    // Zero out the fixed-capacity arrays before parsing.
    for(int i = 0; i < MAX_SPLITS; i++)
    {
        cmd.tp_levels[i]    = 0;
        cmd.volume_split[i] = 0;
    }
    cmd.tp_count = 0;

    // Extract TP levels (1..MAX_SPLITS entries). tp_raw is how many the caller
    // actually sent; tp_count is that clamped to capacity and drives every
    // downstream loop.
    int tp_raw = 0;
    int tp_start = StringFind(dataJson, "\"tp_levels\"");
    if(tp_start >= 0)
    {
        int arr_start = StringFind(dataJson, "[", tp_start);
        int arr_end = StringFind(dataJson, "]", arr_start);
        string tp_str = StringSubstr(dataJson, arr_start + 1, arr_end - arr_start - 1);

        string tp_values[];
        tp_raw = StringSplit(tp_str, ',', tp_values);
        if(tp_raw < 0) tp_raw = 0;
        int tp_parse = (int)MathMin(MAX_SPLITS, tp_raw);
        for(int i = 0; i < tp_parse; i++)
        {
            // Clean whitespace
            string val = tp_values[i];
            StringTrimLeft(val);
            StringTrimRight(val);
            cmd.tp_levels[i] = StringToDouble(val);
        }
        cmd.tp_count = tp_parse;
    }

    // Extract optional volume_split. When present its length must match
    // tp_count. When absent, apply the same default formula as the server so
    // direct TCP callers behave identically (defense in depth).
    bool haveSplit = false;
    int vs_raw = 0;
    int vs_start = StringFind(dataJson, "\"volume_split\"");
    if(vs_start >= 0)
    {
        int varr_start = StringFind(dataJson, "[", vs_start);
        int varr_end = StringFind(dataJson, "]", varr_start);
        if(varr_start >= 0 && varr_end > varr_start)
        {
            string vs_str = StringSubstr(dataJson, varr_start + 1, varr_end - varr_start - 1);
            string vs_trim = vs_str;
            StringTrimLeft(vs_trim);
            StringTrimRight(vs_trim);
            if(StringLen(vs_trim) > 0)
            {
                haveSplit = true;
                string vs_values[];
                vs_raw = StringSplit(vs_str, ',', vs_values);
                if(vs_raw < 0) vs_raw = 0;
                int vs_parse = (int)MathMin(MAX_SPLITS, vs_raw);
                for(int i = 0; i < vs_parse; i++)
                {
                    string val = vs_values[i];
                    StringTrimLeft(val);
                    StringTrimRight(val);
                    cmd.volume_split[i] = StringToDouble(val);
                }
            }
        }
    }

    if(!haveSplit)
        ApplyDefaultVolumeSplit(cmd);

    Print("Parsed command: ", cmd.order_type, " ", cmd.symbol, " @ ", cmd.price, " SL:", cmd.sl, " Lot:", cmd.lot_size, " TPs:", cmd.tp_count);

    // Validate level count and volume split (mirrors the server-side rules).
    if(tp_raw < 1 || tp_raw > MAX_SPLITS)
        return BuildResponse(false, StringFormat("tp_levels must contain 1..%d prices (got %d)", MAX_SPLITS, tp_raw), 0);

    if(haveSplit && vs_raw != cmd.tp_count)
        return BuildResponse(false, StringFormat("volume_split length (%d) must match tp_levels count (%d)", vs_raw, cmd.tp_count), 0);

    double splitSum = 0;
    bool anyPositive = false;
    for(int i = 0; i < cmd.tp_count; i++)
    {
        if(cmd.volume_split[i] < 0)
            return BuildResponse(false, StringFormat("volume_split[%d] must be >= 0", i+1), 0);
        if(cmd.volume_split[i] > 0) anyPositive = true;
        splitSum += cmd.volume_split[i];
    }
    if(!anyPositive)
        return BuildResponse(false, "volume_split must have at least one entry > 0", 0);
    if(splitSum < 0.99 || splitSum > 1.01)
        return BuildResponse(false, StringFormat("volume_split must sum to ~1.0 (got %.4f)", splitSum), 0);

    // Validate
    if(!ValidateCommand(cmd))
    {
        return BuildResponse(false, "Validation failed", 0);
    }

    // Execute
    string errorMsg = "";
    ulong ticket = ExecuteOrder(cmd, errorMsg);
    if(ticket > 0)
    {
        return BuildResponse(true, "Order placed successfully", ticket);
    }

    return BuildResponse(false, errorMsg, 0);
}

//+------------------------------------------------------------------+
//| Extract string from JSON                                          |
//+------------------------------------------------------------------+
string ExtractString(string json, string key)
{
    int pos = StringFind(json, "\"" + key + "\"");
    if(pos < 0) return "";

    int start = StringFind(json, ":", pos) + 1;
    start = StringFind(json, "\"", start) + 1;
    int end = StringFind(json, "\"", start);

    if(start < 0 || end < 0) return "";

    return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| Extract double from JSON                                          |
//+------------------------------------------------------------------+
double ExtractDouble(string json, string key)
{
    int pos = StringFind(json, "\"" + key + "\"");
    if(pos < 0) return 0;

    int start = StringFind(json, ":", pos) + 1;
    int end = start;

    while(end < StringLen(json))
    {
        ushort ch = StringGetCharacter(json, end);
        if(ch == ',' || ch == '}' || ch == ']') break;
        end++;
    }

    string value = StringSubstr(json, start, end - start);
    StringTrimLeft(value);
    StringTrimRight(value);

    return StringToDouble(value);
}

//+------------------------------------------------------------------+
//| Parse an order-type string into an ENUM (WRONG_VALUE if unknown)  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE ParseOrderType(string s)
{
    if(s == "BUY_STOP")   return ORDER_TYPE_BUY_STOP;
    if(s == "SELL_STOP")  return ORDER_TYPE_SELL_STOP;
    if(s == "BUY_LIMIT")  return ORDER_TYPE_BUY_LIMIT;
    if(s == "SELL_LIMIT") return ORDER_TYPE_SELL_LIMIT;
    return WRONG_VALUE;
}

//+------------------------------------------------------------------+
//| Is this a buy-side order type?                                    |
//+------------------------------------------------------------------+
bool IsBuyType(ENUM_ORDER_TYPE t)
{
    return (t == ORDER_TYPE_BUY_STOP || t == ORDER_TYPE_BUY_LIMIT);
}

//+------------------------------------------------------------------+
//| One pip in price terms for a symbol.                              |
//| 5/3-digit quotes: 1 pip = 10 points. Everything else (2/4-digit   |
//| FX, metals, indices): 1 pip = 1 point (the broker's increment).   |
//| Only used for the spread guard; order prices use real TP values.  |
//+------------------------------------------------------------------+
double SymbolPip(string sym)
{
    int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(sym, SYMBOL_POINT);
    if(point <= 0) return 0;
    return (digits == 3 || digits == 5) ? point * 10.0 : point;
}

//+------------------------------------------------------------------+
//| Start of the current broker trading day (broker midnight), so the |
//| daily-loss window follows the broker clock, not the server's UTC. |
//+------------------------------------------------------------------+
datetime BrokerDayStart()
{
    datetime d = iTime(_Symbol, PERIOD_D1, 0);
    if(d <= 0) d = TimeCurrent() - (TimeCurrent() % 86400);  // fallback if no bar yet
    return d;
}

//+------------------------------------------------------------------+
//| Validate command                                                   |
//+------------------------------------------------------------------+
bool ValidateCommand(TradeCommand &cmd)
{
    if(!SymbolInfoInteger(cmd.symbol, SYMBOL_SELECT))
    {
        Print("ERROR: Symbol not found: ", cmd.symbol);
        return false;
    }

    double minLot = SymbolInfoDouble(cmd.symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(cmd.symbol, SYMBOL_VOLUME_MAX);

    if(cmd.lot_size < minLot || cmd.lot_size > maxLot)
    {
        Print("ERROR: Invalid lot size: ", cmd.lot_size, " (min:", minLot, " max:", maxLot, ")");
        return false;
    }

    // Spread guard: reject when the live spread exceeds MaxSpreadPips.
    if(MaxSpreadPips > 0)
    {
        double pip = SymbolPip(cmd.symbol);
        double ask = SymbolInfoDouble(cmd.symbol, SYMBOL_ASK);
        double bid = SymbolInfoDouble(cmd.symbol, SYMBOL_BID);
        if(pip > 0 && ask > 0 && bid > 0)
        {
            double spreadPips = (ask - bid) / pip;
            if(spreadPips > MaxSpreadPips)
            {
                Print("ERROR: Spread ", DoubleToString(spreadPips, 1), " pips exceeds MaxSpreadPips (", MaxSpreadPips, ")");
                return false;
            }
        }
    }

    // Combined cap: our open positions AND pending orders both count, so a
    // burst of pending split orders can't blow past the limit unnoticed.
    if(CountOpenPositions() + CountPendingOrders() >= MaxPositions)
    {
        Print("ERROR: Max positions+orders reached: ", MaxPositions);
        return false;
    }

    if(!CheckDailyLossLimit())
    {
        Print("ERROR: Daily loss limit exceeded");
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Execute order - splits into up to MAX_SPLITS orders per split    |
//+------------------------------------------------------------------+
ulong ExecuteOrder(TradeCommand &cmd, string &errorMsg)
{
    // Parse the requested order type explicitly. We do NOT silently convert a
    // STOP into a LIMIT (or vice-versa): that would reverse the trade's intent
    // (breakout vs. pullback entry). Ambiguous requests are rejected instead.
    ENUM_ORDER_TYPE orderType = ParseOrderType(cmd.order_type);
    if(orderType == WRONG_VALUE)
    {
        errorMsg = "Unknown order_type '" + cmd.order_type + "' (expected BUY_STOP/SELL_STOP/BUY_LIMIT/SELL_LIMIT)";
        Print("[ERR] ", errorMsg);
        return 0;
    }

    double ask = SymbolInfoDouble(cmd.symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(cmd.symbol, SYMBOL_BID);
    bool isBuy = IsBuyType(orderType);

    // Reject orders whose price is on the wrong side of the market for the
    // requested type, rather than quietly re-interpreting them.
    string sideError = "";
    if(orderType == ORDER_TYPE_BUY_STOP   && cmd.price <= ask) sideError = "BUY_STOP requires price ABOVE ask - use BUY_LIMIT for entries below market";
    if(orderType == ORDER_TYPE_BUY_LIMIT  && cmd.price >= ask) sideError = "BUY_LIMIT requires price BELOW ask - use BUY_STOP for entries above market";
    if(orderType == ORDER_TYPE_SELL_STOP  && cmd.price >= bid) sideError = "SELL_STOP requires price BELOW bid - use SELL_LIMIT for entries above market";
    if(orderType == ORDER_TYPE_SELL_LIMIT && cmd.price <= bid) sideError = "SELL_LIMIT requires price ABOVE bid - use SELL_STOP for entries below market";
    if(sideError != "")
    {
        errorMsg = StringFormat("%s (ask=%.5f bid=%.5f price=%.5f)", sideError, ask, bid, cmd.price);
        Print("[ERR] Refusing order: ", errorMsg);
        return 0;
    }

    // Validate SL / TP are on the correct side of the entry for the direction.
    if(cmd.sl > 0)
    {
        if(isBuy && cmd.sl >= cmd.price)  { errorMsg = "BUY stop-loss must be below entry price";  Print("[ERR] ", errorMsg); return 0; }
        if(!isBuy && cmd.sl <= cmd.price) { errorMsg = "SELL stop-loss must be above entry price"; Print("[ERR] ", errorMsg); return 0; }
    }
    for(int t = 0; t < cmd.tp_count; t++)
    {
        if(cmd.tp_levels[t] <= 0)                       { errorMsg = StringFormat("TP%d is missing or invalid", t+1);     Print("[ERR] ", errorMsg); return 0; }
        if(isBuy && cmd.tp_levels[t] <= cmd.price)      { errorMsg = StringFormat("BUY TP%d must be above entry price", t+1);  Print("[ERR] ", errorMsg); return 0; }
        if(!isBuy && cmd.tp_levels[t] >= cmd.price)     { errorMsg = StringFormat("SELL TP%d must be below entry price", t+1); Print("[ERR] ", errorMsg); return 0; }
    }

    Print("Executing ", cmd.order_type, " order on ", cmd.symbol);
    Print("Ask: ", ask, " | Bid: ", bid, " | Order price: ", cmd.price, " | SL: ", cmd.sl, " | Total Lot: ", cmd.lot_size);
    Print("Splitting into ", cmd.tp_count, " order(s) per volume_split");

    // --- Volume computation (any-symbol correct) ---
    // Floor each split to the symbol's volume step; reject the whole order if
    // any nonzero split floors below the broker minimum; add the flooring
    // leftover to the first level with the largest ratio.
    double step = SymbolInfoDouble(cmd.symbol, SYMBOL_VOLUME_STEP);
    if(step <= 0) step = 0.01;  // Fallback when the broker reports no step
    double volMin = SymbolInfoDouble(cmd.symbol, SYMBOL_VOLUME_MIN);

    double volumes[MAX_SPLITS];
    for(int i = 0; i < MAX_SPLITS; i++) volumes[i] = 0;

    double sumVol = 0;
    for(int i = 0; i < cmd.tp_count; i++)
    {
        double v = MathFloor(cmd.lot_size * cmd.volume_split[i] / step + 1e-9) * step;
        v = NormalizeDouble(v, 8);  // strip floating-point dust from the multiply

        if(cmd.volume_split[i] > 0 && v < volMin)
        {
            double minViable = MathCeil((volMin / cmd.volume_split[i]) / step - 1e-9) * step;
            errorMsg = StringFormat("TP%d volume %.4f below broker minimum %.4f - increase lot_size to at least %.4f",
                                    i+1, v, volMin, minViable);
            Print("[ERR] ", errorMsg);
            return 0;
        }

        volumes[i] = v;
        sumVol += v;
    }

    // Add the flooring leftover (floored to step) to the first level having the
    // largest ratio (deterministic: lowest index wins on ties).
    double leftover = MathFloor((cmd.lot_size - sumVol) / step + 1e-9) * step;
    if(leftover > 1e-9)
    {
        int bestIdx = -1;
        double bestRatio = -1;
        for(int i = 0; i < cmd.tp_count; i++)
        {
            if(cmd.volume_split[i] > bestRatio)
            {
                bestRatio = cmd.volume_split[i];
                bestIdx = i;
            }
        }
        if(bestIdx >= 0)
            volumes[bestIdx] = NormalizeDouble(volumes[bestIdx] + leftover, 8);
    }

    // Normalize entry / SL / every TP to the symbol's digits before OrderOpen.
    int digits = (int)SymbolInfoInteger(cmd.symbol, SYMBOL_DIGITS);
    double entryN = NormalizeDouble(cmd.price, digits);
    double slN    = (cmd.sl > 0) ? NormalizeDouble(cmd.sl, digits) : cmd.sl;
    double tpN[MAX_SPLITS];
    for(int i = 0; i < MAX_SPLITS; i++)
        tpN[i] = (i < cmd.tp_count) ? NormalizeDouble(cmd.tp_levels[i], digits) : 0;

    // Create a compact, unique group ID. Kept short so it fits inside the MT5
    // order comment (brokers truncate long comments, which used to silently
    // break recovery). The monotonic counter guarantees uniqueness per second.
    g_groupCounter++;
    string groupId = StringFormat("SM%d_%d", (int)TimeLocal(), g_groupCounter);

    // Create split order group
    int groupIndex = ArraySize(orderGroups);
    ArrayResize(orderGroups, groupIndex + 1);
    orderGroups[groupIndex].groupId     = groupId;
    orderGroups[groupIndex].count       = cmd.tp_count;
    orderGroups[groupIndex].tp2_reached = false;
    orderGroups[groupIndex].entry_price = entryN;
    orderGroups[groupIndex].symbol      = cmd.symbol;
    orderGroups[groupIndex].order_type  = orderType;
    for(int t = 0; t < MAX_SPLITS; t++)
    {
        orderGroups[groupIndex].tickets[t]   = 0;
        // Record the normalized TP for placed/failed levels; 0 for skipped
        // (volume 0) and the unused tail so drawing/trailing ignore them.
        orderGroups[groupIndex].tp_prices[t] = (t < cmd.tp_count && volumes[t] > 0) ? tpN[t] : 0;
    }

    // Place the split orders (skip levels whose split floored to 0 volume)
    int successCount = 0;
    ulong firstTicket = 0;

    for(int i = 0; i < cmd.tp_count; i++)
    {
        if(volumes[i] <= 0)
        {
            Print("[SKIP] Split level ", i+1, "/", cmd.tp_count, " skipped (volume_split=0)");
            continue;
        }

        // Functional comment only: "<groupId>#<tpIndex>". No free-text prefix,
        // so the group/index tokens can't be pushed out by comment truncation.
        string orderComment = StringFormat("%s#%d", groupId, i+1);

        bool success = trade.OrderOpen(
            cmd.symbol,
            orderType,
            volumes[i],
            0,
            entryN,
            slN,
            tpN[i],
            ORDER_TIME_GTC,
            0,
            orderComment
        );

        if(success)
        {
            ulong ticket = trade.ResultOrder();
            orderGroups[groupIndex].tickets[i] = ticket;

            if(firstTicket == 0) firstTicket = ticket;

            Print("[OK] Split order ", i+1, "/", cmd.tp_count, " placed - Ticket: ", ticket,
                  " | Vol: ", volumes[i], " | TP", i+1, ": ", tpN[i]);
            successCount++;
        }
        else
        {
            errorMsg = trade.ResultRetcodeDescription();
            Print("[ERR] Split order ", i+1, "/", cmd.tp_count, " failed - ", errorMsg);
            orderGroups[groupIndex].tickets[i] = 0;
        }
    }

    if(successCount == 0)
    {
        // All orders failed - remove group
        ArrayRemove(orderGroups, groupIndex, 1);
        errorMsg = "All split orders failed";
        return 0;
    }

    // Draw TP levels on chart (once for the group) using the ACTUAL TP prices
    // and the ACTUAL per-level volumes.
    DrawTPLevels(groupId, cmd.symbol, entryN, orderGroups[groupIndex].tp_prices, volumes, cmd.tp_count);

    Print("[OK] Order group placed: ", successCount, "/", cmd.tp_count, " orders successful");
    g_groupsDirty = true;  // persist the new group on the next timer flush
    return firstTicket;  // Return first ticket as reference
}


//+------------------------------------------------------------------+
//| Draw TP levels on chart                                           |
//+------------------------------------------------------------------+
void DrawTPLevels(string groupId, string symbol, double entryPrice, double &tpPrices[], double &volumes[], int count)
{
    // 10-entry palette so every possible split level gets a distinct color.
    color levelColors[MAX_SPLITS] = {clrLime, clrGreen, clrYellow, clrOrange, clrRed,
                                     clrDeepPink, clrAqua, clrMagenta, clrGold, clrTomato};

    for(int i = 0; i < count; i++)
    {
        double tpPrice = tpPrices[i];
        if(tpPrice <= 0) continue;  // TP already closed / skipped / unknown - skip drawing

        // Create horizontal line
        string lineName = StringFormat("TP%d_Line_%s", i+1, groupId);
        ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, tpPrice);
        ObjectSetInteger(0, lineName, OBJPROP_COLOR, levelColors[i]);
        ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DASH);
        ObjectSetInteger(0, lineName, OBJPROP_BACK, false);
        ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);

        // Create text label (shows the ACTUAL per-level volume)
        string labelName = StringFormat("TP%d_Label_%s", i+1, groupId);
        ObjectCreate(0, labelName, OBJ_TEXT, 0, TimeCurrent(), tpPrice);
        ObjectSetString(0, labelName, OBJPROP_TEXT, StringFormat("  TP%d: %.3f (%.2f lots)", i+1, tpPrice, volumes[i]));
        ObjectSetInteger(0, labelName, OBJPROP_COLOR, levelColors[i]);
        ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, labelName, OBJPROP_FONT, "Arial Bold");
        ObjectSetInteger(0, labelName, OBJPROP_BACK, false);
        ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
    }

    // Add entry price line
    string entryLineName = StringFormat("Entry_%s", groupId);
    ObjectCreate(0, entryLineName, OBJ_HLINE, 0, 0, entryPrice);
    ObjectSetInteger(0, entryLineName, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, entryLineName, OBJPROP_WIDTH, 3);
    ObjectSetInteger(0, entryLineName, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, entryLineName, OBJPROP_BACK, false);
    ObjectSetInteger(0, entryLineName, OBJPROP_SELECTABLE, false);

    string entryLabelName = StringFormat("Entry_Label_%s", groupId);
    ObjectCreate(0, entryLabelName, OBJ_TEXT, 0, TimeCurrent(), entryPrice);
    ObjectSetString(0, entryLabelName, OBJPROP_TEXT, StringFormat("  Entry: %.3f [%s]", entryPrice, groupId));
    ObjectSetInteger(0, entryLabelName, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, entryLabelName, OBJPROP_FONTSIZE, 10);
    ObjectSetString(0, entryLabelName, OBJPROP_FONT, "Arial Bold");
    ObjectSetInteger(0, entryLabelName, OBJPROP_BACK, false);
    ObjectSetInteger(0, entryLabelName, OBJPROP_SELECTABLE, false);

    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update TP level visual (mark as closed)                          |
//+------------------------------------------------------------------+
void UpdateTPLevelClosed(string groupId, int level)
{
    string lineName = StringFormat("TP%d_Line_%s", level, groupId);
    string labelName = StringFormat("TP%d_Label_%s", level, groupId);

    // Change to gray and strikethrough style
    ObjectSetInteger(0, lineName, OBJPROP_COLOR, clrGray);
    ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DOT);
    ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 1);

    ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrGray);

    // Update text to show "CLOSED"
    double price = ObjectGetDouble(0, lineName, OBJPROP_PRICE);
    ObjectSetString(0, labelName, OBJPROP_TEXT, StringFormat("  TP%d: %.3f CLOSED", level, price));

    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Remove all TP objects for a group                                |
//+------------------------------------------------------------------+
void RemoveTPObjects(string groupId)
{
    // Remove TP lines and labels. Loop the full capacity so recovered or
    // legacy groups (whose real count is unknown here) are fully cleaned.
    for(int i = 1; i <= MAX_SPLITS; i++)
    {
        ObjectDelete(0, StringFormat("TP%d_Line_%s", i, groupId));
        ObjectDelete(0, StringFormat("TP%d_Label_%s", i, groupId));
    }

    // Remove entry line and label
    ObjectDelete(0, StringFormat("Entry_%s", groupId));
    ObjectDelete(0, StringFormat("Entry_Label_%s", groupId));

    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Check TP2 for trailing SL across all split orders                |
//+------------------------------------------------------------------+
void CheckTP2ForTrailingSL()
{
    for(int i = ArraySize(orderGroups) - 1; i >= 0; i--)
    {
        ulong tp2_ticket = orderGroups[i].tickets[1];

        // Trailing trigger: TP2 must have been placed (ticket > 0), must no
        // longer be a pending order (it filled), and must no longer be an
        // open position (it closed). Checking positions alone misfired for
        // pending groups: a stop order that has not filled yet is NOT a
        // position, so TP2 looked "closed" one tick after placement and the
        // group's tracking self-destructed before any order ever filled.
        if(!orderGroups[i].tp2_reached && tp2_ticket > 0 &&
           !OrderSelect(tp2_ticket) && !PositionSelectByTicket(tp2_ticket))
        {
            // TP2 was hit! Move SL to TP1 for all remaining positions
            Print("[HIT] TP2 reached for group ", orderGroups[i].groupId, " - Moving SL to TP1 for all remaining positions");

            // Use the ACTUAL TP1 price that was placed - not a hardcoded pip
            // offset that may not match the caller's TP ladder. Fall back to
            // breakeven (entry) if TP1's price is unknown after recovery.
            double newSL = orderGroups[i].tp_prices[0];
            if(newSL <= 0) newSL = orderGroups[i].entry_price;

            // Update SL for all remaining positions (TP3..count)
            int movedCount = 0;
            for(int j = 2; j < orderGroups[i].count; j++)  // Start from index 2 (TP3)
            {
                ulong ticket = orderGroups[i].tickets[j];
                if(ticket == 0) continue;

                if(PositionSelectByTicket(ticket))
                {
                    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                    double currentSL = PositionGetDouble(POSITION_SL);
                    double currentTP = PositionGetDouble(POSITION_TP);

                    // Only move SL if new SL is better than current
                    bool shouldMove = false;
                    if(posType == POSITION_TYPE_BUY && newSL > currentSL)
                        shouldMove = true;
                    else if(posType == POSITION_TYPE_SELL && newSL < currentSL)
                        shouldMove = true;

                    if(shouldMove)
                    {
                        if(trade.PositionModify(ticket, newSL, currentTP))
                        {
                            Print("[OK] SL moved to TP1 for position #", ticket, " (TP", j+1, ")");
                            movedCount++;
                        }
                        else
                        {
                            Print("[WARN]  Failed to move SL for position #", ticket, ": ", trade.ResultRetcodeDescription());
                        }
                    }
                }
            }

            if(movedCount > 0)
            {
                Print("[OK] Trailing SL applied: ", movedCount, " position(s) now have SL at TP1 (", newSL, ")");
            }

            // Mark as TP2 reached
            orderGroups[i].tp2_reached = true;
            g_groupsDirty = true;

            // Update visual
            UpdateTPLevelClosed(orderGroups[i].groupId, 2);
        }

        // Clean up the group only when NOTHING is alive on any level: neither
        // an open position nor a still-pending order. This runs for every
        // group (including tp2_reached ones, which previously leaked forever,
        // and skipped-TP2 / single-level groups).
        bool anyAlive = false;
        for(int j = 0; j < orderGroups[i].count; j++)
        {
            ulong ticket = orderGroups[i].tickets[j];
            if(ticket > 0 && (OrderSelect(ticket) || PositionSelectByTicket(ticket)))
            {
                anyAlive = true;
                break;
            }
        }

        if(!anyAlive)
        {
            Print("[END] All orders/positions closed for group ", orderGroups[i].groupId);
            RemoveTPObjects(orderGroups[i].groupId);
            ArrayRemove(orderGroups, i, 1);
            g_groupsDirty = true;
        }
    }
}

//+------------------------------------------------------------------+
//| Count positions                                                    |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(position.SelectByIndex(i) && position.Magic() == MagicNumber)
        {
            count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Count this EA's pending orders                                    |
//+------------------------------------------------------------------+
int CountPendingOrders()
{
    int count = 0;
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket > 0 && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
        {
            count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Check daily loss                                                   |
//+------------------------------------------------------------------+
bool CheckDailyLossLimit()
{
    // Reset the daily baseline when a new broker trading day starts.
    datetime today = BrokerDayStart();
    if(today != dailyStartDay)
    {
        dailyStartDay = today;
        dailyStartBalance = account.Balance();
    }

    if(dailyStartBalance <= 0) return true;

    // Measure against equity so floating (open) losses count too - more
    // conservative than balance, which ignores open positions.
    double loss = dailyStartBalance - account.Equity();
    double lossPercent = (loss / dailyStartBalance) * 100.0;

    return (lossPercent < MaxDailyLossPercent);
}

//+------------------------------------------------------------------+
//| Parse a split-order comment into (groupId, tpLevel).             |
//| Supports the new "<groupId>#<idx>" format and the legacy         |
//| "...|GROUP:<groupId>|TP:<idx>" format for in-flight orders.      |
//+------------------------------------------------------------------+
bool ParseGroupComment(string comment, string &groupId, int &tpLevel)
{
    // New compact format: "<groupId>#<idx>". Read ALL consecutive digits after
    // '#' so two-digit indices (e.g. "#10") parse correctly.
    int hashPos = StringFind(comment, "#");
    if(hashPos > 0)
    {
        groupId = StringSubstr(comment, 0, hashPos);
        int p = hashPos + 1;
        while(p < StringLen(comment))
        {
            ushort ch = StringGetCharacter(comment, p);
            if(ch < '0' || ch > '9') break;
            p++;
        }
        tpLevel = (int)StringToInteger(StringSubstr(comment, hashPos + 1, p - (hashPos + 1)));
        if(tpLevel >= 1 && tpLevel <= MAX_SPLITS) return true;
    }

    // Legacy format: "...|GROUP:<groupId>|TP:<idx>"
    int gPos = StringFind(comment, "|GROUP:");
    if(gPos >= 0)
    {
        int tpPos = StringFind(comment, "|TP:", gPos);
        if(tpPos >= 0)
        {
            groupId = StringSubstr(comment, gPos + 7, tpPos - gPos - 7);
            int p = tpPos + 4;
            while(p < StringLen(comment))
            {
                ushort ch = StringGetCharacter(comment, p);
                if(ch < '0' || ch > '9') break;
                p++;
            }
            tpLevel = (int)StringToInteger(StringSubstr(comment, tpPos + 4, p - (tpPos + 4)));
            if(tpLevel >= 1 && tpLevel <= MAX_SPLITS) return true;
        }
    }

    return false;
}

//+------------------------------------------------------------------+
//| Find the group with this id, or create a fresh (empty) one.      |
//+------------------------------------------------------------------+
int FindOrCreateGroup(string groupId)
{
    for(int i = 0; i < ArraySize(orderGroups); i++)
        if(orderGroups[i].groupId == groupId) return i;

    int idx = ArraySize(orderGroups);
    ArrayResize(orderGroups, idx + 1);
    orderGroups[idx].groupId = groupId;
    // Recovered groups don't know their original level count, so use the full
    // capacity and rely on ticket==0 / tp_price<=0 guards to skip empty slots.
    orderGroups[idx].count = MAX_SPLITS;
    orderGroups[idx].tp2_reached = false;
    orderGroups[idx].entry_price = 0;
    orderGroups[idx].symbol = "";
    for(int t = 0; t < MAX_SPLITS; t++)
    {
        orderGroups[idx].tickets[t] = 0;
        orderGroups[idx].tp_prices[t] = 0;
    }
    return idx;
}

//+------------------------------------------------------------------+
//| Per-EA state file name (magic + account keep instances separate). |
//+------------------------------------------------------------------+
string GroupStateFile()
{
    return StringFormat("split_groups_%d_%I64d.csv", MagicNumber, account.Login());
}

//+------------------------------------------------------------------+
//| Persist all tracked groups to disk. Called (via g_groupsDirty)    |
//| whenever the group set changes, so a restart can rebuild tracking |
//| even if the broker rewrote order comments.                        |
//+------------------------------------------------------------------+
void SaveGroups()
{
    int h = FileOpen(GroupStateFile(), FILE_WRITE|FILE_TXT|FILE_ANSI);
    if(h == INVALID_HANDLE)
    {
        Print("[WARN] Could not write group state file: ", GetLastError());
        return;
    }
    int n = ArraySize(orderGroups);
    for(int i = 0; i < n; i++)
    {
        string tickets = "";
        string prices = "";
        for(int t = 0; t < MAX_SPLITS; t++)
        {
            if(t > 0) { tickets += ","; prices += ","; }
            tickets += StringFormat("%I64u", orderGroups[i].tickets[t]);
            prices  += StringFormat("%.8f", orderGroups[i].tp_prices[t]);
        }
        // groupId|count|tp2|entry|symbol|order_type|tickets|tp_prices
        FileWrite(h, StringFormat("%s|%d|%d|%.8f|%s|%d|%s|%s",
            orderGroups[i].groupId, orderGroups[i].count,
            orderGroups[i].tp2_reached ? 1 : 0, orderGroups[i].entry_price,
            orderGroups[i].symbol, (int)orderGroups[i].order_type, tickets, prices));
    }
    FileClose(h);
}

//+------------------------------------------------------------------+
//| Load groups from disk. Returns true only if at least one valid    |
//| group was loaded; an empty/malformed file falls back to comments. |
//+------------------------------------------------------------------+
bool LoadGroups()
{
    if(!FileIsExist(GroupStateFile())) return false;
    int h = FileOpen(GroupStateFile(), FILE_READ|FILE_TXT|FILE_ANSI);
    if(h == INVALID_HANDLE) return false;

    while(!FileIsEnding(h))
    {
        string line = FileReadString(h);
        if(StringLen(line) < 5) continue;

        string f[];
        if(StringSplit(line, '|', f) != 8) continue;  // skip malformed lines

        int gi = ArraySize(orderGroups);
        ArrayResize(orderGroups, gi + 1);
        orderGroups[gi].groupId     = f[0];
        orderGroups[gi].count       = (int)StringToInteger(f[1]);
        orderGroups[gi].tp2_reached = (StringToInteger(f[2]) != 0);
        orderGroups[gi].entry_price = StringToDouble(f[3]);
        orderGroups[gi].symbol      = f[4];
        orderGroups[gi].order_type  = (ENUM_ORDER_TYPE)StringToInteger(f[5]);

        string ts[]; StringSplit(f[6], ',', ts);
        string ps[]; StringSplit(f[7], ',', ps);
        for(int t = 0; t < MAX_SPLITS; t++)
        {
            orderGroups[gi].tickets[t]   = (t < ArraySize(ts)) ? (ulong)StringToInteger(ts[t]) : 0;
            orderGroups[gi].tp_prices[t] = (t < ArraySize(ps)) ? StringToDouble(ps[t]) : 0;
        }
        if(orderGroups[gi].count < 1 || orderGroups[gi].count > MAX_SPLITS)
            orderGroups[gi].count = MAX_SPLITS;
    }
    FileClose(h);
    return (ArraySize(orderGroups) > 0);
}

//+------------------------------------------------------------------+
//| Redraw a recovered group's chart objects and gray out closed TPs. |
//+------------------------------------------------------------------+
void RedrawRecoveredGroup(int g)
{
    if(orderGroups[g].entry_price <= 0) return;

    double vols[MAX_SPLITS];
    for(int t = 0; t < MAX_SPLITS; t++)
    {
        vols[t] = 0;
        ulong tk = orderGroups[g].tickets[t];
        if(tk == 0) continue;
        if(PositionSelectByTicket(tk))   vols[t] = PositionGetDouble(POSITION_VOLUME);
        else if(OrderSelect(tk))         vols[t] = OrderGetDouble(ORDER_VOLUME_CURRENT);
    }

    DrawTPLevels(orderGroups[g].groupId, orderGroups[g].symbol,
                 orderGroups[g].entry_price, orderGroups[g].tp_prices, vols, orderGroups[g].count);

    for(int t = 0; t < orderGroups[g].count; t++)
        if(orderGroups[g].tickets[t] == 0)
            UpdateTPLevelClosed(orderGroups[g].groupId, t + 1);
}

//+------------------------------------------------------------------+
//| Recover split orders on EA restart                                |
//+------------------------------------------------------------------+
void RecoverSplitOrders()
{
    Print("==== Starting Split Order Recovery ====");

    ArrayResize(orderGroups, 0);  // Clear array first

    // Prefer the state file (authoritative: knows real count, tp2_reached, and
    // exact TP prices even if the broker rewrote order comments). Reconcile it
    // against live orders/positions and drop anything that no longer exists.
    if(LoadGroups())
    {
        for(int g = ArraySize(orderGroups) - 1; g >= 0; g--)
        {
            bool anyAlive = false;
            for(int t = 0; t < MAX_SPLITS; t++)
            {
                ulong tk = orderGroups[g].tickets[t];
                if(tk == 0) continue;
                if(OrderSelect(tk) || PositionSelectByTicket(tk)) anyAlive = true;
                else orderGroups[g].tickets[t] = 0;  // stale ticket - drop it
            }

            if(!anyAlive)
            {
                RemoveTPObjects(orderGroups[g].groupId);
                ArrayRemove(orderGroups, g, 1);
                continue;
            }

            // TP2 closed while we were offline: mark reached (as the comment
            // path does) so trailing state stays consistent.
            bool laterAlive = false;
            for(int t = 2; t < MAX_SPLITS; t++)
                if(orderGroups[g].tickets[t] > 0) { laterAlive = true; break; }
            if(orderGroups[g].tickets[1] == 0 && laterAlive)
                orderGroups[g].tp2_reached = true;

            RedrawRecoveredGroup(g);
        }

        Print("==== Recovered ", ArraySize(orderGroups), " group(s) from state file ====");
        SaveGroups();  // rewrite the reconciled state
        return;
    }

    // No state file (fresh install or first run after upgrade): fall back to
    // rebuilding from order comments, then seed the state file.
    Print("Total open positions found: ", PositionsTotal());
    Print("Total pending orders found: ", OrdersTotal());

    // Rebuild groups directly from open positions. The actual TP price of each
    // split is read back from the live order/position, so trailing and safe
    // shutdown stay consistent with what was really placed.
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(position.SelectByIndex(i) && position.Magic() == MagicNumber)
        {
            string groupId; int tpLevel;
            if(!ParseGroupComment(position.Comment(), groupId, tpLevel)) continue;

            int gi = FindOrCreateGroup(groupId);
            orderGroups[gi].tickets[tpLevel - 1]   = position.Ticket();
            orderGroups[gi].tp_prices[tpLevel - 1] = position.TakeProfit();

            if(orderGroups[gi].entry_price == 0)
            {
                orderGroups[gi].entry_price = position.PriceOpen();
                orderGroups[gi].symbol      = position.Symbol();
                ENUM_POSITION_TYPE posType  = (ENUM_POSITION_TYPE)position.Type();
                orderGroups[gi].order_type  = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
            }

            Print("   [OK] Found position TP", tpLevel, " - Ticket #", position.Ticket());
        }
    }

    // Then fold in pending orders for the same groups.
    for(int i = 0; i < OrdersTotal(); i++)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket > 0 && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
        {
            string groupId; int tpLevel;
            if(!ParseGroupComment(OrderGetString(ORDER_COMMENT), groupId, tpLevel)) continue;

            int gi = FindOrCreateGroup(groupId);
            orderGroups[gi].tickets[tpLevel - 1]   = ticket;
            orderGroups[gi].tp_prices[tpLevel - 1] = OrderGetDouble(ORDER_TP);

            if(orderGroups[gi].entry_price == 0)
            {
                orderGroups[gi].entry_price = OrderGetDouble(ORDER_PRICE_OPEN);
                orderGroups[gi].symbol      = OrderGetString(ORDER_SYMBOL);
                orderGroups[gi].order_type  = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            }

            Print("   [ORD] Found pending order TP", tpLevel, " - Ticket #", ticket);
        }
    }

    int groupCount = ArraySize(orderGroups);
    Print("Found ", groupCount, " unique order group(s) to recover");

    // Post-process: infer TP2-reached state and redraw visuals.
    for(int g = 0; g < groupCount; g++)
    {
        // TP2 was already hit if its ticket is gone but any later TP survives.
        bool laterAlive = false;
        for(int t = 2; t < MAX_SPLITS; t++)
            if(orderGroups[g].tickets[t] > 0) { laterAlive = true; break; }

        if(orderGroups[g].tickets[1] == 0 && laterAlive)
        {
            orderGroups[g].tp2_reached = true;
            Print("   [HIT] TP2 already reached for group ", orderGroups[g].groupId);
        }

        if(orderGroups[g].entry_price > 0)
        {
            RedrawRecoveredGroup(g);
            Print("[OK] Group ", orderGroups[g].groupId, " recovered successfully");
        }
    }

    // Seed the state file from comment-based recovery so future restarts use it.
    SaveGroups();

    Print("");
    Print("==== Split Order Recovery Complete ====");
    Print("[OK] Recovered ", groupCount, " order group(s)");
    Print("=======================================");
}

//+------------------------------------------------------------------+
//| Handle GET_POSITIONS command                                      |
//+------------------------------------------------------------------+
string HandleGetPositions()
{
    string result = "{\"success\":true,\"positions\":[";
    int count = 0;

    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(position.SelectByIndex(i) && position.Magic() == MagicNumber)
        {
            if(count > 0) result += ",";

            ulong ticket = position.Ticket();
            string symbol = position.Symbol();
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)position.Type();
            double volume = position.Volume();
            double openPrice = position.PriceOpen();
            double currentPrice = position.PriceCurrent();
            double sl = position.StopLoss();
            double tp = position.TakeProfit();
            double profit = position.Profit();

            result += StringFormat("{\"ticket\":%d,\"symbol\":\"%s\",\"type\":\"%s\",\"volume\":%.2f,\"open_price\":%.5f,\"current_price\":%.5f,\"sl\":%.5f,\"tp\":%.5f,\"profit\":%.2f}",
                                   ticket, symbol, (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                                   volume, openPrice, currentPrice, sl, tp, profit);
            count++;
        }
    }

    result += "]}";
    return result;
}

//+------------------------------------------------------------------+
//| Handle GET_ORDERS command                                         |
//+------------------------------------------------------------------+
string HandleGetOrders()
{
    string result = "{\"success\":true,\"orders\":[";
    int count = 0;

    for(int i = 0; i < OrdersTotal(); i++)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket > 0 && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
        {
            if(count > 0) result += ",";

            string symbol = OrderGetString(ORDER_SYMBOL);
            ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
            double price = OrderGetDouble(ORDER_PRICE_OPEN);
            double sl = OrderGetDouble(ORDER_SL);
            double tp = OrderGetDouble(ORDER_TP);

            string typeStr = "";
            if(type == ORDER_TYPE_BUY_STOP) typeStr = "BUY_STOP";
            else if(type == ORDER_TYPE_SELL_STOP) typeStr = "SELL_STOP";
            else if(type == ORDER_TYPE_BUY_LIMIT) typeStr = "BUY_LIMIT";
            else if(type == ORDER_TYPE_SELL_LIMIT) typeStr = "SELL_LIMIT";

            result += StringFormat("{\"ticket\":%d,\"symbol\":\"%s\",\"type\":\"%s\",\"volume\":%.2f,\"price\":%.5f,\"sl\":%.5f,\"tp\":%.5f}",
                                   ticket, symbol, typeStr, volume, price, sl, tp);
            count++;
        }
    }

    result += "]}";
    return result;
}

//+------------------------------------------------------------------+
//| Handle DELETE_ORDER command                                       |
//+------------------------------------------------------------------+
string HandleDeleteOrder(string commandJson)
{
    string dataJson = commandJson;
    int dataPos = StringFind(commandJson, "\"data\"");
    if(dataPos >= 0)
    {
        int dataStart = StringFind(commandJson, "{", dataPos);
        if(dataStart >= 0)
        {
            dataJson = StringSubstr(commandJson, dataStart);
        }
    }

    ulong ticket = (ulong)ExtractDouble(dataJson, "ticket");

    if(trade.OrderDelete(ticket))
    {
        Print("[OK] Order #", ticket, " deleted successfully");
        return StringFormat("{\"success\":true,\"message\":\"Order deleted\",\"ticket\":%d}", ticket);
    }
    else
    {
        string error = trade.ResultRetcodeDescription();
        Print("[ERR] Failed to delete order #", ticket, " - ", error);
        return StringFormat("{\"success\":false,\"message\":\"%s\",\"ticket\":%d}", error, ticket);
    }
}

//+------------------------------------------------------------------+
//| Handle CLOSE_POSITION command                                     |
//+------------------------------------------------------------------+
string HandleClosePosition(string commandJson)
{
    string dataJson = commandJson;
    int dataPos = StringFind(commandJson, "\"data\"");
    if(dataPos >= 0)
    {
        int dataStart = StringFind(commandJson, "{", dataPos);
        if(dataStart >= 0)
        {
            dataJson = StringSubstr(commandJson, dataStart);
        }
    }

    ulong ticket = (ulong)ExtractDouble(dataJson, "ticket");

    // Try to extract group ID before closing the position
    string groupId = "";
    if(PositionSelectByTicket(ticket))
    {
        int tpLevel;
        ParseGroupComment(PositionGetString(POSITION_COMMENT), groupId, tpLevel);
    }

    if(trade.PositionClose(ticket))
    {
        Print("[OK] Position #", ticket, " closed successfully");

        // Clean up visual objects if we have the group ID
        if(StringLen(groupId) > 0)
        {
            // Check if all positions in this group are closed
            bool allClosed = true;
            for(int i = 0; i < ArraySize(orderGroups); i++)
            {
                if(orderGroups[i].groupId == groupId)
                {
                    for(int j = 0; j < orderGroups[i].count; j++)
                    {
                        // Alive = still-pending order OR open position; a
                        // pending sibling must block the group cleanup.
                        ulong checkTicket = orderGroups[i].tickets[j];
                        if(checkTicket > 0 && (OrderSelect(checkTicket) || PositionSelectByTicket(checkTicket)))
                        {
                            allClosed = false;
                            break;
                        }
                    }

                    if(allClosed)
                    {
                        RemoveTPObjects(groupId);
                        ArrayRemove(orderGroups, i, 1);
                        g_groupsDirty = true;
                    }
                    break;
                }
            }
        }

        return StringFormat("{\"success\":true,\"message\":\"Position closed\",\"ticket\":%I64u}", ticket);
    }
    else
    {
        string error = trade.ResultRetcodeDescription();
        Print("[ERR] Failed to close position #", ticket, " - ", error);
        return StringFormat("{\"success\":false,\"message\":\"%s\",\"ticket\":%I64u}", error, ticket);
    }
}

//+------------------------------------------------------------------+
//| Handle SAFE_SHUTDOWN command                                      |
//+------------------------------------------------------------------+
string HandleSafeShutdown()
{
    Print("==== Starting Safe Shutdown ====");

    int groupsModified = 0;
    int pendingOrdersModified = 0;
    int openPositionsModified = 0;
    string details = "";

    for(int i = 0; i < ArraySize(orderGroups); i++)
    {
        // Skip groups that already reached TP2 (already protected)
        if(orderGroups[i].tp2_reached)
        {
            Print("[SKIP]  Skipping group ", orderGroups[i].groupId, " - TP2 already reached");
            continue;
        }

        Print("[REC] Processing group: ", orderGroups[i].groupId);

        double entry = orderGroups[i].entry_price;

        // Consolidate remaining TPs to the ACTUAL TP2 price that was placed.
        double tp2Price = orderGroups[i].tp_prices[1];
        if(tp2Price <= 0)
        {
            Print("[WARN]  Skipping group ", orderGroups[i].groupId, " - TP2 price unknown");
            continue;
        }

        int modifiedInGroup = 0;

        // Consolidate levels 2..count (indices 1..count-1) onto TP2's price.
        for(int j = 1; j < orderGroups[i].count; j++)
        {
            ulong ticket = orderGroups[i].tickets[j];
            if(ticket == 0) continue;

            // Check if it's a pending order
            if(OrderSelect(ticket))
            {
                double currentSL = OrderGetDouble(ORDER_SL);

                if(trade.OrderModify(ticket, entry, currentSL, tp2Price, ORDER_TIME_GTC, 0))
                {
                    Print("[OK] Pending order #", ticket, " (TP", j+1, ") modified to TP2: ", tp2Price);
                    pendingOrdersModified++;
                    modifiedInGroup++;
                }
                else
                {
                    Print("[WARN]  Failed to modify pending order #", ticket, ": ", trade.ResultRetcodeDescription());
                }
            }
            // Check if it's an open position
            else if(PositionSelectByTicket(ticket))
            {
                double currentSL = PositionGetDouble(POSITION_SL);

                if(trade.PositionModify(ticket, currentSL, tp2Price))
                {
                    Print("[OK] Open position #", ticket, " (TP", j+1, ") modified to TP2: ", tp2Price);
                    openPositionsModified++;
                    modifiedInGroup++;
                }
                else
                {
                    Print("[WARN]  Failed to modify position #", ticket, ": ", trade.ResultRetcodeDescription());
                }
            }
        }

        if(modifiedInGroup > 0)
        {
            groupsModified++;
            if(StringLen(details) > 0) details += ",";
            details += StringFormat("{\"group\":\"%s\",\"modified\":%d}", orderGroups[i].groupId, modifiedInGroup);
        }
    }

    Print("==== Safe Shutdown Complete ====");
    Print("Groups modified: ", groupsModified);
    Print("Pending orders modified: ", pendingOrdersModified);
    Print("Open positions modified: ", openPositionsModified);

    return StringFormat("{\"success\":true,\"message\":\"Safe shutdown applied\",\"groups_modified\":%d,\"pending_orders_modified\":%d,\"open_positions_modified\":%d,\"details\":[%s]}",
                        groupsModified, pendingOrdersModified, openPositionsModified, details);
}

//+------------------------------------------------------------------+
//| Handle GET_STATS command                                          |
//+------------------------------------------------------------------+
string HandleGetStats()
{
    double balance = account.Balance();
    double equity = account.Equity();
    double margin = account.Margin();
    double freeMargin = account.FreeMargin();
    double profit = account.Profit();

    int totalPositions = 0;
    int totalOrders = 0;

    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(position.SelectByIndex(i) && position.Magic() == MagicNumber)
        {
            totalPositions++;
        }
    }

    for(int i = 0; i < OrdersTotal(); i++)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket > 0 && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
        {
            totalOrders++;
        }
    }

    int trackedGroups = ArraySize(orderGroups);

    return StringFormat("{\"success\":true,\"stats\":{\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,\"free_margin\":%.2f,\"profit\":%.2f,\"total_positions\":%d,\"total_orders\":%d,\"tracked_groups\":%d,\"magic_number\":%d}}",
                        balance, equity, margin, freeMargin, profit, totalPositions, totalOrders, trackedGroups, MagicNumber);
}

//+------------------------------------------------------------------+
//| Build response                                                     |
//+------------------------------------------------------------------+
string BuildResponse(bool success, string message, ulong ticket)
{
    return StringFormat("{\"success\":%s,\"message\":\"%s\",\"ticket\":%I64u}",
                        success ? "true" : "false",
                        message,
                        ticket);
}
//+------------------------------------------------------------------+
