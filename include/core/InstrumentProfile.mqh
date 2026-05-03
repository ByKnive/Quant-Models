//+------------------------------------------------------------------+
//|                      InstrumentProfile.mqh                       |
//|              Instrument Detection & Profile Factory              |
//|                                                                  |
//|  Detects instrument type from symbol name and returns a          |
//|  profile struct with pip size, digit count, and scaling          |
//|  multiplier. All downstream pip-based calculations use this      |
//|  so the EA works correctly across Forex, Gold, and Indices       |
//|  without manual adjustment per instrument.                       |
//|                                                                  |
//|  USAGE:                                                          |
//|    #include <Core/InstrumentProfile.mqh>                         |
//|    InstrumentProfile g_profile;                                  |
//|    // In OnInit():                                               |
//|    g_profile = IP_GetProfile(_Symbol);                           |
//|                                                                  |
//|  SUPPORTED INSTRUMENTS:                                          |
//|    Forex standard   EURUSD, GBPUSD, AUDUSD, USDJPY, GBPJPY...   |
//|    Forex JPY cross  GBPJPY, USDJPY, EURJPY, AUDJPY…             |
//|    Gold             XAUUSD (various broker suffixes)             |
//|    Silver           XAGUSD                                       |
//|    Indices          US100, NAS100, US500, SPX500, DE40, UK100…   |
//|    Crypto           BTCUSD, ETHUSD (basic, verify per broker)    |
//+------------------------------------------------------------------+

#ifndef INSTRUMENT_PROFILE_MQH
#define INSTRUMENT_PROFILE_MQH

//+------------------------------------------------------------------+
//| Instrument type enum                                             |
//+------------------------------------------------------------------+
enum ENUM_INSTRUMENT_TYPE
{
   INST_FOREX_STANDARD,   // Standard forex pair (e.g. EURUSD, GBPUSD)
   INST_FOREX_JPY,        // JPY cross (pip = 0.01, not 0.0001)
   INST_GOLD,             // XAUUSD — pip convention ~$0.10
   INST_SILVER,           // XAGUSD
   INST_INDEX,            // Cash indices (US100, DE40, UK100, etc.)
   INST_CRYPTO,           // Crypto (BTCUSD, ETHUSD) — high volatility
   INST_UNKNOWN           // Unrecognised — uses symbol's own point value
};

//+------------------------------------------------------------------+
//| Instrument profile struct                                        |
//+------------------------------------------------------------------+
struct InstrumentProfile
{
   ENUM_INSTRUMENT_TYPE type;

   double   pipSize;        // One pip in price terms
                            //   Forex std : 0.0001
                            //   JPY cross : 0.01
                            //   Gold      : 0.10
                            //   Indices   : 1.0
   double   pipMultiplier;  // Multiplier relative to standard forex pip
                            //   Used to scale forex-pip inputs for this
                            //   instrument so inputs stay in intuitive
                            //   forex-pip units.
                            //   EURUSD → 1.0   XAUUSD → 10.0 (1 pip=0.1)
                            //   US100  → 100.0 (1 forex pip maps to ~1 index pip)
   int      digits;         // Symbol decimal places (mirrors _Digits)
   double   contractSize;   // Lot size in base units (from symbol info)
   double   tickSize;       // Minimum price movement (from symbol info)
   double   tickValue;      // Value per tick per lot in account currency
};

//+------------------------------------------------------------------+
//| String helpers — case-insensitive symbol prefix check            |
//+------------------------------------------------------------------+
bool IP_SymbolContains(string sym, string fragment)
{
   return StringFind(StringUpperCase(sym), StringUpperCase(fragment)) >= 0;
}

bool IP_SymbolStartsWith(string sym, string prefix)
{
   return StringFind(StringUpperCase(sym), StringUpperCase(prefix)) == 0;
}

