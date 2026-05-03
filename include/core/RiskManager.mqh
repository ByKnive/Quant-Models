//+------------------------------------------------------------------+
//|                       RiskManager.mqh                            |
//|              Risk, Lot Sizing & Drawdown Management             |
//|                                                                  |
//|  Provides percentage-based lot sizing, daily drawdown            |
//|  monitoring, and prop firm-compatible kill switches.             |
//|                                                                  |
//|  DEPENDS ON: Core/InstrumentProfile.mqh                         |
//|                                                                  |
//|  USAGE:                                                          |
//|    #include <Core/InstrumentProfile.mqh>                         |
//|    #include <Core/RiskManager.mqh>                               |
//|                                                                  |
//|    double lots = RM_CalcLots(slPriceDistance, 1.0, g_profile);   |
//|    bool   halt = RM_IsDailyLimitBreached(startBal, 3.0);         |
//|    double pnl  = RM_GetDailyPnL(startBal);                       |
//|                                                                  |
//|  PROP FIRM NOTES:                                                |
//|    FTMO 10k: MaxDailyLoss = 5% of initial balance = $500        |
//|              MaxTotalLoss = 10% of initial balance = $1000       |
//|    The daily loss is measured from the start-of-day equity,      |
//|    not the peak balance — this module anchors to the NY          |
//|    midnight balance passed in by the EA.                         |
//+------------------------------------------------------------------+

#ifndef RISK_MANAGER_MQH
#define RISK_MANAGER_MQH

#include <Core/InstrumentProfile.mqh>

//+------------------------------------------------------------------+
//| Normalise a lot size to broker constraints                        |
//|                                                                  |
//| Snaps to the nearest valid lot step, respects min/max limits.    |
//+------------------------------------------------------------------+
double RM_NormalizeLots(double lots, string symbol = "")
{
   if(symbol == "") symbol = _Symbol;

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(stepLot <= 0) stepLot = 0.01; // Fallback

   // Snap down to nearest valid step
   lots = MathFloor(lots / stepLot) * stepLot;

   // Clamp to broker limits
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Calculate position size from % risk and SL distance              |
//|                                                                  |
//| Parameters:                                                      |
//|   slDistance  — SL distance in price (e.g. 0.0050 = 50 pips)   |
//|   riskPct     — % of account balance to risk (e.g. 1.0 = 1%)    |
//|   p           — instrument profile for the traded symbol         |
//|   symbol      — symbol to size (defaults to _Symbol)             |
//|                                                                  |
//| Returns 0 if sizing is impossible or would exceed account.       |
//+------------------------------------------------------------------+
double RM_CalcLots(double                   slDistance,
                   double                   riskPct,
                   const InstrumentProfile &p,
                   string                   symbol = "")
{
   if(symbol == "") symbol = _Symbol;

   if(slDistance <= 0 || riskPct <= 0)
   {
      Print("RM_CalcLots: Invalid inputs — slDistance:", slDistance,
            " riskPct:", riskPct);
      return 0;
   }

   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount     = accountBalance * riskPct / 100.0;

   // Tick value: value of one tick (SYMBOL_TRADE_TICK_SIZE move) per lot
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0)
   {
      Print("RM_CalcLots: Invalid tick data — tickSize:", tickSize,
            " tickValue:", tickValue);
      return 0;
   }

   // Value of the full SL distance per lot in account currency
   double slValuePerLot = (slDistance / tickSize) * tickValue;

   if(slValuePerLot <= 0)
   {
      Print("RM_CalcLots: SL value per lot is zero or negative");
      return 0;
   }

   double lots = riskAmount / slValuePerLot;

   lots = RM_NormalizeLots(lots, symbol);

   if(lots <= 0)
   {
      Print("RM_CalcLots: Lot size rounded to zero — balance too low",
            " or SL too wide. RiskAmt:", riskAmount,
            " SLValPerLot:", slValuePerLot);
      return 0;
   }

   return lots;
}

//+------------------------------------------------------------------+
//| Get current day's P&L in account currency                        |
//|                                                                  |
//| Uses equity (includes floating P&L) vs the start-of-day         |
//| balance anchor passed in from the EA.                            |
//+------------------------------------------------------------------+
double RM_GetDailyPnL(double startOfDayBalance)
{
   return AccountInfoDouble(ACCOUNT_EQUITY) - startOfDayBalance;
}

//+------------------------------------------------------------------+
//| Get daily P&L as a percentage of start-of-day balance            |
//+------------------------------------------------------------------+
double RM_GetDailyPnLPct(double startOfDayBalance)
{
   if(startOfDayBalance <= 0) return 0;
   return RM_GetDailyPnL(startOfDayBalance) / startOfDayBalance * 100.0;
}

