//+------------------------------------------------------------------+
//|                           DST.mqh                                |
//|                  Automatic DST Detection                         |
//|                                                                  |
//|  Provides GMT offset calculation for broker time, supporting     |
//|  both EU DST rules (last Sun Mar/Oct) and US DST rules          |
//|  (2nd Sun Mar / 1st Sun Nov). Also provides the true NY          |
//|  midnight anchor used for daily resets.                          |
//|                                                                  |
//|  USAGE:                                                          |
//|    #include <Core/DST.mqh>                                       |
//|    int  offset = DST_GetBrokerGMTOffset(...);                    |
//|    int  hour   = DST_GetCurrentGMTHour(...);                     |
//|    datetime ny = DST_GetNYMidnightTime();                        |
//|                                                                  |
//|  All functions are prefixed DST_ to avoid name collisions        |
//|  when multiple includes are loaded.                              |
//+------------------------------------------------------------------+

#ifndef DST_MQH
#define DST_MQH

//+------------------------------------------------------------------+
//| Last Sunday of a given month — used for EU DST transitions       |
//| Returns the day-of-month (1–31)                                  |
//+------------------------------------------------------------------+
int DST_LastSundayOfMonth(int year, int month)
{
   // Days in each month, accounting for leap years
   int days[] = {31,28,31,30,31,30,31,31,30,31,30,31};
   bool leap  = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
   if(leap) days[1] = 29;

   int last = days[month - 1];

   // Walk backwards from the last day of the month to find Sunday
   MqlDateTime dt;
   dt.year = year; dt.mon = month; dt.day = last;
   dt.hour = 12;   dt.min = 0;    dt.sec = 0;
   datetime d = StructToTime(dt);

   for(int i = 0; i <= 6; i++)
   {
      MqlDateTime c;
      TimeToStruct(d - i * 86400, c);
      if(c.day_of_week == 0) return c.day; // 0 = Sunday
   }
   return last; // Fallback — should never reach
}

//+------------------------------------------------------------------+
//| Nth Sunday of a given month — used for US DST transitions        |
//| n=1 → first Sunday, n=2 → second Sunday, etc.                   |
//| Returns the day-of-month (1–31)                                  |
//+------------------------------------------------------------------+
int DST_NthSundayOfMonth(int year, int month, int n)
{
   MqlDateTime dt;
   dt.year = year; dt.mon = month; dt.day = 1;
   dt.hour = 12;   dt.min = 0;    dt.sec = 0;
   datetime d = StructToTime(dt);

   int count = 0;
   for(int i = 0; i < 31; i++)
   {
      MqlDateTime c;
      TimeToStruct(d + i * 86400, c);
      if(c.mon != month) break;
      if(c.day_of_week == 0)
      {
         count++;
         if(count == n) return c.day;
      }
   }
   return 1; // Fallback
}

//+------------------------------------------------------------------+
//| Check if a given GMT date is within US Eastern DST               |
//| US DST: 2nd Sunday in March → 1st Sunday in November            |
//+------------------------------------------------------------------+
bool DST_IsUSEasternDST(int year, int month, int day)
{
   if(month < 3 || month > 11) return false;
   if(month > 3 && month < 11) return true;

   int dstStart = DST_NthSundayOfMonth(year, 3,  2); // 2nd Sun March
   int dstEnd   = DST_NthSundayOfMonth(year, 11, 1); // 1st Sun November

   if(month == 3  && day >= dstStart) return true;
   if(month == 11 && day <  dstEnd)   return true;
   return false;
}

//+------------------------------------------------------------------+
//| Check if a given GMT date is within EU DST                       |
//| EU DST: Last Sunday in March → Last Sunday in October            |
//+------------------------------------------------------------------+
bool DST_IsEUDST(int year, int month, int day)
{
   if(month < 3 || month > 10) return false;
   if(month > 3 && month < 10) return true;

   int dstStart = DST_LastSundayOfMonth(year, 3);  // Last Sun March
   int dstEnd   = DST_LastSundayOfMonth(year, 10); // Last Sun October

   if(month == 3  && day >= dstStart) return true;
   if(month == 10 && day <  dstEnd)   return true;
   return false;
}