//+------------------------------------------------------------------+
//| Detect instrument type from symbol name                          |
//+------------------------------------------------------------------+
ENUM_INSTRUMENT_TYPE IP_DetectType(string symbol)
{
   string s = StringUpperCase(symbol);

   // Gold — must check before generic forex to avoid false matches
   if(IP_SymbolContains(s, "XAUUSD") || IP_SymbolContains(s, "GOLD"))
      return INST_GOLD;

   // Silver
   if(IP_SymbolContains(s, "XAGUSD") || IP_SymbolContains(s, "SILVER"))
      return INST_SILVER;

   // Crypto — check before indices to avoid matching BTC in an index name
   if(IP_SymbolContains(s, "BTC") || IP_SymbolContains(s, "ETH") ||
      IP_SymbolContains(s, "LTC") || IP_SymbolContains(s, "XRP"))
      return INST_CRYPTO;

   // Cash indices — check common naming conventions across brokers
   string indexKeywords[] = {
      "US100","NAS100","USTEC","NDX",
      "US500","SPX500","SP500","SPX",
      "US30","DJ30","DOW","DJI",
      "DE40","DAX","GER40","GER30",
      "UK100","FTSE","UKX",
      "JP225","NKY","NIKKEI",
      "EU50","EURO50","SX5E",
      "AUS200","AS51",
      "HK50","HSI",
      "VIX"
   };
   for(int i = 0; i < ArraySize(indexKeywords); i++)
      if(IP_SymbolContains(s, indexKeywords[i]))
         return INST_INDEX;

   // JPY crosses — pip is 0.01 not 0.0001
   string jpyPairs[] = {
      "USDJPY","GBPJPY","EURJPY","AUDJPY",
      "CADJPY","CHFJPY","NZDJPY","SGDJPY",
      "ZARJPY","NOKJPY","SEKJPY","HKDJPY"
   };
   for(int i = 0; i < ArraySize(jpyPairs); i++)
      if(IP_SymbolContains(s, jpyPairs[i]))
         return INST_FOREX_JPY;

   // Standard forex — anything with a recognisable currency pair structure
   // Six-character base check (EURUSD, GBPUSD, etc.)
   string fxBases[] = {
      "EUR","GBP","AUD","NZD","CAD","CHF","USD",
      "NOK","SEK","DKK","SGD","HKD","MXN","ZAR",
      "TRY","PLN","CZK","HUF","RON"
   };
   for(int i = 0; i < ArraySize(fxBases); i++)
      if(IP_SymbolStartsWith(s, fxBases[i]))
         return INST_FOREX_STANDARD;

   // Fallback
   Print("InstrumentProfile: Unrecognised symbol '", symbol,
         "' — using UNKNOWN type with raw symbol info.");
   return INST_UNKNOWN;
}

