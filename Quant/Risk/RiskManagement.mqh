//====================================================
// Calculate trade volume based on % risk and SL points
//====================================================
double CalculateRiskVolume(
   string symbol,
   double riskPercent,        // e.g. 0.5 = 0.5%
   double stopLossPoints,     // SL distance in POINTS
   bool   useEquity = false    // true = equity, false = balance
)
{
   if(stopLossPoints <= 0 || riskPercent <= 0)
      return 0.0;

   //--- Account risk money
   double accountValue = useEquity ? 
                          AccountInfoDouble(ACCOUNT_EQUITY) :
                          AccountInfoDouble(ACCOUNT_BALANCE);

   double riskMoney = accountValue * (riskPercent / 100.0);

   //--- Symbol properties
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(tickValue <= 0 || tickSize <= 0)
      return 0.0;

   //--- SL value per 1 lot
   double slPriceDistance = stopLossPoints * point;
   double slValuePerLot   = (slPriceDistance / tickSize) * tickValue;

   if(slValuePerLot <= 0)
      return 0.0;

   //--- Raw volume
   double volume = riskMoney / slValuePerLot;

   //--- Broker limits
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   //--- Normalize volume
   volume = MathFloor(volume / lotStep) * lotStep;
   volume = MathMax(volume, minLot);
   volume = MathMin(volume, maxLot);

   return NormalizeDouble(volume, 2);
}