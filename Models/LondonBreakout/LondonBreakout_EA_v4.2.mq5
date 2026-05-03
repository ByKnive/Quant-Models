//+------------------------------------------------------------------+
//|                  LondonBreakout_EA_v4.2.mq5                      |
//|         London Breakout with Consolidation Filter v4.20          |
//|   Universal Instruments | Chart Visuals | DST Auto | Prop Ready  |
//+------------------------------------------------------------------+
//
// CHANGELOG FROM v4.10:
//   [REFACTOR]  DST logic moved to Core/DST.mqh
//               GetCurrentGMTHour(), GetCurrentGMTOffset(),
//               GetNYMidnightTime(), LastSundayOfMonth(),
//               NthSundayOfMonth(), IsUSEasternDST() all removed
//               from EA — replaced with DST_* prefixed calls
//   [REFACTOR]  InstrumentProfile moved to Core/InstrumentProfile.mqh
//               GetInstrumentProfile() → IP_GetProfile()
//               InstrumentTypeName()   → IP_TypeName()
//               EnforceMinStop()       → IP_EnforceMinStop()
//               IsPriceValidForOrder() → IP_IsPriceValidForOrder()
//   [REFACTOR]  Risk management moved to Core/RiskManager.mqh
//               CalcLots()              → RM_CalcLots()
//               NormalizeLots()         → RM_NormalizeLots()
//               IsDailyDrawdownBreached() → RM_IsDailyLimitBreached()
//               CloseAllTrades()        → RM_CloseAllPositions()
//               IsDailyDrawdownBreached handler → RM_HandleDailyLimitBreach()
//   [IMPROVED]  Dashboard DD bar now uses RM_GetDailyDrawdownUsedPct()
//   [IMPROVED]  OnInit prints diagnostics from all three includes
//   [IMPROVED]  Dashboard version label updated to v4.20
//
// CHANGELOG FROM v4.00:
//   [BUG FIX]  GetATR() no longer creates/releases a handle on every
//              call — handle created once in OnInit, released OnDeinit
//   [BUG FIX]  Partial close now uses dedicated partialDone[] bool flag
//              instead of checking ticket value (was never firing)
//   [BUG FIX]  FindPartialRecord() separated from RegisterPosition()
//              — no more double-registration risk
//   [BUG FIX]  Asian range box t1 now anchored to first Asian bar
//              timestamp instead of last closed M15 bar
//   [REMOVED]  RequireCloseBeyondBuffer input — was wired to nothing
//   [CHANGE]   TradeClose_Hour default lowered 20→12 GMT
//
// INSTRUMENT SUPPORT:
//   Forex:   EURUSD, GBPUSD, EURGBP, USDJPY, GBPJPY, AUDUSD
//   Gold:    XAUUSD (auto-scaled pip values)
//   Indices: US100/NAS100, US500/SPX500 (auto-scaled)
//
// OPTIMISATION PARAMETER GRID:
//   IN-SAMPLE PERIOD:  2020.01.01 – 2023.12.31
//   VALIDATION PERIOD: 2024.01.01 – 2025.12.31
//   TIMEFRAME: M15
//   MODELLING: Every tick based on real ticks (preferred)
//
//   OPTIMISE THESE PARAMETERS:
//   MinRangePips_Forex:    10 to 30, step 5
//   MaxRangePips_Forex:    40 to 80, step 10
//   BreakoutBufferPips:    1  to 5,  step 1
//   StopLossBufferPips:    3  to 10, step 1
//   RR_Target:             1.5 to 4.0, step 0.5
//   LondonClose_Hour:      8  to 11, step 1
//   TrailStepPips_Forex:   5  to 25, step 5
//   UsePartialClose:       true / false
//
//   FILTER RESULTS TO:
//     Profit Factor > 1.5
//     Max Drawdown  < 15%
//     Total Trades  > 100 (over 4 years)
//     Consecutive losses < 8
//
//   PAIRS TO TEST (run separately):
//     GBPUSD — primary target, expect best results
//     GBPJPY — higher volatility, wider range filter expected
//     EURUSD — secondary, more stable equity curve
//     AUDUSD — slower mover, tighter range filter
//     USDJPY — range often tight, use MinRange 10-15
//
//+------------------------------------------------------------------+
#property copyright   "Price Action Series — EA #1 v4.20"
#property version     "4.20"
#property strict
#property indicator_chart_window

//+------------------------------------------------------------------+
//| INCLUDES                                                         |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
#include <Core\DST.mqh>
#include <Core\InstrumentProfile.mqh>
#include <Core\RiskManager.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

