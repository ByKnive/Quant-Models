//+------------------------------------------------------------------+
//|                      BiasLoggerEA.mq5                            |
//|      Logs daily bias evaluations to CSV for backtesting          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.01"

datetime lastProcessedDay = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("Bias Logger EA initialized.");
   string filename = "BiasLog_" + _Symbol + "_D1.csv";

   // Create and write column headers if file doesn't exist
   if (!FileIsExist(filename))
   {
      int fileHandle = FileOpen(filename, FILE_CSV | FILE_WRITE | FILE_ANSI);
      if (fileHandle != INVALID_HANDLE)
      {
         FileWrite(fileHandle,
                   "LogDate", "Bias Type", "Expected Target", "ActualHit", "Symbol",
                   "HitTime", "HitSession", "TimeToHitMinutes", "T1Range",
                   "MissedDistance", "BothTargetsHit");
         FileClose(fileHandle);
         Print("CSV file and columns created.");
      }
   }
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime prevD1CloseTime = iTime(_Symbol, PERIOD_D1, 1);
   if (prevD1CloseTime == lastProcessedDay) return;

   // Price data
   double t2High = iHigh(_Symbol, PERIOD_D1, 2);
   double t2Low  = iLow(_Symbol, PERIOD_D1, 2);
   double t2Close = iClose(_Symbol, PERIOD_D1, 2);

   double t1High = iHigh(_Symbol, PERIOD_D1, 1);
   double t1Low  = iLow(_Symbol, PERIOD_D1, 1);
   double t1Close = iClose(_Symbol, PERIOD_D1, 1);

   double t0High = iHigh(_Symbol, PERIOD_D1, 0);
   double t0Low  = iLow(_Symbol, PERIOD_D1, 0);

   string biasType = "NONE";
   string expectedTarget = "NONE";
   string actualHit = "NO";
   datetime hitTime = 0;

   // Determine bias type and expected target
   if (t1Close > t2High)
   {
      biasType = "BULL_CONTINUATION";
      expectedTarget = "T2_HIGH";
   }
   else if (t1Close < t2Low)
   {
      biasType = "BEAR_CONTINUATION";
      expectedTarget = "T2_LOW";
   }
   else if (t1High > t2High && t1Close < t2High)
   {
      biasType = "REVERSAL_FROM_HIGH";
      expectedTarget = "T2_LOW";
   }
   else if (t1Low < t2Low && t1Close > t2Low)
   {
      biasType = "REVERSAL_FROM_LOW";
      expectedTarget = "T2_HIGH";
   }

   // Check actual hit
   if (expectedTarget == "T2_HIGH")
   {
      for (int i = 0; i < iBars(_Symbol, PERIOD_CURRENT); i++)
      {
         datetime barTime = iTime(_Symbol, PERIOD_CURRENT, i);
         if (barTime <= prevD1CloseTime) continue;

         double high = iHigh(_Symbol, PERIOD_CURRENT, i);
         if (high >= t2High)
         {
            actualHit = "YES";
            hitTime = barTime;
            break;
         }
      }
   }
   else if (expectedTarget == "T2_LOW")
   {
      for (int i = 0; i < iBars(_Symbol, PERIOD_CURRENT); i++)
      {
         datetime barTime = iTime(_Symbol, PERIOD_CURRENT, i);
         if (barTime <= prevD1CloseTime) continue;

         double low = iLow(_Symbol, PERIOD_CURRENT, i);
         if (low <= t2Low)
         {
            actualHit = "YES";
            hitTime = barTime;
            break;
         }
      }
   }

   // Compute additional metrics
   string hitTimeStr = "N/A";
   string hitSession = "N/A";
   int timeToHitMinutes = -1;

   if (actualHit == "YES" && hitTime > 0)
   {
      hitTimeStr = TimeToString(hitTime, TIME_MINUTES);
      timeToHitMinutes = (int)((hitTime - prevD1CloseTime) / 60);

      MqlDateTime hitStruct;
      TimeToStruct(hitTime, hitStruct);
      int hour = hitStruct.hour;

      if (hour >= 0 && hour < 7)         hitSession = "Asia";
      else if (hour >= 7 && hour < 13)   hitSession = "London";
      else if (hour >= 13 && hour < 18)  hitSession = "New York Open";
      else                               hitSession = "New York PM";
   }

   // T1 Range in pips (absolute, regardless of direction)
   double t1Range = MathAbs(t1High - t1Low) / _Point;
   if (_Digits == 3 || _Digits == 5)
      t1Range /= 10;  // normalize for fractional pip brokers
   
   // Missed distance in pips (if target was not hit)
   double missedDistance = 0;
   if (actualHit == "NO")
   {
      if (expectedTarget == "T2_HIGH")
         missedDistance = MathAbs(t0High - t2High) / _Point;
      else if (expectedTarget == "T2_LOW")
         missedDistance = MathAbs(t0Low - t2Low) / _Point;
   
      if (_Digits == 3 || _Digits == 5)
         missedDistance /= 10;
   }


   // Check if both targets hit
   bool highHit = false, lowHit = false;
   for (int i = 0; i < iBars(_Symbol, PERIOD_CURRENT); i++)
   {
      datetime barTime = iTime(_Symbol, PERIOD_CURRENT, i);
      if (barTime <= prevD1CloseTime) continue;

      double high = iHigh(_Symbol, PERIOD_CURRENT, i);
      double low = iLow(_Symbol, PERIOD_CURRENT, i);
      if (high >= t2High) highHit = true;
      if (low <= t2Low) lowHit = true;
      if (highHit && lowHit) break;
   }
   string bothTargetsHit = (highHit && lowHit) ? "YES" : "NO";

   // Log everything
   string filename = "BiasLog_" + _Symbol + "_D1.csv";
   int fileHandle = FileOpen(filename, FILE_CSV | FILE_WRITE | FILE_READ | FILE_ANSI | FILE_SHARE_WRITE | FILE_SHARE_READ);

   if (fileHandle != INVALID_HANDLE)
   {
      FileSeek(fileHandle, 0, SEEK_END);
      string logDate = TimeToString(prevD1CloseTime, TIME_DATE);
      FileWrite(fileHandle,
                logDate, biasType, expectedTarget, actualHit, _Symbol,
                hitTimeStr, hitSession, timeToHitMinutes,
                t1Range, missedDistance, bothTargetsHit);
      FileClose(fileHandle);

      Print("Logged bias for ", logDate, ": ", biasType, " → ", expectedTarget, " → ", actualHit);
   }
   else
   {
      Print("Failed to open file for writing.");
   }

   lastProcessedDay = prevD1CloseTime;
}
//+------------------------------------------------------------------+
