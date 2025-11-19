//+------------------------------------------------------------------+
//|                                             bulk-add-signals.mq5 |
//|                                Bulk Signal Processing via TCP    |
//|                                          https://www.mql5.com    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      "https://www.mql5.com"
#property version   "4.00"
#property description "Receives trading signals via TCP sockets (MQL5 as client)"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/AccountInfo.mqh>

//--- Input parameters
input string ServerHost = "127.0.0.1";       // Python server host
input int ServerPort = 5555;                  // Python server port
input int MagicNumber = 20250117;            // Magic number for orders
input double DefaultLotSize = 0.1;           // Default lot size
input int MaxSpreadPips = 10;                // Maximum spread in pips
input int MaxPositions = 10;                 // Maximum open positions
input double MaxDailyLossPercent = 5.0;      // Max daily loss %
input int SocketCheckIntervalMs = 500;       // Socket check interval (ms)
input int SocketTimeout = 3000;              // Socket timeout (ms)

//--- Global variables
CTrade trade;
CPositionInfo position;
CAccountInfo account;

double dailyStartBalance = 0;

//--- Structures
struct TradeCommand {
    string action;
    string order_type;
    string symbol;
    double price;
    double sl;
    double tp_levels[5];
    double lot_size;
    int deviation;
    string comment;
};

struct SplitOrderGroup {
    string groupId;           // Unique identifier for the group (based on entry price + symbol)
    ulong tickets[5];         // Tickets for all 5 split orders
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

    // Store starting balance
    dailyStartBalance = account.Balance();

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
    Print("📡 Connected - Received command: ", StringSubstr(commandJson, 0, MathMin(100, StringLen(commandJson))), "...");

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

    // Extract TP levels
    int tp_start = StringFind(dataJson, "\"tp_levels\"");
    if(tp_start >= 0)
    {
        int arr_start = StringFind(dataJson, "[", tp_start);
        int arr_end = StringFind(dataJson, "]", arr_start);
        string tp_str = StringSubstr(dataJson, arr_start + 1, arr_end - arr_start - 1);

        string tp_values[];
        StringSplit(tp_str, ',', tp_values);
        for(int i = 0; i < MathMin(5, ArraySize(tp_values)); i++)
        {
            // Clean whitespace
            string val = tp_values[i];
            StringTrimLeft(val);
            StringTrimRight(val);
            cmd.tp_levels[i] = StringToDouble(val);
        }
    }

    Print("Parsed command: ", cmd.order_type, " ", cmd.symbol, " @ ", cmd.price, " SL:", cmd.sl, " Lot:", cmd.lot_size);

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