//+------------------------------------------------------------------+
//| Build profile for a symbol                                       |
//| Call once in OnInit() and store result in a global variable      |
//+------------------------------------------------------------------+
InstrumentProfile IP_GetProfile(string symbol)
{
   InstrumentProfile p;
   p.type         = IP_DetectType(symbol);
   p.digits       = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   p.contractSize = SymbolInfoDouble (symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   p.tickSize     = SymbolInfoDouble (symbol, SYMBOL_TRADE_TICK_SIZE);
   p.tickValue    = SymbolInfoDouble (symbol, SYMBOL_TRADE_TICK_VALUE);

   switch(p.type)
   {
      case INST_FOREX_STANDARD:
         // Standard forex: pip = 0.0001 (or 0.00001 for 5-digit brokers —
         // we normalise to the 4-digit pip convention throughout)
         p.pipSize       = 0.0001;
         p.pipMultiplier = 1.0;
         break;

      case INST_FOREX_JPY:
         // JPY pairs: pip = 0.01 (or 0.001 for 3-digit brokers)
         p.pipSize       = 0.01;
         p.pipMultiplier = 1.0;
         break;

      case INST_GOLD:
         // XAUUSD: conventional pip = $0.10
         // pipMultiplier 10: 1 forex-pip input → 0.0001 × 10 × 0.10 = 0.001
         // Actually gold: 1 "pip" convention is $0.10, so relative to forex:
         // 0.10 / 0.0001 = 1000× but we use a practical multiplier for
         // range inputs. Gold range of "20 pips" (forex input) → 20 × 1.0 × 0.10 = $2.
         // Adjust ATR-based filtering to compensate if needed.
         p.pipSize       = 0.10;
         p.pipMultiplier = 1.0;
         break;

      case INST_SILVER:
         p.pipSize       = 0.01;
         p.pipMultiplier = 1.0;
         break;

      case INST_INDEX:
         // Indices: 1 "pip" = 1 index point (intuitive for traders)
         // pipMultiplier maps forex-pip inputs (e.g. MinRangePips=20) to
         // index points. 1 forex pip × 100 = 100 index points.
         // This keeps range inputs in the same mental model as forex:
         // "20 pips" on EURUSD ≈ "20 points × 5" = 100pts on US100.
         p.pipSize       = 1.0;
         p.pipMultiplier = 5.0;
         break;

      case INST_CRYPTO:
         // Crypto: use symbol's native point as pip — very volatile,
         // inputs will need separate crypto-scaled presets
         p.pipSize       = p.tickSize > 0 ? p.tickSize * 10 : 1.0;
         p.pipMultiplier = 1.0;
         break;

      case INST_UNKNOWN:
      default:
         // Fall back to symbol's own point value
         p.pipSize       = SymbolInfoDouble(symbol, SYMBOL_POINT);
         p.pipMultiplier = 1.0;
         break;
   }

   return p;
}

//+------------------------------------------------------------------+
//| Human-readable instrument type name                              |
//+------------------------------------------------------------------+
string IP_TypeName(ENUM_INSTRUMENT_TYPE type)
{
   switch(type)
   {
      case INST_FOREX_STANDARD: return "Forex";
      case INST_FOREX_JPY:      return "Forex JPY";
      case INST_GOLD:           return "Gold";
      case INST_SILVER:         return "Silver";
      case INST_INDEX:          return "Index";
      case INST_CRYPTO:         return "Crypto";
      default:                  return "Unknown";
   }
}

//+------------------------------------------------------------------+
//| Enforce minimum stop distance required by the broker             |
//|                                                                  |
//| Some brokers impose a minimum distance between entry and SL.     |
//| This function pushes the SL out if it's too close.              |
//|                                                                  |
//| Parameters:                                                      |
//|   entryPrice — intended entry price                             |
//|   sl         — calculated stop loss price                        |
//|   isBuy      — trade direction                                   |
//|   p          — instrument profile                                |
//+------------------------------------------------------------------+
double IP_EnforceMinStop(double entryPrice,
                          double sl,
                          bool   isBuy,
                          const InstrumentProfile &p)
{
   long   minStopPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopPrice  = minStopPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(minStopPrice <= 0) return sl; // Broker has no minimum — return as-is

   double minDist = minStopPrice + p.tickSize; // Add one tick margin

   if(isBuy)
   {
      double minSL = entryPrice - minDist;
      if(sl > minSL) sl = minSL;
   }
   else
   {
      double minSL = entryPrice + minDist;
      if(sl < minSL) sl = minSL;
   }
   return sl;
}

//+------------------------------------------------------------------+
//| Validate that entry/SL/TP are sensible before sending an order   |
//|                                                                  |
//| Returns false and prints a reason if any check fails.           |
//+------------------------------------------------------------------+
bool IP_IsPriceValidForOrder(double entryPrice,
                              double sl,
                              double tp,
                              bool   isBuy,
                              const InstrumentProfile &p)
{
   if(entryPrice <= 0)
   {
      Print("IP_IsPriceValidForOrder: Invalid entry price (", entryPrice, ")");
      return false;
   }

   double slDist = MathAbs(entryPrice - sl);
   if(slDist < p.pipSize)
   {
      Print("IP_IsPriceValidForOrder: SL too close — distance ",
            NormalizeDouble(slDist / p.pipSize, 1), " pips");
      return false;
   }

   // TP direction check
   if(tp > 0)
   {
      if(isBuy  && tp <= entryPrice)
      {
         Print("IP_IsPriceValidForOrder: BUY TP (", tp,
               ") is at or below entry (", entryPrice, ")");
         return false;
      }
      if(!isBuy && tp >= entryPrice)
      {
         Print("IP_IsPriceValidForOrder: SELL TP (", tp,
               ") is at or above entry (", entryPrice, ")");
         return false;
      }
   }

   // SL direction check
   if(isBuy  && sl >= entryPrice)
   {
      Print("IP_IsPriceValidForOrder: BUY SL (", sl,
            ") is at or above entry (", entryPrice, ")");
      return false;
   }
   if(!isBuy && sl <= entryPrice)
   {
      Print("IP_IsPriceValidForOrder: SELL SL (", sl,
            ") is at or below entry (", entryPrice, ")");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Print profile to journal — useful in OnInit() for verification   |
//+------------------------------------------------------------------+
void IP_PrintProfile(const InstrumentProfile &p, string symbol)
{
   Print("=== InstrumentProfile: ", symbol, " ===");
   Print("  Type        : ", IP_TypeName(p.type));
   Print("  Pip size    : ", p.pipSize);
   Print("  Pip mult    : ", p.pipMultiplier);
   Print("  Digits      : ", p.digits);
   Print("  Contract    : ", p.contractSize);
   Print("  Tick size   : ", p.tickSize);
   Print("  Tick value  : ", p.tickValue);
   Print("==========================================");
}

#endif // INSTRUMENT_PROFILE_MQH