//+------------------------------------------------------------------+
//| Get the current broker GMT offset, with optional DST correction  |
//|                                                                  |
//| Parameters:                                                      |
//|   autoDST         — enable auto DST detection                    |
//|   gmtOffsetWinter — broker offset in winter (no DST)            |
//|   gmtOffsetSummer — broker offset in summer (DST active)        |
//|   brokerFollowsEU — true = EU rules, false = US rules           |
//+------------------------------------------------------------------+
int DST_GetBrokerGMTOffset(bool   autoDST,
                            int    gmtOffsetWinter,
                            int    gmtOffsetSummer,
                            bool   brokerFollowsEU)
{
   if(!autoDST) return gmtOffsetWinter;

   MqlDateTime dtGMT;
   TimeToStruct(TimeGMT(), dtGMT);

   bool inDST = brokerFollowsEU
                ? DST_IsEUDST      (dtGMT.year, dtGMT.mon, dtGMT.day)
                : DST_IsUSEasternDST(dtGMT.year, dtGMT.mon, dtGMT.day);

   return inDST ? gmtOffsetSummer : gmtOffsetWinter;
}

//+------------------------------------------------------------------+
//| Convert broker time to current GMT hour (0–23)                   |
//|                                                                  |
//| Uses TimeCurrent() (broker server time) and removes the broker   |
//| offset so all session logic runs on true GMT regardless of       |
//| broker timezone or DST state.                                    |
//+------------------------------------------------------------------+
int DST_GetCurrentGMTHour(bool autoDST,
                           int  gmtOffsetWinter,
                           int  gmtOffsetSummer,
                           bool brokerFollowsEU)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int offset = DST_GetBrokerGMTOffset(autoDST,
                                        gmtOffsetWinter,
                                        gmtOffsetSummer,
                                        brokerFollowsEU);
   return (dt.hour - offset + 24) % 24;
}

//+------------------------------------------------------------------+
//| Get the timestamp of the most recent NY midnight in GMT           |
//|                                                                  |
//| NY midnight (00:00 EST/EDT) is the true start of the forex       |
//| trading day. Broker D1 candles don't align with this — this      |
//| function gives the correct anchor for daily resets.              |
//|                                                                  |
//| NY midnight in GMT:                                              |
//|   Standard time (EST, UTC-5): 05:00 GMT                          |
//|   Daylight time (EDT, UTC-4): 04:00 GMT                          |
//+------------------------------------------------------------------+
datetime DST_GetNYMidnightTime()
{
   MqlDateTime dtGMT;
   TimeToStruct(TimeGMT(), dtGMT);

   // Is New York currently on EDT (summer)?
   bool edt       = DST_IsUSEasternDST(dtGMT.year, dtGMT.mon, dtGMT.day);
   int  utcOffset = edt ? 4 : 5; // Hours ahead of GMT that NY midnight is

   // Build today's NY midnight in GMT
   MqlDateTime mid;
   mid.year = dtGMT.year;
   mid.mon  = dtGMT.mon;
   mid.day  = dtGMT.day;
   mid.hour = utcOffset;
   mid.min  = 0;
   mid.sec  = 0;
   datetime nyMid = StructToTime(mid);

   // If we haven't reached today's NY midnight yet, use yesterday's
   if(TimeGMT() < nyMid)
      nyMid -= 86400;

   return nyMid;
}

//+------------------------------------------------------------------+
//| Diagnostic: print current DST state to journal                   |
//| Call from OnInit() when debugging timezone issues                |
//+------------------------------------------------------------------+
void DST_PrintDiagnostics(bool autoDST,
                           int  gmtOffsetWinter,
                           int  gmtOffsetSummer,
                           bool brokerFollowsEU)
{
   MqlDateTime dtGMT;
   TimeToStruct(TimeGMT(), dtGMT);

   int    offset    = DST_GetBrokerGMTOffset(autoDST, gmtOffsetWinter,
                                              gmtOffsetSummer, brokerFollowsEU);
   int    gmtHour   = DST_GetCurrentGMTHour(autoDST, gmtOffsetWinter,
                                             gmtOffsetSummer, brokerFollowsEU);
   bool   euDST     = DST_IsEUDST(dtGMT.year, dtGMT.mon, dtGMT.day);
   bool   usDST     = DST_IsUSEasternDST(dtGMT.year, dtGMT.mon, dtGMT.day);
   datetime nyMid   = DST_GetNYMidnightTime();

   Print("=== DST Diagnostics ===");
   Print("Broker time   : ", TimeCurrent());
   Print("GMT time      : ", TimeGMT());
   Print("GMT hour      : ", gmtHour);
   Print("Broker offset : +", offset, "h");
   Print("EU DST active : ", euDST  ? "YES" : "NO");
   Print("US DST active : ", usDST  ? "YES" : "NO");
   Print("Mode          : ", brokerFollowsEU ? "EU rules" : "US rules");
   Print("Auto DST      : ", autoDST ? "ON" : "OFF (winter offset used)");
   Print("NY midnight   : ", nyMid,
         " (", TimeToString(nyMid, TIME_DATE|TIME_MINUTES), " GMT)");
   Print("=======================");
}

#endif // DST_MQH
