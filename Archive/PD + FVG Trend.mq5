//+------------------------------------------------------------------+
//| PD + FVG Trend (fixed compileable version)                       |
//| - Daily bias update once per D1 bar                               |
//| - FVG detection on M5                                              |
//| - CE-retest entry logic                                             |
//| - Uses CTrade for order placement                                   |
//+------------------------------------------------------------------+
#property copyright "Assistant"
#property version   "1.1"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- INPUTS
input double  InpRiskPercent         = 0.5;      // risk % per trade (percent of account)
input int     InpFVG_MinSpreadMult   = 2;        // FVG min size = mult * spread
input int     InpFVG_MaxAgeCandles   = 3;        // max age in M5 candles
input int     InpCE_RetestMaxCandles = 20;       // max candles to wait for CE retest
input ENUM_TIMEFRAMES InpHTF         = PERIOD_D1; // HTF used for bias
input bool    InpUseSessionFilter    = true;     // only trade during defined session window
input bool    InpAllowLongs          = true;
input bool    InpAllowShorts         = true;
input int     InpMagicNumber         = 20250606;

//--- GLOBAL STRUCTS
struct DailyBiasStruct
{
   double HTFHigh;
   double HTFLow;
   double Equilibrium;
   int    Trend;            // +1 bullish, -1 bearish, 0 neutral
   bool   AllowLongs;
   bool   AllowShorts;
   datetime LastCalculatedBarTime;
};
DailyBiasStruct DailyBias;

struct FVGStruct
{
   bool exists;
   int  startIndex; // oldest candle index of the 3-candle pattern
   int  midIndex;
   int  endIndex;   // most recent of the three
   double high;
   double low;
   datetime detectedTime;
   bool   bullish;  // true if bullish FVG
};
FVGStruct currentFVG;

//--- internal
string OBJ_PREFIX = "M6_";

//+------------------------------------------------------------------+
//| Utility: Current daily bar time                                   |
//+------------------------------------------------------------------+
datetime GetCurrentDailyBarTime()
{
   return(iTime(_Symbol, PERIOD_D1, 0));
}

//+------------------------------------------------------------------+
//| DailyBiasUpdate                                                   |
//+------------------------------------------------------------------+
void DailyBiasUpdate()
{
   datetime curD = GetCurrentDailyBarTime();
   if(curD == DailyBias.LastCalculatedBarTime) return; // already done

   // ensure we have enough bars
   if(iBars(_Symbol, InpHTF) < 5) return;

   // Simple swing detection: highest high and lowest low in recent lookback
   int look = 20;
   double highest = -1.0;
   double lowest  = DBL_MAX;
   int    idxHigh = -1;
   int    idxLow  = -1;

   for(int i=1; i<=look; i++)
   {
      double h = iHigh(_Symbol, InpHTF, i);
      double l = iLow(_Symbol, InpHTF, i);
      if(h > highest) { highest = h; idxHigh = i; }
      if(l < lowest)  { lowest  = l; idxLow  = i; }
   }

   if(idxHigh == -1 || idxLow == -1) return;

   DailyBias.HTFHigh = iHigh(_Symbol, InpHTF, idxHigh);
   DailyBias.HTFLow  = iLow(_Symbol, InpHTF, idxLow);
   DailyBias.Equilibrium = (DailyBias.HTFHigh + DailyBias.HTFLow) / 2.0;

   // Trend: compare latest close to HTF extremes or to previous close
   double lastClose = iClose(_Symbol, InpHTF, 0);
   if(lastClose > DailyBias.HTFHigh) DailyBias.Trend = +1;
   else if(lastClose < DailyBias.HTFLow) DailyBias.Trend = -1;
   else
   {
      double c1 = iClose(_Symbol, InpHTF, 0);
      double c2 = iClose(_Symbol, InpHTF, 1);
      DailyBias.Trend = (c1 > c2) ? +1 : ((c1 < c2) ? -1 : 0);
   }

   // Use HTF open (today's open) to determine premium/discount (use open of current HTF bar)
   double htfOpen = iOpen(_Symbol, InpHTF, 0);
   bool inDiscount = (htfOpen < DailyBias.Equilibrium);
   bool inPremium  = (htfOpen > DailyBias.Equilibrium);

   DailyBias.AllowLongs  = (DailyBias.Trend == +1 && inDiscount && InpAllowLongs);
   DailyBias.AllowShorts = (DailyBias.Trend == -1 && inPremium  && InpAllowShorts);
   DailyBias.LastCalculatedBarTime = curD;

   // Draw EQ line for debug
   DrawEQLine(DailyBias.Equilibrium);

   PrintFormat("[DailyBiasUpdate] Time=%s Trend=%d EQ=%.5f AllowLongs=%d AllowShorts=%d",
               TimeToString(curD, TIME_DATE|TIME_SECONDS), DailyBias.Trend, DailyBias.Equilibrium,
               DailyBias.AllowLongs, DailyBias.AllowShorts);
}