    if(CountOpenPositions() >= MaxPositions)
    {
        Print("ERROR: Max positions reached: ", MaxPositions);
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
//| Execute order - Now splits into 5 separate orders                |
//+------------------------------------------------------------------+
ulong ExecuteOrder(TradeCommand &cmd, string &errorMsg)
{
    // Smart order type detection based on price vs market
    double currentPrice = SymbolInfoDouble(cmd.symbol, SYMBOL_ASK);
    ENUM_ORDER_TYPE orderType;

    if(cmd.order_type == "BUY_STOP")
    {
        // BUY STOP must be above market, BUY LIMIT below market
        orderType = (cmd.price > currentPrice) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_BUY_LIMIT;
    }
    else  // SELL_STOP
    {
        // SELL STOP must be below market, SELL LIMIT above market
        orderType = (cmd.price < currentPrice) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_SELL_LIMIT;
    }

    string orderTypeStr = "";
    if(orderType == ORDER_TYPE_BUY_STOP) orderTypeStr = "BUY_STOP";
    else if(orderType == ORDER_TYPE_BUY_LIMIT) orderTypeStr = "BUY_LIMIT";
    else if(orderType == ORDER_TYPE_SELL_STOP) orderTypeStr = "SELL_STOP";
    else if(orderType == ORDER_TYPE_SELL_LIMIT) orderTypeStr = "SELL_LIMIT";

    Print("Executing ", cmd.order_type, " → ", orderTypeStr, " order on ", cmd.symbol);
    Print("Current price: ", currentPrice, " | Order price: ", cmd.price, " | SL: ", cmd.sl, " | Total Lot: ", cmd.lot_size);
    Print("Will split into 5 orders: TP1=60%, TP2-TP5=10% each");

    // Calculate volume splits
    // TP1: 60% of total volume
    // TP2-TP5: 10% each (remaining 40% split equally)
    double volumes[5];
    volumes[0] = NormalizeDouble(cmd.lot_size * 0.60, 2);  // 60% for TP1
    volumes[1] = NormalizeDouble(cmd.lot_size * 0.10, 2);  // 10% for TP2
    volumes[2] = NormalizeDouble(cmd.lot_size * 0.10, 2);  // 10% for TP3
    volumes[3] = NormalizeDouble(cmd.lot_size * 0.10, 2);  // 10% for TP4
    volumes[4] = NormalizeDouble(cmd.lot_size * 0.10, 2);  // 10% for TP5

    // Create group ID
    string groupId = StringFormat("%s_%.3f_%d", cmd.symbol, cmd.price, (int)TimeLocal());

    // Create split order group
    int groupIndex = ArraySize(orderGroups);
    ArrayResize(orderGroups, groupIndex + 1);
    orderGroups[groupIndex].groupId = groupId;
    orderGroups[groupIndex].tp2_reached = false;
    orderGroups[groupIndex].entry_price = cmd.price;
    orderGroups[groupIndex].symbol = cmd.symbol;
    orderGroups[groupIndex].order_type = orderType;

    // Place 5 separate orders
    int successCount = 0;
    ulong firstTicket = 0;

    for(int i = 0; i < 5; i++)
    {
        string orderComment = StringFormat("%s|GROUP:%s|TP:%d", cmd.comment, groupId, i+1);

        bool success = trade.OrderOpen(
            cmd.symbol,
            orderType,
            volumes[i],
            0,
            cmd.price,
            cmd.sl,
            cmd.tp_levels[i],
            ORDER_TIME_GTC,
            0,
            orderComment
        );

        if(success)
        {
            ulong ticket = trade.ResultOrder();
            orderGroups[groupIndex].tickets[i] = ticket;

            if(firstTicket == 0) firstTicket = ticket;

            Print("✅ Split order ", i+1, "/5 placed - Ticket: ", ticket,
                  " | Vol: ", volumes[i], " | TP", i+1, ": ", cmd.tp_levels[i]);
            successCount++;
        }
        else
        {
            errorMsg = trade.ResultRetcodeDescription();
            Print("❌ Split order ", i+1, "/5 failed - ", errorMsg);
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

    // Draw TP levels on chart (once for the group)
    DrawTPLevels(groupId, cmd.symbol, cmd.price, orderType);

    Print("✅ Order group placed: ", successCount, "/5 orders successful");
    return firstTicket;  // Return first ticket as reference
}


//+------------------------------------------------------------------+
//| Draw TP levels on chart                                           |
//+------------------------------------------------------------------+
void DrawTPLevels(string groupId, string symbol, double entryPrice, ENUM_ORDER_TYPE orderType)
{
    // Calculate TP levels: TP1=15 pips, then +30 pip intervals
    double pipValue = (symbol == "XAGUSD") ? 0.01 : 0.10;  // Silver: 0.01, Gold: 0.10
    int direction = (orderType == ORDER_TYPE_BUY_STOP) ? 1 : -1;

    color levelColors[5] = {clrLime, clrGreen, clrYellow, clrOrange, clrRed};

    string percentages[5] = {"60%", "10%", "10%", "10%", "10%"};

    // TP levels: 15, 45, 75, 105, 135 pips
    int tpPips[5] = {15, 45, 75, 105, 135};

    for(int i = 0; i < 5; i++)
    {
        double tpPrice = entryPrice + (direction * tpPips[i] * pipValue);

        // Create horizontal line
        string lineName = StringFormat("TP%d_Line_%s", i+1, groupId);
        ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, tpPrice);
        ObjectSetInteger(0, lineName, OBJPROP_COLOR, levelColors[i]);
        ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DASH);
        ObjectSetInteger(0, lineName, OBJPROP_BACK, false);
        ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);

        // Create text label
        string labelName = StringFormat("TP%d_Label_%s", i+1, groupId);
        ObjectCreate(0, labelName, OBJ_TEXT, 0, TimeCurrent(), tpPrice);
        ObjectSetString(0, labelName, OBJPROP_TEXT, StringFormat("  TP%d: %.3f (%s)", i+1, tpPrice, percentages[i]));
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
    ObjectSetString(0, labelName, OBJPROP_TEXT, StringFormat("  TP%d: %.3f ✓CLOSED", level, price));

    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Remove all TP objects for a group                                |
//+------------------------------------------------------------------+
void RemoveTPObjects(string groupId)
{
    // Remove TP lines and labels
    for(int i = 1; i <= 5; i++)
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
        // Skip if TP2 trailing already applied for this group
        if(orderGroups[i].tp2_reached)
        {
            continue;
        }

        // Check if TP2 position (ticket index 1) has closed
        ulong tp2_ticket = orderGroups[i].tickets[1];

        if(tp2_ticket == 0) continue;  // Invalid ticket

        // Check if TP2 position no longer exists (was closed by hitting TP)
        if(!PositionSelectByTicket(tp2_ticket))
        {
            // TP2 was hit! Move SL to TP1 for all remaining positions
            Print("🎯 TP2 reached for group ", orderGroups[i].groupId, " - Moving SL to TP1 for all remaining positions");

            double entry = orderGroups[i].entry_price;
            string symbol = orderGroups[i].symbol;
            ENUM_ORDER_TYPE orderType = orderGroups[i].order_type;

            // Calculate TP1 price (15 pips from entry)
            double pipValue = (symbol == "XAGUSD") ? 0.01 : 0.10;  // Silver: 0.01, Gold: 0.10
            int direction = (orderType == ORDER_TYPE_BUY_STOP) ? 1 : -1;
            double newSL = entry + (direction * 15 * pipValue);

            // Update SL for all remaining positions (TP3, TP4, TP5)
            int movedCount = 0;
            for(int j = 2; j < 5; j++)  // Start from index 2 (TP3)
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
                            Print("✅ SL moved to TP1 for position #", ticket, " (TP", j+1, ")");
                            movedCount++;
                        }
                        else
                        {
                            Print("⚠️  Failed to move SL for position #", ticket, ": ", trade.ResultRetcodeDescription());
                        }
                    }
                }
            }

