//+------------------------------------------------------------------+
//|                        ResultsExporter.mqh                       |
//|          Backtest result export → CSV → Notion bridge            |
//|                                                                  |
//|  USAGE:                                                          |
//|    1. #include this file in your EA                              |
//|    2. Populate a SExportResult struct during the test            |
//|    3. Call ExportResultToCSV() from OnDeinit()                   |
//|                                                                  |
//|  OUTPUT:                                                         |
//|    Writes to MQL5/Files/NotionExport/<strategy>_<symbol>.csv    |
//|    One row appended per optimization pass.                       |
//|    The notion_push.py bridge watches this folder and pushes      |
//|    new rows to your Notion Parameter Sets database.              |
//+------------------------------------------------------------------+

#ifndef RESULTS_EXPORTER_MQH
#define RESULTS_EXPORTER_MQH

//--- Result struct — populate this in your EA, pass to ExportResultToCSV()
struct SExportResult
{
   string   strategyName;     // e.g. "LondonBreakout"
   string   symbol;           // _Symbol
   string   timeframe;        // e.g. "M15"
   string   testPeriodStart;  // e.g. "2023.01.01"
   string   testPeriodEnd;    // e.g. "2023.12.31"
   double   startingBalance;  // Initial deposit
   double   netProfit;        // TesterStatistics(STAT_PROFIT)
   double   profitFactor;     // TesterStatistics(STAT_PROFIT_FACTOR)
   double   maxDrawdownPct;   // TesterStatistics(STAT_EQUITY_DD_RELATIVE) — as percentage
   int      totalTrades;      // TesterStatistics(STAT_TRADES)
   double   winRatePct;       // Win % 0-100
};

//+------------------------------------------------------------------+
//| Auto-populate result struct from MT5 tester statistics           |
//| Call this at the end of a test — all stats are available then    |
//+------------------------------------------------------------------+
void FillResultFromTester(SExportResult &r,
                          string strategyName,
                          double startBalance)
{
   r.strategyName    = strategyName;
   r.symbol          = _Symbol;
   r.startingBalance = startBalance;

   // Timeframe as string
   switch(Period())
   {
      case PERIOD_M1:  r.timeframe = "M1";  break;
      case PERIOD_M5:  r.timeframe = "M5";  break;
      case PERIOD_M15: r.timeframe = "M15"; break;
      case PERIOD_M30: r.timeframe = "M30"; break;
      case PERIOD_H1:  r.timeframe = "H1";  break;
      case PERIOD_H4:  r.timeframe = "H4";  break;
      case PERIOD_D1:  r.timeframe = "D1";  break;
      default:         r.timeframe = "UNK"; break;
   }

   // Tester stats — only valid inside OnDeinit() during a test
   r.netProfit      = TesterStatistics(STAT_PROFIT);
   r.profitFactor   = TesterStatistics(STAT_PROFIT_FACTOR);
   r.maxDrawdownPct = TesterStatistics(STAT_EQUITY_DD_RELATIVE); // already in %
   r.totalTrades    = (int)TesterStatistics(STAT_TRADES);

   double wins      = TesterStatistics(STAT_PROFIT_TRADES);
   r.winRatePct     = (r.totalTrades > 0)
                      ? NormalizeDouble(wins / r.totalTrades * 100.0, 1)
                      : 0.0;

   // Test period from tester date range
   datetime from = (datetime)TesterStatistics(STAT_INITIAL_DEPOSIT); // fallback
   // Note: MT5 doesn't expose test start/end via TesterStatistics directly.
   // Pass them explicitly via EA inputs (TestStart, TestEnd as string inputs)
   // or leave as empty strings — the bridge will use file creation date.
   // r.testPeriodStart and r.testPeriodEnd should be set by the EA before calling.
}

//+------------------------------------------------------------------+
//| Build a short parameter label from EA inputs                     |
//| Override this in your EA for strategy-specific params            |
//| Default: returns a timestamp-based run ID                        |
//+------------------------------------------------------------------+
string BuildParamLabel(string strategyName)
{
   return strategyName + "_" + _Symbol + "_" +
          StringSubstr(TimeToString(TimeCurrent(), TIME_DATE), 0, 10);
}

//+------------------------------------------------------------------+
//| Export result to CSV — call from OnDeinit()                      |
//+------------------------------------------------------------------+
void ExportResultToCSV(SExportResult &r, string paramLabel = "")
{
   // Only fire during Strategy Tester runs
   if(!MQLInfoInteger(MQL_TESTER)) return;

   // Skip passes with no trades — nothing useful to log
   if(r.totalTrades <= 0) return;

   if(paramLabel == "")
      paramLabel = BuildParamLabel(r.strategyName);

   // Output path: MQL5/Files/NotionExport/<StrategyName>_<Symbol>.csv
   string folder   = "NotionExport\\";
   string filename  = folder + r.strategyName + "_" + r.symbol + ".csv";

   // Check if file exists to decide whether to write header
   bool fileExists = (FileIsExist(filename, FILE_COMMON) ||
                      FileIsExist(filename));

   int handle = FileOpen(filename,
                         FILE_WRITE | FILE_READ | FILE_CSV | FILE_ANSI |
                         FILE_SHARE_READ,
                         ',');

   if(handle == INVALID_HANDLE)
   {
      Print("ResultsExporter: Failed to open file: ", filename,
            " Error: ", GetLastError());
      return;
   }

   // Append mode: seek to end of file
   FileSeek(handle, 0, SEEK_END);

   // Write header only for new files
   if(!fileExists)
   {
      FileWrite(handle,
         "param_label",
         "strategy",
         "symbol",
         "timeframe",
         "test_period_start",
         "test_period_end",
         "balance",
         "net_profit",
         "profit_factor",
         "max_dd_pct",
         "trades",
         "win_rate_pct",
         "exported_at"
      );
   }

   // Write data row
   FileWrite(handle,
      paramLabel,
      r.strategyName,
      r.symbol,
      r.timeframe,
      r.testPeriodStart,
      r.testPeriodEnd,
      DoubleToString(r.startingBalance, 2),
      DoubleToString(r.netProfit,       2),
      DoubleToString(r.profitFactor,    4),
      DoubleToString(r.maxDrawdownPct,  2),
      IntegerToString(r.totalTrades),
      DoubleToString(r.winRatePct,      1),
      TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES)
   );

   FileClose(handle);

   Print("ResultsExporter: Row written → ", filename,
         " | PF:", DoubleToString(r.profitFactor, 2),
         " | DD:", DoubleToString(r.maxDrawdownPct, 1), "%",
         " | Trades:", r.totalTrades);
}

#endif // RESULTS_EXPORTER_MQH
