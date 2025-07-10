//+------------------------------------------------------------------+
//| BiasBreak + FVG Reentry Strategy - Debug & Safety Enhanced      |
//| Modular version with visual markers and logging                 |
//+------------------------------------------------------------------+

#include <Trade\Trade.mqh>
CTrade trade;

//--- Input parameters
input double RiskPercent     = 0.5;    // Risk per trade in %
input int    MinStopPips     = 5;      // Minimum stoploss in pips
input color  BullFVGColor    = clrLime;
input color  BearFVGColor    = clrRed;
input color  BiasTargetColor = clrOrange;

//--- Global state
bool     isBullishBias = true;
double   biasTarget    = 0.0;
datetime biasDate      = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   CheckNewDayBias();

   // Dummy example signal check (replace with your FVG logic)
   if(IsNewBar() && entrySignalDetected())
     {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl    = isBullishBias ? entry - 20 * _Point : entry + 20 * _Point;
      double tp    = isBullishBias ? entry + 40 * _Point : entry - 40 * _Point;

      double stopPips = MathAbs(entry - sl) / (_Point * 10);
      if(stopPips < MinStopPips)
        {
         Print("[DEBUG] Skipped trade: SL too tight (", stopPips, " pips)");
         return;
        }

      double lotSize = CalculateLots(entry, sl, RiskPercent);

      DrawFVGBox(isBullishBias, entry - 10 * _Point, entry);
      DrawTradeBox(entry, sl, tp);

      // Submit order (market order example)
      if(isBullishBias)
         trade.Buy(lotSize, _Symbol, entry, sl, tp, "Bias+FVG Buy");
      else
         trade.Sell(lotSize, _Symbol, entry, sl, tp, "Bias+FVG Sell");
     }
  }

//+------------------------------------------------------------------+
//| Check daily bias and draw visuals                                |
//+------------------------------------------------------------------+
void CheckNewDayBias()
  {
   MqlDateTime currentTime, lastBiasTime;
   TimeToStruct(TimeCurrent(), currentTime);
   TimeToStruct(biasDate, lastBiasTime);
   if(currentTime.day != lastBiasTime.day)
     {
      double open  = iOpen(_Symbol, PERIOD_D1, 1);
      double close = iClose(_Symbol, PERIOD_D1, 1);
      isBullishBias = (close > open);
      biasTarget    = isBullishBias ? open + (close - open) * 2 : open - (open - close) * 2;
      biasDate      = TimeCurrent();

      // Print debug info
      Print("[BIAS] ", (isBullishBias ? "Bullish" : "Bearish"), " | Target: ", DoubleToString(biasTarget, _Digits));

      // Draw target line
      string name = "BiasTargetLine";
      ObjectDelete(0, name);
      ObjectCreate(0, name, OBJ_HLINE, 0, TimeCurrent(), biasTarget);
      ObjectSetInteger(0, name, OBJPROP_COLOR, BiasTargetColor);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
     }
  }

//+------------------------------------------------------------------+
//| Calculate lot size                                               |
//+------------------------------------------------------------------+
double CalculateLots(double entry, double sl, double riskPercent)
  {
   double riskPerTrade = AccountInfoDouble(ACCOUNT_BALANCE) * riskPercent / 100.0;
   double stopSize     = MathAbs(entry - sl);
   double tickValue    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   
   if(stopSize <= 0 || tickValue <= 0 || tickSize <= 0 || contractSize <= 0)
      return 0.0;

   double valuePerPoint = tickValue / tickSize;
   double lotSize = riskPerTrade / (stopSize * valuePerPoint / contractSize);
   return NormalizeDouble(lotSize, 2);
  }

//+------------------------------------------------------------------+
//| Draw Fair Value Gap box                                          |
//+------------------------------------------------------------------+
void DrawFVGBox(bool isBull, double low, double high)
  {
   string id = (isBull ? "BullFVG_" : "BearFVG_") + TimeToString(TimeCurrent(), TIME_SECONDS);
   ObjectDelete(0, id);
   ObjectCreate(0, id, OBJ_RECTANGLE, 0, TimeCurrent() - PeriodSeconds(PERIOD_M5), low, TimeCurrent(), high);
   ObjectSetInteger(0, id, OBJPROP_COLOR, isBull ? BullFVGColor : BearFVGColor);
   ObjectSetInteger(0, id, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, id, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, id, OBJPROP_BACK, true);
  }

//+------------------------------------------------------------------+
//| Draw entry, stop, and take profit box                            |
//+------------------------------------------------------------------+
void DrawTradeBox(double entry, double sl, double tp)
  {
   string id = "TradeBox_" + TimeToString(TimeCurrent(), TIME_SECONDS);
   double top    = MathMax(entry, tp);
   double bottom = MathMin(entry, sl);
   ObjectDelete(0, id);
   ObjectCreate(0, id, OBJ_RECTANGLE, 0, TimeCurrent() - PeriodSeconds(PERIOD_M5), bottom, TimeCurrent(), top);
   ObjectSetInteger(0, id, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, id, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, id, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, id, OBJPROP_BACK, true);
  }

//+------------------------------------------------------------------+
//| Dummy signal logic (replace with your real entry logic)          |
//+------------------------------------------------------------------+
bool entrySignalDetected()
  {
   // Replace with your FVG + bias logic
   return true;
  }

//+------------------------------------------------------------------+
//| Detect if new bar opened                                         |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBarTime != lastBarTime)
     {
      lastBarTime = currentBarTime;
      return true;
     }
   return false;
  }