// --- Session Times (GMT) ---
input group "=== SESSION TIMES (GMT) ==="
input int      AsianStart_Hour        = 0;    // Asian session start (GMT)
input int      AsianEnd_Hour          = 7;    // Asian session end (GMT)
input int      LondonOpen_Hour        = 7;    // Breakout window start (GMT)
input int      LondonClose_Hour       = 9;    // Breakout window end (GMT)
input int      TradeClose_Hour        = 12;   // Force-close all trades (GMT)

// --- DST / Timezone ---
input group "=== TIMEZONE & DST ==="
input bool     AutoDST                = true; // Auto-detect DST (recommended)
input int      GMT_Offset_Winter      = 2;    // Broker GMT offset in winter
input int      GMT_Offset_Summer      = 3;    // Broker GMT offset in summer
input bool     BrokerFollowsEU_DST    = true; // EU rules (last Sun Mar/Oct)
//             Set false for US DST rules (2nd Sun Mar / 1st Sun Nov)

// --- Range Filter ---
input group "=== ASIAN RANGE FILTER ==="
input int      MinRangePips_Forex     = 20;   // Min range (Forex pips — auto-scaled for other instruments)
input int      MaxRangePips_Forex     = 60;   // Max range (Forex pips)
input bool     UseATRRangeFilter      = true; // Also validate range vs ATR
input double   ATR_MinRangeMultiple   = 0.3;  // Range must be > ATR × this
input double   ATR_MaxRangeMultiple   = 1.5;  // Range must be < ATR × this
input int      ATR_Period             = 14;   // ATR period (M15 bars)

// --- Entry ---
input group "=== ENTRY SETTINGS ==="
input int      BreakoutBufferPips_Forex = 2;  // Breakout buffer (Forex pips)
// Note: Entry requires a CLOSED M15 bar beyond the buffer level (iClose[1])

// --- Stop Loss & Take Profit ---
input group "=== STOP LOSS & TAKE PROFIT ==="
input int      StopLossBufferPips_Forex = 5;  // SL buffer beyond opposite range wall (Forex pips)
input double   RR_Target              = 2.0;  // Risk:Reward for fixed TP
input bool     UseFixedTP             = true; // Use fixed RR target as TP
input bool     UsePartialClose        = true; // Close partial position at 1R
input double   PartialClosePct        = 50.0; // % of position to close at 1R
input bool     MoveToBreakeven        = true; // Move SL to BE after partial close

// --- Trailing Stop ---
input group "=== TRAILING STOP ==="
input bool     UseTrailingStop        = true;
input int      TrailActivatePips_Forex= 0;    // Profit required before trail activates (0 = immediate)
input int      TrailStepPips_Forex    = 10;   // Trail step size (Forex pips)

// --- Risk Management ---
input group "=== RISK MANAGEMENT ==="
input double   RiskPercent            = 1.0;  // Risk per trade (% of balance)
input double   MaxDailyLossPercent    = 3.0;  // Max daily loss before EA halts (%)
input int      MaxTradesPerDay        = 2;    // Max entries per day

// --- Chart Visuals ---
input group "=== CHART VISUALS ==="
input bool     ShowAsianRangeBox      = true;
input bool     ShowEntryLevels        = true;
input bool     ShowDashboard          = true;
input color    AsianBoxColor          = clrSteelBlue;
input color    BullBreakColor         = clrLimeGreen;
input color    BearBreakColor         = clrTomato;
input color    DashboardBGColor       = C'20,20,35';
input color    DashboardTextColor     = clrWhite;
input color    DashboardGoodColor     = clrLimeGreen;
input color    DashboardBadColor      = clrTomato;
input int      DashboardX             = 15;
input int      DashboardY             = 30;

// --- Misc ---
input group "=== MISC ==="
input int      MagicNumber            = 20240101;
input string   TradeComment           = "LDN_BO_v4";
input bool     EnableAlerts           = true;
input bool     VerboseLogging         = false;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+

// Instrument profile — populated in OnInit
InstrumentProfile g_profile;

// Scaled price values — derived from pip inputs × profile in OnInit
double   minRangePrice    = 0;
double   maxRangePrice    = 0;
double   breakoutBuffer   = 0;
double   slBuffer         = 0;
double   trailActivate    = 0;
double   trailStep        = 0;

