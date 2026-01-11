//+------------------------------------------------------------------+
//| Strategy Functionality                                  |
//+------------------------------------------------------------------+
/* The Strategy Explained
Expecting first 90 minute Cycle of London to breakout from the Asia Range in a Continuation pattern.
The steps:
- Get Asia High and Low
- Check Session time for 2:30-4:00am (New York Time)
- Check if Price is Under Asia Low or Above Asia High
- Calculate SL and TP (1:1 Risk-Reward)
- Send Market Order
- Sleep, Reset and Repeat
*/

#include <Trade\Trade.mqh>
#include <Quant\Sessions\SessionsNY.mqh>
#include <Quant\Core\TimeUtils.mqh>
CTrade trade;

input int MagicNumber = 25565;
// Global Variables
double asiaHigh;
double asiaLow;
double asiaRange;
bool sessionCheck = false;
int maxOrders = 2;
int maxPositions = 1;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//---
trade.SetExpertMagicNumber(MagicNumber);
//---

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---
      trade.OrderDelete(0);
      trade.OrderDelete(0);
      trade.PositionClose(_Symbol);
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//---
   // When Time == 2:30am NY Time -> Call Asia Function
   if(GetCurrentNYTime() == StringToTime("02:30:00") && sessionCheck == false){
      Print("Getting Session Data");
      // Get Asia High and Low
      GetAsiaRangeNY(_Symbol,PERIOD_CURRENT,asiaHigh,asiaLow,true);
      Print("Asia High: " + asiaHigh, " ", "Asia Low: " + asiaLow);
      asiaRange = asiaHigh-asiaLow;
      sessionCheck = true;
   }
   if(IsWithinNYTimeWindow(2,30,4,0)){
      Print("Inside Trading Window...");
      // Send Limit Orders
      if(PositionsTotal() < maxPositions && OrdersTotal() == 0){
         trade.BuyLimit(0.1,asiaHigh,_Symbol,asiaLow,asiaHigh+asiaRange);
         trade.SellLimit(0.1,asiaLow,_Symbol,asiaHigh,asiaLow-asiaRange);
        }

      if(PositionsTotal() == 1 && OrdersTotal() != 0){
         trade.OrderDelete(OrderGetTicket(0));
        }
      
   
   }
   else{
      Print("Outside Trading Window. Resetting Booleans.");
      sessionCheck = false;
      trade.OrderDelete(OrderGetTicket(0));
      trade.PositionClose(PositionGetTicket(0));
   }

  }
//+------------------------------------------------------------------+