            if(movedCount > 0)
            {
                Print("✅ Trailing SL applied: ", movedCount, " position(s) now have SL at TP1 (", newSL, ")");
            }

            // Mark as TP2 reached
            orderGroups[i].tp2_reached = true;

            // Update visual
            UpdateTPLevelClosed(orderGroups[i].groupId, 2);
        }

        // Clean up group if all positions closed
        bool allClosed = true;
        for(int j = 0; j < 5; j++)
        {
            ulong ticket = orderGroups[i].tickets[j];
            if(ticket > 0 && PositionSelectByTicket(ticket))
            {
                allClosed = false;
                break;
            }
        }

        if(allClosed)
        {
            Print("🏁 All positions closed for group ", orderGroups[i].groupId);
            RemoveTPObjects(orderGroups[i].groupId);
            ArrayRemove(orderGroups, i, 1);
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
//| Check daily loss                                                   |
//+------------------------------------------------------------------+
bool CheckDailyLossLimit()
{
    double loss = dailyStartBalance - account.Balance();
    double lossPercent = (loss / dailyStartBalance) * 100.0;

    return (lossPercent < MaxDailyLossPercent);
}

//+------------------------------------------------------------------+
//| Recover split orders on EA restart                                |
//+------------------------------------------------------------------+
void RecoverSplitOrders()
{
    Print("==== Starting Split Order Recovery ====");

    ArrayResize(orderGroups, 0);  // Clear array first

    int totalPositions = PositionsTotal();
    int totalOrders = OrdersTotal();

    Print("Total open positions found: ", totalPositions);
    Print("Total pending orders found: ", totalOrders);

    // Build a map of group IDs from existing positions/orders
    string groupIds[];
    int groupCount = 0;

    // Scan all positions and orders to find unique group IDs
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(position.SelectByIndex(i) && position.Magic() == MagicNumber)
        {
            string comment = position.Comment();
            int groupPos = StringFind(comment, "|GROUP:");
            if(groupPos >= 0)
            {
                int tpPos = StringFind(comment, "|TP:", groupPos);
                if(tpPos >= 0)
                {
                    string groupId = StringSubstr(comment, groupPos + 7, tpPos - groupPos - 7);

                    // Check if we already have this group
                    bool found = false;
                    for(int j = 0; j < groupCount; j++)
                    {
                        if(groupIds[j] == groupId)
                        {
                            found = true;
                            break;
                        }
                    }

                    if(!found)
                    {
                        ArrayResize(groupIds, groupCount + 1);
                        groupIds[groupCount] = groupId;
                        groupCount++;
                    }
                }
            }
        }
    }

    // Also check pending orders
    for(int i = 0; i < OrdersTotal(); i++)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket > 0 && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
        {
            string comment = OrderGetString(ORDER_COMMENT);
            int groupPos = StringFind(comment, "|GROUP:");
            if(groupPos >= 0)
            {
                int tpPos = StringFind(comment, "|TP:", groupPos);
                if(tpPos >= 0)
                {
                    string groupId = StringSubstr(comment, groupPos + 7, tpPos - groupPos - 7);

                    // Check if we already have this group
                    bool found = false;
                    for(int j = 0; j < groupCount; j++)
                    {
                        if(groupIds[j] == groupId)
                        {
                            found = true;
                            break;
                        }
                    }

                    if(!found)
                    {
                        ArrayResize(groupIds, groupCount + 1);
                        groupIds[groupCount] = groupId;
                        groupCount++;
                    }
                }
            }
        }
    }

    Print("Found ", groupCount, " unique order group(s) to recover");

    // Rebuild each group
    for(int g = 0; g < groupCount; g++)
    {
        string groupId = groupIds[g];
        Print("🔄 Recovering group: ", groupId);

        int groupIndex = ArraySize(orderGroups);
        ArrayResize(orderGroups, groupIndex + 1);

        orderGroups[groupIndex].groupId = groupId;
        orderGroups[groupIndex].tp2_reached = false;

        // Initialize tickets to 0
        for(int t = 0; t < 5; t++)
        {
            orderGroups[groupIndex].tickets[t] = 0;
        }

        // Find all tickets for this group (from positions)
        for(int i = 0; i < PositionsTotal(); i++)
        {
            if(position.SelectByIndex(i) && position.Magic() == MagicNumber)
            {
                string comment = position.Comment();
                if(StringFind(comment, "|GROUP:" + groupId) >= 0)
                {
                    // Extract TP level
                    int tpPos = StringFind(comment, "|TP:");
                    if(tpPos >= 0)
                    {
                        string tpStr = StringSubstr(comment, tpPos + 4, 1);
                        int tpLevel = (int)StringToInteger(tpStr);

                        if(tpLevel >= 1 && tpLevel <= 5)
                        {
                            orderGroups[groupIndex].tickets[tpLevel - 1] = position.Ticket();

                            // Store metadata from first position found
                            if(orderGroups[groupIndex].entry_price == 0)
                            {
                                orderGroups[groupIndex].entry_price = position.PriceOpen();
                                orderGroups[groupIndex].symbol = position.Symbol();
                                ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)position.Type();
                                orderGroups[groupIndex].order_type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
                            }

                            Print("   ✅ Found position TP", tpLevel, " - Ticket #", position.Ticket());
                        }
                    }
                }
            }
        }

        // Find all tickets for this group (from pending orders)
        for(int i = 0; i < OrdersTotal(); i++)
        {
            ulong ticket = OrderGetTicket(i);
            if(ticket > 0 && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
            {
                string comment = OrderGetString(ORDER_COMMENT);
                if(StringFind(comment, "|GROUP:" + groupId) >= 0)
                {
                    // Extract TP level
                    int tpPos = StringFind(comment, "|TP:");
                    if(tpPos >= 0)
                    {
                        string tpStr = StringSubstr(comment, tpPos + 4, 1);
                        int tpLevel = (int)StringToInteger(tpStr);

                        if(tpLevel >= 1 && tpLevel <= 5)
                        {
                            orderGroups[groupIndex].tickets[tpLevel - 1] = ticket;

                            // Store metadata from first order found
                            if(orderGroups[groupIndex].entry_price == 0)
                            {
                                orderGroups[groupIndex].entry_price = OrderGetDouble(ORDER_PRICE_OPEN);
                                orderGroups[groupIndex].symbol = OrderGetString(ORDER_SYMBOL);
                                orderGroups[groupIndex].order_type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
                            }

                            Print("   📋 Found pending order TP", tpLevel, " - Ticket #", ticket);
                        }
                    }
                }
            }
        }

        // Check if TP2 was already hit (TP2 position doesn't exist, but TP3+ do)
        if(orderGroups[groupIndex].tickets[1] == 0 &&
           (orderGroups[groupIndex].tickets[2] > 0 ||
            orderGroups[groupIndex].tickets[3] > 0 ||
            orderGroups[groupIndex].tickets[4] > 0))
        {
            orderGroups[groupIndex].tp2_reached = true;
            Print("   🎯 TP2 already reached for this group");
        }

        // Redraw visuals if we have valid metadata
        if(orderGroups[groupIndex].entry_price > 0)
        {
            DrawTPLevels(groupId, orderGroups[groupIndex].symbol,
                        orderGroups[groupIndex].entry_price,
                        orderGroups[groupIndex].order_type);

            // Mark closed TPs as gray
            for(int t = 0; t < 5; t++)
            {
                if(orderGroups[groupIndex].tickets[t] == 0)
                {
                    UpdateTPLevelClosed(groupId, t + 1);
                }
            }

            Print("✅ Group ", groupId, " recovered successfully");
        }
    }

    Print("");
    Print("==== Split Order Recovery Complete ====");
    Print("✅ Recovered ", groupCount, " order group(s)");
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
        Print("✅ Order #", ticket, " deleted successfully");
        return StringFormat("{\"success\":true,\"message\":\"Order deleted\",\"ticket\":%d}", ticket);
    }
    else
    {
        string error = trade.ResultRetcodeDescription();
        Print("❌ Failed to delete order #", ticket, " - ", error);
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
        string comment = PositionGetString(POSITION_COMMENT);
        int groupPos = StringFind(comment, "|GROUP:");
        if(groupPos >= 0)
        {
            int tpPos = StringFind(comment, "|TP:", groupPos);
            if(tpPos >= 0)
            {
                groupId = StringSubstr(comment, groupPos + 7, tpPos - groupPos - 7);
            }
        }
    }

    if(trade.PositionClose(ticket))
    {
        Print("✅ Position #", ticket, " closed successfully");

        // Clean up visual objects if we have the group ID
        if(StringLen(groupId) > 0)
        {
            // Check if all positions in this group are closed
            bool allClosed = true;
            for(int i = 0; i < ArraySize(orderGroups); i++)
            {
                if(orderGroups[i].groupId == groupId)
                {
                    for(int j = 0; j < 5; j++)
                    {
                        ulong checkTicket = orderGroups[i].tickets[j];
                        if(checkTicket > 0 && PositionSelectByTicket(checkTicket))
                        {
                            allClosed = false;
                            break;
                        }
                    }

                    if(allClosed)
                    {
                        RemoveTPObjects(groupId);
                        ArrayRemove(orderGroups, i, 1);
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
        Print("❌ Failed to close position #", ticket, " - ", error);
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
            Print("⏭️  Skipping group ", orderGroups[i].groupId, " - TP2 already reached");
            continue;
        }

        Print("🔄 Processing group: ", orderGroups[i].groupId);

        double entry = orderGroups[i].entry_price;
        string symbol = orderGroups[i].symbol;
        ENUM_ORDER_TYPE orderType = orderGroups[i].order_type;

        // Calculate TP2 price (45 pips from entry)
        double pipValue = (symbol == "XAGUSD") ? 0.01 : 0.10;  // Silver: 0.01, Gold: 0.10
        int direction = (orderType == ORDER_TYPE_BUY_STOP) ? 1 : -1;
        double tp2Price = entry + (direction * 45 * pipValue);

        int modifiedInGroup = 0;

        // Modify TP2, TP3, TP4, TP5 (indices 1-4)
        for(int j = 1; j < 5; j++)
        {
            ulong ticket = orderGroups[i].tickets[j];
            if(ticket == 0) continue;

            // Check if it's a pending order
            if(OrderSelect(ticket))
            {
                double currentSL = OrderGetDouble(ORDER_SL);

                if(trade.OrderModify(ticket, entry, currentSL, tp2Price, ORDER_TIME_GTC, 0))
                {
                    Print("✅ Pending order #", ticket, " (TP", j+1, ") modified to TP2: ", tp2Price);
                    pendingOrdersModified++;
                    modifiedInGroup++;
                }
                else
                {
                    Print("⚠️  Failed to modify pending order #", ticket, ": ", trade.ResultRetcodeDescription());
                }
            }
            // Check if it's an open position
            else if(PositionSelectByTicket(ticket))
            {
                double currentSL = PositionGetDouble(POSITION_SL);

                if(trade.PositionModify(ticket, currentSL, tp2Price))
                {
                    Print("✅ Open position #", ticket, " (TP", j+1, ") modified to TP2: ", tp2Price);
                    openPositionsModified++;
                    modifiedInGroup++;
                }
                else
                {
                    Print("⚠️  Failed to modify position #", ticket, ": ", trade.ResultRetcodeDescription());
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