// Session state
double   asianHigh        = 0;
double   asianLow         = 0;
bool     asianRangeSet    = false;    // Range passed validation and is active
bool     asianRangeLocked = false;    // Lock gate — prevents re-processing
int      tradesToday      = 0;
double   dailyStartBalance= 0;
datetime lastBarTime      = 0;
datetime lastNYMidnight   = 0;
datetime asianRangeStart  = 0;        // First Asian bar timestamp for chart box

// Partial close tracking arrays
ulong    partialTickets[50];
int      partialCount     = 0;
bool     partialDone[50];             // true once partial close has fired
bool     breakevenDone[50];

// ATR handle — created once in OnInit, released in OnDeinit
int      g_atrHandle      = INVALID_HANDLE;

// Chart object prefix — used to identify and delete EA objects
string   OBJ_PREFIX       = "LBO_";

//+------------------------------------------------------------------+
//| CONVENIENCE WRAPPERS                                             |
//| Thin wrappers that pass EA inputs into the include functions     |
//| so call sites in the EA stay clean and readable                  |
//+------------------------------------------------------------------+

int GetCurrentGMTHour()
{
   return DST_GetCurrentGMTHour(AutoDST, GMT_Offset_Winter,
                                 GMT_Offset_Summer, BrokerFollowsEU_DST);
}

int GetCurrentGMTOffset()
{
   return DST_GetBrokerGMTOffset(AutoDST, GMT_Offset_Winter,
                                  GMT_Offset_Summer, BrokerFollowsEU_DST);
}

datetime GetNYMidnightTime()
{
   return DST_GetNYMidnightTime();
}

double CalcLots(double slDistance)
{
   return RM_CalcLots(slDistance, RiskPercent, g_profile, _Symbol);
}

double NormalizeLots(double lots)
{
   return RM_NormalizeLots(lots, _Symbol);
}

void CloseAllTrades()
{
   RM_CloseAllPositions(trade, MagicNumber, _Symbol);
}

//+------------------------------------------------------------------+
//| INITIALIZATION                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);

   // Build instrument profile from symbol name
   g_profile = IP_GetProfile(_Symbol);

   // Scale all Forex-pip inputs to this instrument's price terms
   double pm = g_profile.pipMultiplier;
   double ps = g_profile.pipSize;

   minRangePrice  = MinRangePips_Forex        * pm * ps;
   maxRangePrice  = MaxRangePips_Forex        * pm * ps;
   breakoutBuffer = BreakoutBufferPips_Forex  * pm * ps;
   slBuffer       = StopLossBufferPips_Forex  * pm * ps;
   trailActivate  = TrailActivatePips_Forex   * pm * ps;
   trailStep      = TrailStepPips_Forex       * pm * ps;

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastNYMidnight    = GetNYMidnightTime();

   // ATR handle — created once, reused on every bar via GetATR()
   g_atrHandle = iATR(_Symbol, PERIOD_M15, ATR_Period);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR handle — check symbol/period.");
      return(INIT_FAILED);
   }

   // Initialise partial close tracking arrays
   ArrayInitialize(partialTickets, 0);
   ArrayInitialize(partialDone,    false);
   ArrayInitialize(breakevenDone,  false);

   DeleteAllVisuals();

   // --- Diagnostics ---
   Print("=== London Breakout EA v4.20 ===");
   IP_PrintProfile(g_profile, _Symbol);
   DST_PrintDiagnostics(AutoDST, GMT_Offset_Winter, GMT_Offset_Summer, BrokerFollowsEU_DST);
   RM_PrintDiagnostics(dailyStartBalance, MaxDailyLossPercent, RiskPercent, RR_Target);

   Print("Range filter  : [",
         NormalizeDouble(minRangePrice / g_profile.pipSize, 1), " – ",
         NormalizeDouble(maxRangePrice / g_profile.pipSize, 1), "] scaled pips");
   Print("Breakout buf  : ",
         NormalizeDouble(breakoutBuffer / g_profile.pipSize, 1), " pips",
         " | SL buf: ",
         NormalizeDouble(slBuffer / g_profile.pipSize, 1), " pips");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }
   DeleteAllVisuals();
   Print("London Breakout EA v4.20 deinitialized.");
}