//+------------------------------------------------------------------+
//| Get how much of the daily loss limit has been consumed (0–100%)  |
//|                                                                  |
//| Returns 0 if in profit, 100+ if limit is fully consumed.         |
//+------------------------------------------------------------------+
double RM_GetDailyDrawdownUsedPct(double startOfDayBalance,
                                   double maxDailyLossPct)
{
   double loss    = -RM_GetDailyPnL(startOfDayBalance); // Positive = losing
   double maxLoss = startOfDayBalance * maxDailyLossPct / 100.0;
   if(maxLoss <= 0) return 0;
   return MathMax(0, loss / maxLoss * 100.0);
}

//+------------------------------------------------------------------+
//| Check if daily drawdown limit has been breached                  |
//|                                                                  |
//| Parameters:                                                      |
//|   startOfDayBalance — balance at last NY midnight reset           |
//|   maxDailyLossPct   — maximum allowed daily loss in % (e.g. 3.0) |
//|                                                                  |
//| Returns true when the EA should halt trading for the day.        |
//+------------------------------------------------------------------+
bool RM_IsDailyLimitBreached(double startOfDayBalance,
                              double maxDailyLossPct)
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxLoss = startOfDayBalance * (maxDailyLossPct / 100.0);

   return (startOfDayBalance - equity >= maxLoss);
}

//+------------------------------------------------------------------+
//| Check if total account drawdown limit has been breached          |
//|                                                                  |
//| For prop firms with a total loss limit separate from daily.      |
//| initialBalance — the balance when the challenge started.         |
//+------------------------------------------------------------------+
bool RM_IsTotalLimitBreached(double initialBalance,
                              double maxTotalLossPct)
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxLoss = initialBalance * (maxTotalLossPct / 100.0);

   return (initialBalance - equity >= maxLoss);
}

//+------------------------------------------------------------------+
//| Close all positions for this EA                                  |
//|                                                                  |
//| Requires a CTrade instance passed in by reference.               |
//| Only closes positions matching the given magic number.           |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

void RM_CloseAllPositions(CTrade &trade,
                           long    magicNumber,
                           string  symbol = "")
{
   if(symbol == "") symbol = _Symbol;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                  continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)      continue;

      bool closed = trade.PositionClose(ticket);
      if(closed)
         Print("RM_CloseAllPositions: Closed ticket ", ticket);
      else
         Print("RM_CloseAllPositions: Failed to close ", ticket,
               " | Error: ", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Daily limit breach handler — close all and log                   |
//|                                                                  |
//| Call this when IsDailyLimitBreached() returns true.             |
//| Throttles alerts to once per hour to avoid spam.                 |
//+------------------------------------------------------------------+
void RM_HandleDailyLimitBreach(CTrade  &trade,
                                long     magicNumber,
                                double   startOfDayBalance,
                                double   maxDailyLossPct,
                                bool     enableAlerts,
                                string   symbol = "")
{
   if(symbol == "") symbol = _Symbol;

   static datetime lastAlert = 0;
   if(TimeCurrent() - lastAlert < 3600) return; // Throttle to 1/hour
   lastAlert = TimeCurrent();

   double loss    = startOfDayBalance - AccountInfoDouble(ACCOUNT_EQUITY);
   double pct     = (startOfDayBalance > 0) ? loss / startOfDayBalance * 100.0 : 0;

   Print("!!! DAILY DRAWDOWN LIMIT BREACHED !!!");
   Print("    Loss: -", DoubleToString(pct, 2), "% / limit: ",
         maxDailyLossPct, "%");
   Print("    EA halted for today. Closing all positions.");

   if(enableAlerts)
      Alert(symbol, " | Daily DD limit hit: -",
            DoubleToString(pct, 2), "%");

   RM_CloseAllPositions(trade, magicNumber, symbol);
}

//+------------------------------------------------------------------+
//| Print risk diagnostics to journal                                |
//| Call from OnInit() for verification                              |
//+------------------------------------------------------------------+
void RM_PrintDiagnostics(double startOfDayBalance,
                          double maxDailyLossPct,
                          double riskPct,
                          double rr)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxLoss  = startOfDayBalance * maxDailyLossPct / 100.0;

   Print("=== RiskManager Diagnostics ===");
   Print("  Account balance  : ", balance);
   Print("  Account equity   : ", equity);
   Print("  Day start balance: ", startOfDayBalance);
   Print("  Risk per trade   : ", riskPct, "%  = $",
         NormalizeDouble(balance * riskPct / 100.0, 2));
   Print("  Max daily loss   : ", maxDailyLossPct, "% = $",
         NormalizeDouble(maxLoss, 2));
   Print("  R:R target       : ", rr);
   Print("  Break-even win % : ",
         NormalizeDouble(1.0 / (1.0 + rr) * 100.0, 1), "%");
   Print("===============================");
}

#endif // RISK_MANAGER_MQH
