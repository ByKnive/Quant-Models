//+------------------------------------------------------------------+
//|                      BiasLoggerEA.mq5                            |
//|      Visual daily bias evaluations to CSV for backtesting        |
//+------------------------------------------------------------------+
/*
-++ The Logic ++-

We have Candle 0/1/2

BULL_C = c1_Close > c2_High
   Expect c0_High > c1_High

BEAR_C = c1_Close < c2_Low
   Expect c0_Low < c1_Low
   
BEAR_R = c1_High > c2_High && c1_Close < c2_High
   Expect c0_Low < c2_Low || c0_Low < c1_Low

BULL_R = c1_Low > c2_Low && c1_Close > c2_Low
   Expect c0_High > c2_High || c0_High > c1_High



*/
// Input Variables
input group       "🔍 Visual Debug Tools"
input bool        ShowDebugVisuals = true;


// Global Variables
datetime lastProcessedDay = 0;
string visualMarkerPrefix = "BiasMarker_";
datetime lastDrawnDay = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("Bias Logger Debug initialized.");
   string filename = "BiasDebug_" + _Symbol + "_D1.csv";

   int fileHandle;
   if (!FileIsExist(filename))
   {
      fileHandle = FileOpen(filename, FILE_WRITE | FILE_CSV  | FILE_ANSI);
      if (fileHandle != INVALID_HANDLE)
      {
         FileWrite(fileHandle,
            "LogDate", "Bias Type", "Expected Target", "TargetHit", "TargetLevel", "Symbol",
            "HitTime", "HitSession", "DayOfWeek", "WeekOfMonth",
            "C0High", "C0Low", "C1High", "C1Low", "C2High", "C2Low",
            "C0Range", "C1Range", "C2Range");
         FileClose(fileHandle);
         Print("CSV headers written to new file.");
      }
      else
      {
         Print("Failed to create CSV file for headers.");
      }
   }
   else
   {
      Print("CSV already exists, skipping header write.");
   }

   return INIT_SUCCEEDED;
}


void OnTick()
{
   // Get the time of the last fully closed daily candle (index 1)
   datetime currentDailyCandleTime = iTime(_Symbol, PERIOD_D1, 1);

   // Debug: Print current daily candle time and last processed time
   PrintFormat("OnTick called. Current daily candle time: %s, Last processed: %s",
               TimeToString(currentDailyCandleTime, TIME_DATE | TIME_SECONDS),
               TimeToString(lastProcessedDay, TIME_DATE | TIME_SECONDS));

   // Skip processing if we've already processed this daily candle
   if (currentDailyCandleTime == lastProcessedDay)
   {
      Print("Daily candle not changed, skipping processing.");
      return;
   }

   // New daily candle detected, update lastProcessedDay
   lastProcessedDay = currentDailyCandleTime;
   Print("New daily candle detected, processing logic.");


   // Price data
   double C2_H = iHigh(_Symbol, PERIOD_D1, 3);
   double C2_L  = iLow(_Symbol, PERIOD_D1, 3);
   double C2_C = iClose(_Symbol, PERIOD_D1, 3);
   double C2_O  = iOpen(_Symbol, PERIOD_D1, 3);

   double C1_H = iHigh(_Symbol, PERIOD_D1, 2);
   double C1_L  = iLow(_Symbol, PERIOD_D1, 2);
   double C1_C = iClose(_Symbol, PERIOD_D1, 2);
   double C1_O  = iOpen(_Symbol, PERIOD_D1, 2);

   double C0_H = iHigh(_Symbol, PERIOD_D1, 1);
   double C0_L  = iLow(_Symbol, PERIOD_D1, 1);
   double C0_C  = iClose(_Symbol, PERIOD_D1, 1);
   double C0_O  = iOpen(_Symbol, PERIOD_D1, 1);
   
   // Data Placeholders
   string biasType = "NONE";
   string expectedTarget = "NONE";
   string targetHit = "NO";
   datetime hitTime = 0;
   
   /// Determine bias type and expected target
   if (C1_C > C2_H){
      biasType = "BULL_C";
      expectedTarget = "C1_High";
   }
   else if (C1_C < C2_L){
      biasType = "BEAR_C";
      expectedTarget = "C1_Low";
   }
   else if (C1_H > C2_H && C1_C < C2_H){
      biasType = "BEAR_R";
      expectedTarget = "C2_Low";
   }
   else if (C1_L < C2_L && C1_C > C2_L){
      biasType = "BULL_R";
      expectedTarget = "C2_High";
   }
   else {
      biasType = "NONE";
      expectedTarget = "NONE";
   }
   
   
   double targetLevel = 0.0; // Declare it here so it can be used later
   
   // Check if target was hit
   if (CheckTargetHit(expectedTarget, C1_H, C1_L, C2_H, C2_L, hitTime, targetLevel)){
      targetHit = "YES";
   }

   string hitSession = "NONE";
   if (targetHit == "YES")
   {
      MqlDateTime dt;
      TimeToStruct(hitTime, dt);
      int hour = dt.hour;
   
      if (hour >= 0 && hour < 6)
         hitSession = "Asia";
      else if (hour >= 6 && hour < 12)
         hitSession = "London";
      else if (hour >= 12 && hour < 18)
         hitSession = "New York";
      else
         hitSession = "Post-NY";
   }
   
   
   datetime candle0OpenTime = iTime(_Symbol, PERIOD_D1, 1);
   
   // Prepare other log info
   MqlDateTime logTime;
   TimeToStruct(candle0OpenTime, logTime);
   string dayOfWeek = EnumToString((ENUM_DAY_OF_WEEK)logTime.day_of_week);
   int weekOfMonth = (logTime.day + 6) / 7; // Rough estimate
   
   double pipSize = GetPipSize();  // auto-detect current symbol

   double C0Range = (C0_H - C0_L) / pipSize;
   double C1Range = (C1_H - C1_L) / pipSize;
   double C2Range = (C2_H - C2_L) / pipSize;
   
   // Open and append to file
   string filename = "BiasDebug_" + _Symbol + "_D1.csv";
   int fileHandle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI);
   if (fileHandle != INVALID_HANDLE)
   {
      FileSeek(fileHandle, 0, SEEK_END); // Move to end for appending
   
      FileWrite(fileHandle,
         TimeToString(candle0OpenTime, TIME_DATE), biasType, expectedTarget, targetHit, targetLevel, _Symbol,
         TimeToString(hitTime, TIME_MINUTES), hitSession, dayOfWeek, weekOfMonth,
         C0_H, C0_L, C1_H, C1_L, C2_H, C2_L, C0Range, C1Range, C2Range);

      Print("Logged bias for ", TimeToString(candle0OpenTime, TIME_DATE), ": ", biasType, " → ", expectedTarget, " → ", targetHit);
      FileClose(fileHandle);
   }
   