//+------------------------------------------------------------------+
//| MAIN TICK                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   // Process on new M15 bar only
   datetime barTime = iTime(_Symbol, PERIOD_M15, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   // --- NY Midnight reset ---
   datetime nyMidnight = GetNYMidnightTime();
   if(nyMidnight != lastNYMidnight)
   {
      lastNYMidnight    = nyMidnight;
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      asianHigh         = 0;
      asianLow          = 0;
      asianRangeStart   = 0;
      asianRangeSet     = false;
      asianRangeLocked  = false;
      tradesToday       = 0;
      partialCount      = 0;
      ArrayInitialize(partialTickets, 0);
      ArrayInitialize(partialDone,    false);
      ArrayInitialize(breakevenDone,  false);
      DeleteAllVisuals();
      if(VerboseLogging) Print("=== NY Midnight reset ===");
   }

   // --- Kill switches ---
   int gmtHour = GetCurrentGMTHour();

   if(RM_IsDailyLimitBreached(dailyStartBalance, MaxDailyLossPercent))
   {
      RM_HandleDailyLimitBreach(trade, MagicNumber, dailyStartBalance,
                                 MaxDailyLossPercent, EnableAlerts, _Symbol);
      return;
   }

   if(gmtHour >= TradeClose_Hour)
   {
      CloseAllTrades();
      return;
   }

   if(tradesToday >= MaxTradesPerDay) return;

   // --- Strategy phases ---
   BuildAsianRange(gmtHour);
   LockAsianRange(gmtHour);

   if(asianRangeSet)
      CheckBreakoutEntry(gmtHour);

   ManageOpenTrades();

   if(ShowDashboard) UpdateDashboard(gmtHour);
}

//+------------------------------------------------------------------+
//| PHASE 1: BUILD ASIAN RANGE                                      |
//+------------------------------------------------------------------+
void BuildAsianRange(int gmtHour)
{
   if(asianRangeLocked) return;

   bool inAsian = (gmtHour >= AsianStart_Hour && gmtHour < AsianEnd_Hour);
   if(!inAsian) return;

   // Capture first bar timestamp for accurate chart box left edge
   if(asianRangeStart == 0)
      asianRangeStart = iTime(_Symbol, PERIOD_M15, 1);

   double h = iHigh(_Symbol, PERIOD_M15, 1);
   double l = iLow (_Symbol, PERIOD_M15, 1);

   if(asianHigh == 0 || h > asianHigh) asianHigh = h;
   if(asianLow  == 0 || l < asianLow)  asianLow  = l;

   if(VerboseLogging)
      Print("Asian building | H:", asianHigh, " L:", asianLow,
            " Range:", NormalizeDouble((asianHigh - asianLow) / g_profile.pipSize, 1),
            " pips | Hour:", gmtHour);
}

//+------------------------------------------------------------------+
//| PHASE 2: LOCK ASIAN RANGE AT LONDON OPEN                        |
//+------------------------------------------------------------------+
void LockAsianRange(int gmtHour)
{
   if(gmtHour < LondonOpen_Hour) return;
   if(asianRangeLocked)          return;
   if(asianHigh == 0 || asianLow == 0) return;

   asianRangeLocked = true; // Lock regardless of validity

   double rangePrice = asianHigh - asianLow;
   double rangePips  = rangePrice / g_profile.pipSize;

   // Price-based filter
   bool rangeValid = (rangePrice >= minRangePrice &&
                      rangePrice <= maxRangePrice);

   // ATR-based filter (optional)
   if(rangeValid && UseATRRangeFilter)
   {
      double atr = GetATR();
      if(atr > 0)
      {
         bool atrValid = (rangePrice >= atr * ATR_MinRangeMultiple &&
                          rangePrice <= atr * ATR_MaxRangeMultiple);
         if(!atrValid)
         {
            Print("Asian Range REJECTED (ATR) | Range: ",
                  NormalizeDouble(rangePips, 1), " pips | ATR: ",
                  NormalizeDouble(atr / g_profile.pipSize, 1), " pips | Required: [",
                  NormalizeDouble(ATR_MinRangeMultiple * atr / g_profile.pipSize, 1), " – ",
                  NormalizeDouble(ATR_MaxRangeMultiple * atr / g_profile.pipSize, 1), "]");
            rangeValid = false;
         }
      }
   }

   if(rangeValid)
   {
      asianRangeSet = true;
      Print("Asian Range LOCKED ✓ | H:", asianHigh,
            " L:", asianLow,
            " | Range:", NormalizeDouble(rangePips, 1), " pips");
      DrawAsianRange();
      DrawEntryLevels();
      if(EnableAlerts)
         Alert(_Symbol, " London BO: Range valid | ",
               NormalizeDouble(rangePips, 1), " pips");
   }
   else
   {
      Print("Asian Range REJECTED | Range: ",
            NormalizeDouble(rangePips, 1), " pips | Filter: [",
            NormalizeDouble(minRangePrice / g_profile.pipSize, 1), " – ",
            NormalizeDouble(maxRangePrice / g_profile.pipSize, 1), "]");
   }
}