//+------------------------------------------------------------------+
//| FVG detection on M5                                               |
//+------------------------------------------------------------------+
void DetectFVG_M5()
{
   int nowIndex = iBarShift(_Symbol, PERIOD_M5, TimeCurrent(), true);

   // expire old FVG but DO NOT stop scanning
   if(currentFVG.exists)
   {
      int age = nowIndex - currentFVG.endIndex;
      if(age > InpFVG_MaxAgeCandles)
         currentFVG.exists = false;
   }

   // always scan for newest possible FVG
   int lookback = 80;

   for(int i = 3; i < lookback; i++)
   {
      double h1 = iHigh(_Symbol, PERIOD_M5, i);
      double l1 = iLow(_Symbol, PERIOD_M5, i);
      double h3 = iHigh(_Symbol, PERIOD_M5, i-2);
      double l3 = iLow(_Symbol, PERIOD_M5, i-2);

      // bullish FVG
      if(l1 > h3)
      {
         if(IsFVGValid(l1, h3, i-2))
         {
            currentFVG.exists = true;
            currentFVG.startIndex = i;
            currentFVG.midIndex   = i-1;
            currentFVG.endIndex   = i-2;
            currentFVG.high = l1;
            currentFVG.low  = h3;
            currentFVG.detectedTime = iTime(_Symbol, PERIOD_M5, i-2);
            currentFVG.bullish = true;
            DrawFVG(currentFVG);
            return;
         }
      }

      // bearish FVG
      if(h1 < l3)
      {
         if(IsFVGValid(l3, h1, i-2))
         {
            currentFVG.exists = true;
            currentFVG.startIndex = i;
            currentFVG.midIndex   = i-1;
            currentFVG.endIndex   = i-2;
            currentFVG.high = l3;
            currentFVG.low  = h1;
            currentFVG.detectedTime = iTime(_Symbol, PERIOD_M5, i-2);
            currentFVG.bullish = false;
            DrawFVG(currentFVG);
            return;
         }
      }
   }
}


//+------------------------------------------------------------------+
//| Validate FVG                                                      |
//+------------------------------------------------------------------+
bool IsFVGValid(double fvgHigh, double fvgLow, int fvgIndex)
{
   double fvgSize = MathAbs(fvgHigh - fvgLow);

   // Eerst proberen we spread via ASK-BID
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Min grootte check
   if(fvgSize < (InpFVG_MinSpreadMult * spread)) return false;

   // Age check
   int nowIndex = iBarShift(_Symbol, PERIOD_M5, TimeCurrent(), true);
   int age = nowIndex - fvgIndex;
   if(age > InpFVG_MaxAgeCandles) return false;

   return true;
}

//+------------------------------------------------------------------+
//| CE level                                                           |
//+------------------------------------------------------------------+
double GetCELevel(const FVGStruct &fvg)
{
   return (fvg.high + fvg.low) / 2.0;
}