// Add these at the end of OnTick(), after you calculate the bias & targets

// First delete old markers for the previous draw (if any)
   if(lastDrawnDay != 0 && lastDrawnDay != lastProcessedDay){
      DeleteOldMarkers();
   }
   
   if(ShowDebugVisuals){
   
      // Draw markers for the daily candles checked (C0_H, C0_L, C1_H, C1_L, C2_H, C2_L)
      DrawMarker(iTime(_Symbol, PERIOD_D1, 1), C0_H, "C0_High", clrGreen, OBJ_ARROW_UP); 
      DrawMarker(iTime(_Symbol, PERIOD_D1, 1), C0_L, "C0_Low", clrRed, OBJ_ARROW_DOWN);
      DrawMarker(iTime(_Symbol, PERIOD_D1, 2), C1_H, "C1_High", clrGreen, OBJ_ARROW_UP);
      DrawMarker(iTime(_Symbol, PERIOD_D1, 2), C1_L, "C1_Low", clrRed, OBJ_ARROW_DOWN);
      DrawMarker(iTime(_Symbol, PERIOD_D1, 3), C2_H, "C2_High", clrGreen,OBJ_ARROW_UP);
      DrawMarker(iTime(_Symbol, PERIOD_D1, 3), C2_L, "C2_Low", clrRed, OBJ_ARROW_DOWN);
   
      // Draw marker for expected target level with a different color and label
      if(expectedTarget != "NONE" && targetLevel != 0.0){
         color targetColor = (targetHit == "YES") ? clrPurple : clrPink;
         DrawMarker(candle0OpenTime, targetLevel, "TargetLevel", targetColor, OBJ_ARROWED_LINE);
      }
   
      // Draw bias type text label near C0_H
      string labelName = visualMarkerPrefix + StringReplace(TimeToString(lastProcessedDay, TIME_DATE), "-", "") + "_BiasLabel";
      if(ObjectFind(0, labelName) == -1)
      {
         ObjectCreate(0, labelName, OBJ_TEXT, 0, candle0OpenTime, C0_H + (C0Range * 0.2));
         ObjectSetString(0, labelName, OBJPROP_TEXT, "Bias: " + biasType);
         ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrBlack);
         ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 12);
         ObjectSetInteger(0, labelName, OBJPROP_BACK, true);
      }
   }   
   lastDrawnDay = lastProcessedDay;

}