//+------------------------------------------------------------------+
//| PHASE 3: CHECK BREAKOUT ENTRY                                   |
//+------------------------------------------------------------------+
void CheckBreakoutEntry(int gmtHour)
{
   if(gmtHour < LondonOpen_Hour || gmtHour >= LondonClose_Hour) return;

   double closePrice = iClose(_Symbol, PERIOD_M15, 1);

   bool bullBreak = (closePrice > asianHigh + breakoutBuffer);
   bool bearBreak = (closePrice < asianLow  - breakoutBuffer);

   if(VerboseLogging && (bullBreak || bearBreak))
      Print("Breakout check | Close:", closePrice,
            " AH:", asianHigh, " AL:", asianLow,
            " Buffer:", breakoutBuffer,
            " Bull:", bullBreak, " Bear:", bearBreak);

   if(bullBreak) ExecuteEntry(true,  closePrice);
   else
   if(bearBreak) ExecuteEntry(false, closePrice);
}

//+------------------------------------------------------------------+
//| EXECUTE ENTRY                                                   |
//+------------------------------------------------------------------+
void ExecuteEntry(bool isBuy, double entryPrice)
{
   double sl, tp, risk, lots;

   if(isBuy)
   {
      sl   = asianLow  - slBuffer;
      risk = entryPrice - sl;
      tp   = UseFixedTP ? entryPrice + risk * RR_Target : 0;
   }
   else
   {
      sl   = asianHigh + slBuffer;
      risk = sl - entryPrice;
      tp   = UseFixedTP ? entryPrice - risk * RR_Target : 0;
   }

   if(risk <= 0)
   {
      Print("ExecuteEntry: Invalid risk (", risk, ") — skipping");
      return;
   }

   // Enforce broker minimum stop distance
   sl   = IP_EnforceMinStop(entryPrice, sl, isBuy, g_profile);
   risk = MathAbs(entryPrice - sl);
   tp   = UseFixedTP ? (isBuy ? entryPrice + risk * RR_Target
                               : entryPrice - risk * RR_Target) : 0;

   // Size position using RM_CalcLots (tick-value based, works all instruments)
   lots = CalcLots(risk);
   if(lots <= 0)
   {
      Print("ExecuteEntry: CalcLots returned 0 — skipping");
      return;
   }

   // Validate price levels before sending order
   if(!IP_IsPriceValidForOrder(entryPrice, sl, tp, isBuy, g_profile))
      return;

   bool success = isBuy
      ? trade.Buy (lots, _Symbol, 0,
                   NormalizeDouble(sl, g_profile.digits),
                   NormalizeDouble(tp, g_profile.digits),
                   TradeComment)
      : trade.Sell(lots, _Symbol, 0,
                   NormalizeDouble(sl, g_profile.digits),
                   NormalizeDouble(tp, g_profile.digits),
                   TradeComment);

   if(success)
   {
      tradesToday++;
      Print((isBuy ? "BUY" : "SELL"),
            " ENTRY | Price:", entryPrice,
            " SL:", NormalizeDouble(sl, g_profile.digits),
            " TP:", NormalizeDouble(tp, g_profile.digits),
            " Risk:", NormalizeDouble(risk / g_profile.pipSize, 1), " pips",
            " Lots:", lots,
            " | Day trades:", tradesToday);
      if(EnableAlerts)
         Alert(_Symbol, isBuy ? " BUY " : " SELL ",
               "| Entry:", entryPrice, " TP:", tp);
   }
   else
   {
      Print("Order FAILED | Error:", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| PHASE 4: MANAGE OPEN TRADES                                     |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                    continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)  continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)      continue;

      double             openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double             sl        = PositionGetDouble(POSITION_SL);
      double             tp        = PositionGetDouble(POSITION_TP);
      double             lots      = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE posType   =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double risk = MathAbs(openPrice - sl);

      // Register before any management — safe to call every bar
      RegisterPosition(ticket);
      int pIdx = FindPartialRecord(ticket);

      // --- Partial close at 1R ---
      if(UsePartialClose && pIdx >= 0 && !partialDone[pIdx] && risk > 0)
      {
         double target1R = (posType == POSITION_TYPE_BUY)
                           ? openPrice + risk
                           : openPrice - risk;
         bool hit1R = (posType == POSITION_TYPE_BUY)
                      ? bid >= target1R
                      : ask <= target1R;

         if(hit1R)
         {
            double closeLots = NormalizeLots(lots * PartialClosePct / 100.0);
            if(closeLots >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
            {
               if(trade.PositionClosePartial(ticket, closeLots))
               {
                  partialDone[pIdx] = true;

                  if(MoveToBreakeven && !breakevenDone[pIdx])
                  {
                     double beSL = (posType == POSITION_TYPE_BUY)
                                   ? openPrice + g_profile.pipSize
                                   : openPrice - g_profile.pipSize;
                     beSL = NormalizeDouble(beSL, g_profile.digits);
                     if(trade.PositionModify(ticket, beSL, tp))
                        breakevenDone[pIdx] = true;
                  }
                  Print("Partial close (", PartialClosePct, "%) at 1R | Ticket:", ticket,
                        " | Lots:", closeLots);
               }
            }
         }
      }

      // --- Trailing stop ---
      if(!UseTrailingStop) continue;

      if(posType == POSITION_TYPE_BUY)
      {
         double profit = bid - openPrice;
         if(profit < trailActivate) continue;
         double newSL  = bid - trailStep;
         if(newSL > sl + g_profile.pipSize)
            trade.PositionModify(ticket,
               NormalizeDouble(newSL, g_profile.digits), tp);
      }
      else
      {
         double profit = openPrice - ask;
         if(profit < trailActivate) continue;
         double newSL  = ask + trailStep;
         if(newSL < sl - g_profile.pipSize)
            trade.PositionModify(ticket,
               NormalizeDouble(newSL, g_profile.digits), tp);
      }
   }
}