//+------------------------------------------------------------------+
//| Entry engine: wait for CE retest & rejection                      |
//+------------------------------------------------------------------+
void EntryEngine()
{
   if(!currentFVG.exists) return;

   double CE = GetCELevel(currentFVG);

   // allowed by bias?
   if(currentFVG.bullish && !DailyBias.AllowLongs) return;
   if(!currentFVG.bullish && !DailyBias.AllowShorts) return;

   // age
   int nowIndex = iBarShift(_Symbol, PERIOD_M5, TimeCurrent(), true);
   int age = nowIndex - currentFVG.endIndex;
   if(age > InpCE_RetestMaxCandles) return;

   // touch check last 3 bars
   int touchLook = 3;
   bool touched = false;
   for(int i=0;i<touchLook;i++)
   {
      double high = iHigh(_Symbol, PERIOD_M5, i);
      double low  = iLow(_Symbol, PERIOD_M5, i);
      if(low <= CE && CE <= high) { touched = true; break; }
   }
   if(!touched) return;

   // rejection candle on candle 0
   double open0  = iOpen(_Symbol, PERIOD_M5, 0);
   double close0 = iClose(_Symbol, PERIOD_M5, 0);
   double high0  = iHigh(_Symbol, PERIOD_M5, 0);
   double low0   = iLow(_Symbol, PERIOD_M5, 0);

   bool isRejection = false;
   if(currentFVG.bullish)
   {
      if(low0 <= CE && close0 > open0) isRejection = true;
   }
   else
   {
      if(high0 >= CE && close0 < open0) isRejection = true;
   }
   if(!isRejection) return;

   // position sizing
   double stopRef = currentFVG.bullish ? currentFVG.low : currentFVG.high;
   double lot = CalculateLotSizeForRisk(stopRef);
   if(lot <= 0) return;

   // place order using CTrade
   if(currentFVG.bullish)
   {
      double sl = NormalizeDouble(currentFVG.low - 10*_Point, _Digits);
      double tp = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) + (SymbolInfoDouble(_Symbol, SYMBOL_BID) - sl) * 1.0, _Digits);
      trade.SetExpertMagicNumber(InpMagicNumber);
      if(!trade.Buy(lot, NULL, sl, tp, "M6_FVG_BUY"))
         Print("[EntryEngine] Buy failed: ", GetLastError());
      else
         PrintFormat("[EntryEngine] Buy placed lot=%.2f sl=%.5f tp=%.5f", lot, sl, tp);
   }
   else
   {
      double sl = NormalizeDouble(currentFVG.high + 10*_Point, _Digits);
      double tp = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) - (sl - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) * 1.0, _Digits);
      trade.SetExpertMagicNumber(InpMagicNumber);
      if(!trade.Sell(lot, NULL, sl, tp, "M6_FVG_SELL"))
         Print("[EntryEngine] Sell failed: ", GetLastError());
      else
         PrintFormat("[EntryEngine] Sell placed lot=%.2f sl=%.5f tp=%.5f", lot, sl, tp);
   }

   // prevent duplicate entries for this FVG
   currentFVG.exists = false;
}

//+------------------------------------------------------------------+
//| Position sizing                                                   |
//+------------------------------------------------------------------+
double CalculateLotSizeForRisk(double stopReferencePrice)
{
   double riskPercent = InpRiskPercent / 100.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riskPercent;

   double entryPrice = currentFVG.bullish ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopDistance = MathAbs(entryPrice - stopReferencePrice);
   if(stopDistance <= 10*_Point) return 0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double lots = 0.0;
   if(tickValue <= 0 || tickSize <= 0)
   {
      // fallback rough calc (not exact)
      double pipValue = 10; // very rough
      lots = riskMoney / (stopDistance / _Point * pipValue);
   }
   else
   {
      double valuePerPoint = (tickValue / tickSize);
      lots = riskMoney / (stopDistance * valuePerPoint);
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lots < minLot) return 0;
   if(lots > maxLot) lots = maxLot;

   // round to step
   double rounded = MathFloor(lots / lotStep) * lotStep;
   // guard
   if(rounded < minLot) rounded = minLot;
   return(NormalizeDouble(rounded, 2));
}

//+------------------------------------------------------------------+
//| Drawing helpers                                                   |
//+------------------------------------------------------------------+
void DrawEQLine(double eq)
{
   string name = OBJ_PREFIX + "EQ";
   if(ObjectFind(0, name) != -1) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_HLINE, 0, TimeCurrent(), eq);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrSilver);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetString(0, name, OBJPROP_TEXT, "EQ");
}

void DrawFVG(const FVGStruct &fvg)
{
   string name = OBJ_PREFIX + "FVG_" + IntegerToString((int)fvg.detectedTime);
   datetime t1 = iTime(_Symbol, PERIOD_M5, fvg.startIndex);
   datetime t2 = TimeCurrent();
   if(ObjectFind(0, name) != -1) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, fvg.high, t2, fvg.low);
   ObjectSetInteger(0, name, OBJPROP_COLOR, (fvg.bullish? clrGreen : clrRed));
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| Session filter (simple)                                           |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
   int hour = tm.hour;
   if(hour >= 6 && hour <= 20) return true;
   return false;
}

//+------------------------------------------------------------------+
//| OnInit / OnTick                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   currentFVG.exists = false;
   DailyBias.LastCalculatedBarTime = 0;
   Print("PD+FVG Trend fixed EA initialized.");
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   // update bias once per day
   DailyBiasUpdate();

   if(!IsWithinTradingSession()) return;

   // detect FVG
   DetectFVG_M5();

   // entry engine
   EntryEngine();

   // trade management not implemented here (can be added)
}