// Global Functions
bool CheckTargetHit(string expectedTarget, double C1_H, double C1_L, double C2_H, double C2_L, datetime &hitTime, double &targetLevel)
{
   targetLevel = 0.0;

   if(expectedTarget == "C1_High") targetLevel = C1_H;
   else if(expectedTarget == "C1_Low") targetLevel = C1_L;
   else if(expectedTarget == "C2_High") targetLevel = C2_H;
   else if(expectedTarget == "C2_Low") targetLevel = C2_L;

   if (targetLevel == 0.0)
      return false;

   datetime candle0OpenTime  = iTime(_Symbol, PERIOD_D1, 1);
   datetime candle0CloseTime = iTime(_Symbol, PERIOD_D1, 0);

   int startM1 = iBarShift(_Symbol, PERIOD_M1, candle0OpenTime, false);
   int endM1   = iBarShift(_Symbol, PERIOD_M1, candle0CloseTime, false);
   if(startM1 == -1){
      PrintFormat("Could not find M1 start bar for time %s", TimeToString(candle0OpenTime));
      // Try a fallback: shift candle0OpenTime by +60 seconds to find next bar
      startM1 = iBarShift(_Symbol, PERIOD_M1, candle0OpenTime + 60, false);
      if(startM1 == -1){
         Print("Still could not find start M1 bar, exiting target check.");
         return false;
      }
   }

if(endM1 == -1)
{
   PrintFormat("Could not find M1 end bar for time %s", TimeToString(candle0CloseTime));
   // Similar fallback or just set endM1 = 0 (most recent bar)
   endM1 = 0;
}

   Print("startM1 = ", startM1, ", endM1 = ", endM1);
   if(startM1 == -1 || endM1 == -1)
   {
      Print("Error: Could not find M1 bars for the given D1 candle times.");
      return false;
   }
   
   if (startM1 != -1 && endM1 != -1)
   {
      for (int i = startM1; i >= endM1; i--)
      {
         double M1High = iHigh(_Symbol, PERIOD_M1, i);
         double M1Low  = iLow(_Symbol, PERIOD_M1, i);
         datetime M1Time = iTime(_Symbol, PERIOD_M1, i);

         bool broken = false;
         if (expectedTarget == "C1_High" || expectedTarget == "C2_High")
            broken = M1High > targetLevel;
         else if (expectedTarget == "C1_Low" || expectedTarget == "C2_Low")
            broken = M1Low < targetLevel;

         PrintFormat("Bar %d: M1High=%.5f, M1Low=%.5f, Target=%.5f, Broken=%s",
                      i, M1High, M1Low, targetLevel, broken ? "YES" : "NO");
         if (broken)
         {
            hitTime = M1Time;
            return true;
         }
      }
   }
   return false;
}

// Function to delete old markers for the last day drawn
void DeleteOldMarkers(){
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--) {
      string name = ObjectName(0, i);
      if(StringFind(name, visualMarkerPrefix) == 0) { // starts with prefix
         ObjectDelete(0, name);
      }
   }      
}

// Helper function to draw an arrow label at a price and time
void DrawMarker(datetime time, double price, string nameSuffix, color clr, int arrowCode)
{
   string dateStr = TimeToString(lastProcessedDay, TIME_DATE);
   string objName = visualMarkerPrefix + StringReplace(dateStr, "-", "") + "_" + nameSuffix;
   if (ObjectFind(0, objName) == -1)
   {
      ObjectCreate(0, objName, OBJ_ARROW, 0, time, price);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, objName, OBJPROP_ARROWCODE, arrowCode);
      ObjectSetInteger(0, objName, OBJPROP_WIDTH, 2);
   }
   
}  
// Dynamically return pip size per symbol
double GetPipSize(string symbol = NULL)
{
   if(symbol == NULL)
      symbol = _Symbol;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   // Special cases by symbol
   if(StringFind(symbol, "JPY") != -1)  // e.g., USDJPY, EURJPY
      return (digits == 3) ? 0.01 : 0.01;  // JPY pairs: 1 pip = 0.01
   else if(StringFind(symbol, "XAU") != -1 || StringFind(symbol, "GOLD") != -1)  // e.g., XAUUSD
      return 0.1;  // 1 pip = 0.1 for gold
   else if(StringFind(symbol, "XAG") != -1)  // Silver
      return 0.01;
   else if(StringFind(symbol, "US100") != -1 || StringFind(symbol, "NAS") != -1 || StringFind(symbol, "NQ") != -1)
      return 1.0;  // Indices like NASDAQ: 1 pip = 1.0 point
   else if(StringFind(symbol, "US500") != -1 || StringFind(symbol, "SP") != -1)
      return 1.0;
   else if(digits == 5 || digits == 3)
      return _Point * 10.0;  // Most Forex pairs with fractional pips
   else
      return _Point;  // Fallback
}