//+------------------------------------------------------------------+
//| PARTIAL CLOSE POSITION TRACKING                                 |
//+------------------------------------------------------------------+

// Adds a ticket to tracking arrays if not already registered.
// Safe to call on every bar.
void RegisterPosition(ulong ticket)
{
   if(partialCount >= 49) return;
   for(int i = 0; i < partialCount; i++)
      if(partialTickets[i] == ticket) return;
   partialTickets[partialCount] = ticket;
   partialDone[partialCount]    = false;
   breakevenDone[partialCount]  = false;
   partialCount++;
}

// Returns the array index for a ticket, or -1 if not registered.
// Does NOT register — always call RegisterPosition first.
int FindPartialRecord(ulong ticket)
{
   for(int i = 0; i < partialCount; i++)
      if(partialTickets[i] == ticket) return i;
   return -1;
}

//+------------------------------------------------------------------+
//| ATR HELPER                                                      |
//+------------------------------------------------------------------+
double GetATR()
{
   if(g_atrHandle == INVALID_HANDLE) return 0;
   double buf[1];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) == 1) return buf[0];
   return 0;
}

//+------------------------------------------------------------------+
//| CHART VISUALS — ASIAN RANGE BOX                                |
//+------------------------------------------------------------------+
void DrawAsianRange()
{
   if(!ShowAsianRangeBox) return;

   string   name = OBJ_PREFIX + "AsianBox";
   datetime t1   = (asianRangeStart > 0)
                   ? asianRangeStart
                   : iTime(_Symbol, PERIOD_M15, 1);
   datetime t2   = iTime(_Symbol, PERIOD_M15, 0) + 4 * 3600;

   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, asianHigh, t2, asianLow);
   ObjectSetInteger(0, name, OBJPROP_COLOR,        AsianBoxColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE,        STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,        1);
   ObjectSetInteger(0, name, OBJPROP_BACK,         true);
   ObjectSetInteger(0, name, OBJPROP_FILL,         true);
   ObjectSetDouble (0, name, OBJPROP_TRANSPARENCY, 80);

   string lblH = OBJ_PREFIX + "AsianH";
   if(ObjectFind(0, lblH) >= 0) ObjectDelete(0, lblH);
   ObjectCreate(0, lblH, OBJ_TEXT, 0, t1, asianHigh);
   ObjectSetString (0, lblH, OBJPROP_TEXT,
                    "Asian High: " + DoubleToString(asianHigh, g_profile.digits));
   ObjectSetInteger(0, lblH, OBJPROP_COLOR,    AsianBoxColor);
   ObjectSetInteger(0, lblH, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, lblH, OBJPROP_ANCHOR,   ANCHOR_LEFT_LOWER);

   string lblL = OBJ_PREFIX + "AsianL";
   if(ObjectFind(0, lblL) >= 0) ObjectDelete(0, lblL);
   ObjectCreate(0, lblL, OBJ_TEXT, 0, t1, asianLow);
   ObjectSetString (0, lblL, OBJPROP_TEXT,
                    "Asian Low: " + DoubleToString(asianLow, g_profile.digits));
   ObjectSetInteger(0, lblL, OBJPROP_COLOR,    AsianBoxColor);
   ObjectSetInteger(0, lblL, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, lblL, OBJPROP_ANCHOR,   ANCHOR_LEFT_UPPER);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| CHART VISUALS — ENTRY TRIGGER LEVELS                           |
//+------------------------------------------------------------------+
void DrawEntryLevels()
{
   if(!ShowEntryLevels) return;

   datetime t1 = iTime(_Symbol, PERIOD_M15, 1);
   datetime t2 = t1 + 8 * 3600;

   double bullTrigger = asianHigh + breakoutBuffer;
   string bLine = OBJ_PREFIX + "BullTrigger";
   if(ObjectFind(0, bLine) >= 0) ObjectDelete(0, bLine);
   ObjectCreate(0, bLine, OBJ_TREND, 0, t1, bullTrigger, t2, bullTrigger);
   ObjectSetInteger(0, bLine, OBJPROP_COLOR,     BullBreakColor);
   ObjectSetInteger(0, bLine, OBJPROP_STYLE,     STYLE_DASH);
   ObjectSetInteger(0, bLine, OBJPROP_WIDTH,     1);
   ObjectSetInteger(0, bLine, OBJPROP_RAY_RIGHT, true);

   string bLbl = OBJ_PREFIX + "BullLabel";
   if(ObjectFind(0, bLbl) >= 0) ObjectDelete(0, bLbl);
   ObjectCreate(0, bLbl, OBJ_TEXT, 0, t2, bullTrigger);
   ObjectSetString (0, bLbl, OBJPROP_TEXT,
                    "▲ BUY trigger: " + DoubleToString(bullTrigger, g_profile.digits));
   ObjectSetInteger(0, bLbl, OBJPROP_COLOR,    BullBreakColor);
   ObjectSetInteger(0, bLbl, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, bLbl, OBJPROP_ANCHOR,   ANCHOR_LEFT_LOWER);

   double bearTrigger = asianLow - breakoutBuffer;
   string sLine = OBJ_PREFIX + "BearTrigger";
   if(ObjectFind(0, sLine) >= 0) ObjectDelete(0, sLine);
   ObjectCreate(0, sLine, OBJ_TREND, 0, t1, bearTrigger, t2, bearTrigger);
   ObjectSetInteger(0, sLine, OBJPROP_COLOR,     BearBreakColor);
   ObjectSetInteger(0, sLine, OBJPROP_STYLE,     STYLE_DASH);
   ObjectSetInteger(0, sLine, OBJPROP_WIDTH,     1);
   ObjectSetInteger(0, sLine, OBJPROP_RAY_RIGHT, true);

   string sLbl = OBJ_PREFIX + "BearLabel";
   if(ObjectFind(0, sLbl) >= 0) ObjectDelete(0, sLbl);
   ObjectCreate(0, sLbl, OBJ_TEXT, 0, t2, bearTrigger);
   ObjectSetString (0, sLbl, OBJPROP_TEXT,
                    "▼ SELL trigger: " + DoubleToString(bearTrigger, g_profile.digits));
   ObjectSetInteger(0, sLbl, OBJPROP_COLOR,    BearBreakColor);
   ObjectSetInteger(0, sLbl, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, sLbl, OBJPROP_ANCHOR,   ANCHOR_LEFT_UPPER);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| CHART VISUALS — DASHBOARD PANEL                                |
//+------------------------------------------------------------------+
void UpdateDashboard(int gmtHour)
{
   if(!ShowDashboard) return;

   double dayPnLPct = RM_GetDailyPnLPct(dailyStartBalance);
   double dayPnL    = RM_GetDailyPnL(dailyStartBalance);
   double ddPct     = RM_GetDailyDrawdownUsedPct(dailyStartBalance, MaxDailyLossPercent);
   double rangePips = (asianHigh > 0 && asianLow > 0)
                      ? (asianHigh - asianLow) / g_profile.pipSize : 0;

   string phase;
   color  phaseColor;
   if(!asianRangeLocked)
      { phase = "BUILDING RANGE";  phaseColor = clrGold; }
   else if(!asianRangeSet)
      { phase = "RANGE INVALID";   phaseColor = BearBreakColor; }
   else if(gmtHour < LondonOpen_Hour || gmtHour >= LondonClose_Hour)
      { phase = "WAITING WINDOW";  phaseColor = clrGray; }
   else
      { phase = "WATCHING BREAK";  phaseColor = BullBreakColor; }

   struct DashLine { string text; color col; };
   DashLine lines[12];
   int n = 0;

   lines[n].text = "── LONDON BREAKOUT v4.20 ──"; lines[n++].col = clrGold;
   lines[n].text = _Symbol + " | " + IP_TypeName(g_profile.type);
   lines[n++].col = DashboardTextColor;
   lines[n].text = "Phase: " + phase;                lines[n++].col = phaseColor;
   lines[n].text = "── ASIAN RANGE ──";              lines[n++].col = clrSilver;

   if(asianHigh > 0 && asianLow > 0)
   {
      lines[n].text = "H: " + DoubleToString(asianHigh, g_profile.digits)
                    + "  L: " + DoubleToString(asianLow, g_profile.digits);
      lines[n++].col = AsianBoxColor;

      lines[n].text = "Range: " + DoubleToString(rangePips, 1) + " pips  "
                    + (asianRangeSet ? "✓ VALID" : "✗ INVALID");
      lines[n++].col = asianRangeSet ? DashboardGoodColor : DashboardBadColor;
   }
   else
   {
      lines[n].text = "Not yet built"; lines[n++].col = clrGray;
   }

   lines[n].text = "── TODAY ──"; lines[n++].col = clrSilver;

   lines[n].text = "Trades: " + IntegerToString(tradesToday)
                 + " / " + IntegerToString(MaxTradesPerDay);
   lines[n++].col = (tradesToday >= MaxTradesPerDay)
                    ? DashboardBadColor : DashboardTextColor;

   string pnlSign = (dayPnL >= 0) ? "+" : "";
   lines[n].text = "Day P&L: " + pnlSign + DoubleToString(dayPnLPct, 2) + "%";
   lines[n++].col = (dayPnL >= 0) ? DashboardGoodColor : DashboardBadColor;

   lines[n].text = "DD used: " + DoubleToString(ddPct, 1) + "%"
                 + " of " + DoubleToString(MaxDailyLossPercent, 1) + "% limit";
   color ddColor = (ddPct > 70) ? DashboardBadColor :
                   (ddPct > 40) ? clrGold : DashboardGoodColor;
   lines[n++].col = ddColor;

   lines[n].text = "GMT hour: " + IntegerToString(gmtHour)
                 + "  Offset: +" + IntegerToString(GetCurrentGMTOffset());
   lines[n++].col = clrSilver;

   int lineH = 16;
   for(int i = 0; i < n; i++)
   {
      string oName = OBJ_PREFIX + "Dash_" + IntegerToString(i);

      if(i == 0)
      {
         string bgName = OBJ_PREFIX + "DashBG";
         if(ObjectFind(0, bgName) < 0)
            ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE,   DashboardX - 5);
         ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE,   DashboardY - 5);
         ObjectSetInteger(0, bgName, OBJPROP_XSIZE,       220);
         ObjectSetInteger(0, bgName, OBJPROP_YSIZE,       n * lineH + 10);
         ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR,     DashboardBGColor);
         ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
         ObjectSetInteger(0, bgName, OBJPROP_COLOR,       clrDimGray);
         ObjectSetInteger(0, bgName, OBJPROP_BACK,        false);
      }

      if(ObjectFind(0, oName) < 0)
         ObjectCreate(0, oName, OBJ_LABEL, 0, 0, 0);

      ObjectSetString (0, oName, OBJPROP_TEXT,       lines[i].text);
      ObjectSetInteger(0, oName, OBJPROP_COLOR,      lines[i].col);
      ObjectSetInteger(0, oName, OBJPROP_FONTSIZE,   8);
      ObjectSetString (0, oName, OBJPROP_FONT,       "Consolas");
      ObjectSetInteger(0, oName, OBJPROP_XDISTANCE,  DashboardX);
      ObjectSetInteger(0, oName, OBJPROP_YDISTANCE,  DashboardY + i * lineH);
      ObjectSetInteger(0, oName, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, oName, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, oName, OBJPROP_BACK,       false);
      ObjectSetInteger(0, oName, OBJPROP_SELECTABLE, false);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| DELETE ALL EA VISUAL OBJECTS                                    |
//+------------------------------------------------------------------+
void DeleteAllVisuals()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, OBJ_PREFIX) == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| END OF FILE                                                      |
//+------------------------------------------------------------------+
