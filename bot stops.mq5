//+------------------------------------------------------------------+
//|                                            GridTradingEA.mq5     |
//|                                    Copyright 2025, Your Name     |
//|                                             https://www.yoursite |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Your Name"
#property link      "https://www.yoursite"
#property version   "1.98"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- parámetros de entrada (estrategia)
input double InpLotSize               = 0.01;      // Lote base
input int    InpNumberOfOrders        = 11;        // Número de órdenes por lado (rejilla)
input int    InpDistancePoints        = 50;        // Distancia entre órdenes (puntos)
input double InpProfitTarget          = 4.0;       // Profit target (ambas direcciones) en USD
input double InpOneDirectionProfitTarget = 10.0;  // Profit target (una dirección) en USD
input int    InpTrailingStopPoints    = 100;       // Trailing stop (puntos) (0 = desactivado)
input int    InpMagicNumber           = 123456;    // Número mágico
input int    InpMaxExpansionOrders    = 10;        // Máx. órdenes adicionales por lado (0 = desactivado)
input int    InpMaxGrids              = 5;         // Máx. rejillas totales (0 = desactivado)
input bool   InpEnableGridExpansion   = true;      // Activar nuevas rejillas completas
input double InpLotIncrement          = 0.01;      // Incremento de lote por paso
input int    InpLotStep               = 1;         // Cada cuántas rejillas se aplica el incremento
input int    InpCloseOppositeCount    = 0;         // Nº de posiciones contrarias a cerrar por rejilla (0=desactivado)
input double InpCooldownHours         = 2.0;       // Horas de espera tras cerrar todo sin órdenes pendientes o con expansiones en ambos lados
input int    InpMaxTotalPositions     = 0;         // Máx. posiciones totales (0=desactivado)

//--- parámetros de entrada (gestión diaria - drawdown)
input double InpDailyMaxDrawdownPercent = 0.0;     // Drawdown máximo diario en % (ej: 4.5)
input double InpDailyMaxDrawdownMoney   = 0.0;     // Drawdown máximo diario en dinero (ej: 450)
input int    InpDrawdownMode            = 0;       // Modo: 0=%, 1=dinero

//--- parámetros de entrada (gestión diaria - profit)
input int    InpDailyProfitMode         = 0;       // Modo profit: 0=%, 1=dinero
input double InpDailyProfitPercent      = 0.0;     // Profit objetivo diario en % (ej: 2.5)
input double InpDailyProfitMoney        = 0.0;     // Profit objetivo diario en dinero (ej: 200)

//--- parámetros de entrada (sesiones de mercado)
input bool InpTradeTokyo   = false;    // Operar en sesión Tokio (00:00-08:00 UTC)
input bool InpTradeLondon  = true;     // Operar en sesión Londres (08:00-16:00 UTC)
input bool InpTradeNewYork = true;     // Operar en sesión Nueva York (13:00-21:00 UTC)
input bool InpTradeAsia    = false;    // Operar en sesión Asia (21:00-05:00 UTC)
input int  InpTimeZoneOffset = 0;      // Desfase horario del servidor (UTC+/-)

//--- parámetros de entrada (panel visual)
input color InpColorTitle    = clrWhite;
input color InpColorLabels   = clrLightGray;
input color InpColorValues   = clrLime;
input int   InpFontSizeTitle = 12;
input int   InpFontSizeLabels= 10;
input int   InpFontSizeValues= 10;
input int   InpPanelMarginRight = 10;
input int   InpPanelWidth    = 280;
input int   InpPanelSeparation = 120;

//--- estructura para almacenar el estado de cada rejilla
struct GridState
{
   int gridId;
   double lastBuyStopPrice;
   double lastSellStopPrice;
   int buyExpansionCount;
   int sellExpansionCount;
   int retryCount;
   bool isDisabled;
};

//--- variables globales
CTrade trade;
double accumulatedProfit = 0.0;
double closedLossAccumulator = 0.0;
double totalCommissions = 0.0;
double maxDrawdown = 0.0;
double maxEquity = 0.0;
bool trailingEnabled = true;
bool panelCreated = false;
bool gridPlaced = false;
int  timerSeconds = 1;

//--- variables para rejillas
int gridCounter = 1;
double lastBuyGridPrice = 0.0;
double lastSellGridPrice = 0.0;
int buyGridActivationCount = 0;
int sellGridActivationCount = 0;

//--- variables para drawdown diario
double dailyMaxEquity = 0.0;
bool dailyDrawdownReached = false;
datetime lastDayCheck = 0;
double dailyDrawdownLimit = 0.0;
bool dailyDrawdownEnabled = false;

//--- variables para profit diario
double dailyStartEquity = 0.0;
bool dailyProfitReached = false;
double dailyProfitTarget = 0.0;
bool dailyProfitEnabled = false;

//--- contadores de límites diarios alcanzados
int dailyProfitCount = 0;
int dailyDrawdownCount = 0;

//--- variables para cooldown
bool cooldownActive = false;
datetime cooldownEndTime = 0;

//--- variable para profit de cierre por límite de posiciones
double lastMaxPositionsProfit = 0.0;

//--- Array de estados por rejilla
GridState gridStates[];

//+------------------------------------------------------------------+
//| Retorna true si el símbolo coincide (ignora sufijos)             |
//+------------------------------------------------------------------+
bool IsMySymbol(string symbol)
{
   return StringFind(symbol, _Symbol) != -1;
}

//+------------------------------------------------------------------+
//| Calcula el lote para una rejilla según su número                 |
//+------------------------------------------------------------------+
double CalculateLotForGrid(int gridNumber)
{
   if(gridNumber <= 1)
      return InpLotSize;
   
   int steps = (gridNumber - 1) / InpLotStep;
   double lot = InpLotSize + steps * InpLotIncrement;
   lot = MathRound(lot * 100) / 100.0;
   if(lot < 0.01)
      lot = 0.01;
   return lot;
}

//+------------------------------------------------------------------+
//| Ajusta el precio para cumplir con la distancia mínima de stops   |
//+------------------------------------------------------------------+
double AdjustPriceForStops(double price, double basePrice, bool isBuy)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double minDist = MathMax(stopsLevel, 20 * point);
   
   if(isBuy)
   {
      if(price <= basePrice + minDist)
         price = basePrice + minDist;
   }
   else
   {
      if(price >= basePrice - minDist)
         price = basePrice - minDist;
   }
   return price;
}

//+------------------------------------------------------------------+
//| Actualiza el acumulador de comisiones de posiciones abiertas     |
//+------------------------------------------------------------------+
void UpdateCommissionsAccumulator()
{
   totalCommissions = 0.0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            totalCommissions += PositionGetDouble(POSITION_COMMISSION);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Verifica si hay órdenes o posiciones de expansión de un lado     |
//+------------------------------------------------------------------+
bool HasExpansionOrdersOrPositions(string side)
{
   string prefix = (side == "Buy") ? "ExpBuy" : "ExpSell";
   int totalOrders = OrdersTotal();
   for(int i = 0; i < totalOrders; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            string comment = OrderGetString(ORDER_COMMENT);
            if(StringFind(comment, prefix) != -1)
               return true;
         }
      }
   }
   int totalPos = PositionsTotal();
   for(int i = 0; i < totalPos; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            string comment = PositionGetString(POSITION_COMMENT);
            if(StringFind(comment, prefix) != -1)
               return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Verifica si está permitido operar en la sesión actual            |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
   if(!InpTradeTokyo && !InpTradeLondon && !InpTradeNewYork && !InpTradeAsia)
      return true;
   
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   
   int hourUTC = dt.hour - InpTimeZoneOffset;
   if(hourUTC < 0) hourUTC += 24;
   if(hourUTC >= 24) hourUTC -= 24;
   
   bool isTokyo = (hourUTC >= 0 && hourUTC < 8);
   bool isLondon = (hourUTC >= 8 && hourUTC < 16);
   bool isNewYork = (hourUTC >= 13 && hourUTC < 21);
   bool isAsia = (hourUTC >= 21 || hourUTC < 5);
   
   if(isTokyo && InpTradeTokyo) return true;
   if(isLondon && InpTradeLondon) return true;
   if(isNewYork && InpTradeNewYork) return true;
   if(isAsia && InpTradeAsia) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Inicialización                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   if(InpTrailingStopPoints <= 0)
   {
      trailingEnabled = false;
      Print("Trailing stop desactivado.");
   }
   
   if(InpMaxGrids == 0 || !InpEnableGridExpansion)
   {
      if(InpMaxGrids == 0)
         Print("Nuevas rejillas desactivadas por InpMaxGrids = 0");
      if(!InpEnableGridExpansion)
         Print("Nuevas rejillas desactivadas por InpEnableGridExpansion = false");
   }
   else
   {
      Print("Máximo de rejillas totales: ", InpMaxGrids);
   }
   
   if(InpMaxExpansionOrders == 0)
      Print("Expansión de órdenes en misma dirección desactivada (InpMaxExpansionOrders = 0)");
   else
      Print("Máx. órdenes de expansión por lado: ", InpMaxExpansionOrders);
   
   if(InpCloseOppositeCount > 0)
      Print("Se cerrarán ", InpCloseOppositeCount, " posiciones contrarias por cada rejilla al expandir.");
   else
      Print("Cierre de posiciones contrarias desactivado (InpCloseOppositeCount = 0)");
   
   if(InpCooldownHours > 0)
      Print("Cooldown activado: ", InpCooldownHours, " horas.");
   else
      Print("Cooldown desactivado (InpCooldownHours = 0)");
   
   if(InpMaxTotalPositions > 0)
      Print("Límite máximo de posiciones totales: ", InpMaxTotalPositions);
   else
      Print("Límite de posiciones totales desactivado (InpMaxTotalPositions = 0)");
   
   string sessions = "Sesiones activas: ";
   if(InpTradeTokyo) sessions += "Tokio ";
   if(InpTradeLondon) sessions += "Londres ";
   if(InpTradeNewYork) sessions += "Nueva York ";
   if(InpTradeAsia) sessions += "Asia ";
   if(sessions == "Sesiones activas: ")
      sessions += "Todas (ninguna seleccionada)";
   Print(sessions, "| Offset UTC: ", InpTimeZoneOffset);
   
   // Configuración del drawdown diario
   if(InpDrawdownMode == 0 && InpDailyMaxDrawdownPercent > 0.0)
   {
      dailyDrawdownEnabled = true;
      dailyDrawdownLimit = InpDailyMaxDrawdownPercent;
      Print("Drawdown diario activado en modo %: ", dailyDrawdownLimit, "%");
   }
   else if(InpDrawdownMode == 1 && InpDailyMaxDrawdownMoney > 0.0)
   {
      dailyDrawdownEnabled = true;
      dailyDrawdownLimit = InpDailyMaxDrawdownMoney;
      Print("Drawdown diario activado en modo dinero: $", dailyDrawdownLimit);
   }
   else
   {
      dailyDrawdownEnabled = false;
      Print("Drawdown diario desactivado.");
   }
   
   // Configuración del profit diario
   if(InpDailyProfitMode == 0 && InpDailyProfitPercent > 0.0)
   {
      dailyProfitEnabled = true;
      dailyProfitTarget = InpDailyProfitPercent;
      Print("Profit diario activado en modo %: ", dailyProfitTarget, "%");
   }
   else if(InpDailyProfitMode == 1 && InpDailyProfitMoney > 0.0)
   {
      dailyProfitEnabled = true;
      dailyProfitTarget = InpDailyProfitMoney;
      Print("Profit diario activado en modo dinero: $", dailyProfitTarget);
   }
   else
   {
      dailyProfitEnabled = false;
      Print("Profit diario desactivado.");
   }
   
   Print("Lote base: ", InpLotSize, " | Incremento: ", InpLotIncrement, " | Paso: ", InpLotStep);
   
   int chartWidth = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int minWidth = InpPanelSeparation + 30;
   int panelWidth = MathMax(InpPanelWidth, minWidth);
   int panelX = chartWidth - panelWidth - InpPanelMarginRight;
   int panelY = 30;
   int panelHeight = 355; // 9 filas
   
   CreatePanel(panelX, panelY, panelWidth, panelHeight);
   panelCreated = true;
   EventSetTimer(timerSeconds);
   
   gridPlaced = false;
   lastDayCheck = 0;
   dailyMaxEquity = 0.0;
   dailyDrawdownReached = false;
   dailyStartEquity = 0.0;
   dailyProfitReached = false;
   dailyProfitCount = 0;
   dailyDrawdownCount = 0;
   totalCommissions = 0.0;
   closedLossAccumulator = 0.0;
   cooldownActive = false;
   cooldownEndTime = 0;
   lastMaxPositionsProfit = 0.0;
   
   Print("EA iniciado. Esperando primer tick...");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Desinicialización                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "GridPanel_");
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   CheckDailyControls();
   
   if(dailyDrawdownReached || dailyProfitReached)
      return;
   
   if(cooldownActive)
   {
      if(TimeCurrent() >= cooldownEndTime)
      {
         cooldownActive = false;
         cooldownEndTime = 0;
         Print("Cooldown finalizado. EA reanudando operaciones.");
         gridPlaced = false;
      }
      else
      {
         static datetime lastCooldownMsg = 0;
         if(TimeCurrent() - lastCooldownMsg >= 300)
         {
            lastCooldownMsg = TimeCurrent();
            int remaining = (int)((cooldownEndTime - TimeCurrent()) / 60);
            Print("Cooldown activo. Restan ", remaining, " minutos.");
         }
         return;
      }
   }
   
   bool tradingAllowed = IsTradingAllowed();
   
   if(!gridPlaced)
   {
      if(tradingAllowed)
      {
         if(CountPendingOrders() > 0)
            CancelAllPendingOrders();
         
         if(PositionsTotal() > 0)
         {
            bool hasMyPositions = false;
            for(int i = 0; i < PositionsTotal(); i++)
            {
               ulong ticket = PositionGetTicket(i);
               if(PositionSelectByTicket(ticket))
               {
                  if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
                     PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
                  {
                     hasMyPositions = true;
                     break;
                  }
               }
            }
            if(hasMyPositions)
            {
               Print("Cerrando posiciones residuales del EA antes de colocar rejilla inicial.");
               CloseAllPositions();
               totalCommissions = 0.0;
               closedLossAccumulator = 0.0;
            }
         }
         
         MqlTick tick;
         if(SymbolInfoTick(_Symbol, tick) && tick.ask > 0 && tick.bid > 0)
         {
            if(PlaceGrid())
            {
               gridPlaced = true;
               Print("Rejilla inicial colocada correctamente.");
            }
         }
      }
      UpdatePanel();
      return;
   }
   
   UpdateCommissionsAccumulator();
   ManagePositions();
   if(tradingAllowed)
      CheckAndAddOrders();
   UpdateMaxDrawdown();
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| Timer - actualiza panel                                          |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(panelCreated)
      UpdatePanel();
}

//+------------------------------------------------------------------+
//| Controla los límites diarios (drawdown y profit)                 |
//+------------------------------------------------------------------+
void CheckDailyControls()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   
   datetime currentDay = StringToTime(IntegerToString(dt.year) + "." + IntegerToString(dt.mon) + "." + IntegerToString(dt.day));
   if(lastDayCheck == 0)
      lastDayCheck = currentDay;
   
   if(currentDay != lastDayCheck)
   {
      lastDayCheck = currentDay;
      dailyMaxEquity = 0.0;
      dailyDrawdownReached = false;
      dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      dailyProfitReached = false;
      totalCommissions = 0.0;
      closedLossAccumulator = 0.0;
      cooldownActive = false;
      cooldownEndTime = 0;
      Print("Nuevo día detectado. Reiniciando controles diarios y cooldown.");
   }
   
   if(dailyStartEquity == 0.0)
      dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   bool mustStop = false;
   
   // Verificar Drawdown
   if(dailyDrawdownEnabled && !dailyDrawdownReached)
   {
      if(dailyMaxEquity == 0.0 || equity > dailyMaxEquity)
         dailyMaxEquity = equity;
      
      double currentDrawdown = dailyMaxEquity - equity;
      if(currentDrawdown < 0) currentDrawdown = 0;
      
      double limit = dailyDrawdownLimit;
      bool limitExceeded = false;
      
      if(InpDrawdownMode == 0)
      {
         double percentDrawdown = (dailyMaxEquity > 0) ? (currentDrawdown / dailyMaxEquity) * 100.0 : 0;
         if(percentDrawdown >= limit)
         {
            limitExceeded = true;
            Print("Drawdown diario en % alcanzado: ", DoubleToString(percentDrawdown, 2), "% (límite ", limit, "%)");
         }
      }
      else
      {
         if(currentDrawdown >= limit)
         {
            limitExceeded = true;
            Print("Drawdown diario en dinero alcanzado: $", DoubleToString(currentDrawdown, 2), " (límite $", limit, ")");
         }
      }
      
      if(limitExceeded)
      {
         dailyDrawdownReached = true;
         mustStop = true;
         dailyDrawdownCount++;
      }
   }
   
   // Verificar Profit
   if(dailyProfitEnabled && !dailyProfitReached)
   {
      double currentProfit = equity - dailyStartEquity;
      
      double limit = dailyProfitTarget;
      bool limitExceeded = false;
      
      if(InpDailyProfitMode == 0)
      {
         double percentProfit = (dailyStartEquity > 0) ? (currentProfit / dailyStartEquity) * 100.0 : 0;
         if(percentProfit >= limit)
         {
            limitExceeded = true;
            Print("Profit diario en % alcanzado: ", DoubleToString(percentProfit, 2), "% (límite ", limit, "%)");
         }
      }
      else
      {
         if(currentProfit >= limit)
         {
            limitExceeded = true;
            Print("Profit diario en dinero alcanzado: $", DoubleToString(currentProfit, 2), " (límite $", limit, ")");
         }
      }
      
      if(limitExceeded)
      {
         dailyProfitReached = true;
         mustStop = true;
         dailyProfitCount++;
      }
   }
   
   // Si se debe detener, cerrar todo
   if(mustStop)
   {
      Print("Cerrando todas las posiciones y cancelando órdenes por límite diario.");
      CancelAllPendingOrders();
      CloseAllPositions();
      gridPlaced = false;
      ResetAllGrids();
      totalCommissions = 0.0;
      closedLossAccumulator = 0.0;
      cooldownActive = false;
      cooldownEndTime = 0;
   }
}

//+------------------------------------------------------------------+
//| Gestiona posiciones (cierre por profit/trailing, cooldown, límite)|
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(dailyDrawdownReached || dailyProfitReached)
      return;
   
   int totalPos = PositionsTotal();
   int buyCount = 0, sellCount = 0;
   double totalProfit = 0.0;
   
   static double highestPriceSeen = 0.0;
   static double lowestPriceSeen  = DBL_MAX;
   static bool onlyBuysMode = false;
   static bool onlySellsMode = false;
   
   for(int i = 0; i < totalPos; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            totalProfit += PositionGetDouble(POSITION_PROFIT);
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(posType == POSITION_TYPE_BUY)
               buyCount++;
            else if(posType == POSITION_TYPE_SELL)
               sellCount++;
         }
      }
   }
   
   // --- LÍMITE MÁXIMO DE POSICIONES ---
   if(InpMaxTotalPositions > 0 && (buyCount + sellCount) >= InpMaxTotalPositions)
   {
      lastMaxPositionsProfit = totalProfit;
      Print("Límite máximo de posiciones alcanzado (", buyCount+sellCount, "/", InpMaxTotalPositions, 
            "). Cerrando todas las posiciones. Profit de cierre: ", DoubleToString(totalProfit, 2));
      accumulatedProfit += totalProfit;
      CancelAllPendingOrders();
      CloseAllPositions();
      closedLossAccumulator = 0.0;
      totalCommissions = 0.0;
      ResetAllGrids();
      gridPlaced = false;
      return;
   }
   
   // Si no hay posiciones, resetear flags y acumuladores
   if(buyCount == 0 && sellCount == 0)
   {
      onlyBuysMode = false;
      onlySellsMode = false;
      highestPriceSeen = 0.0;
      lowestPriceSeen = DBL_MAX;
      if(CountPendingOrders() == 0)
         gridPlaced = false;
      totalCommissions = 0.0;
      closedLossAccumulator = 0.0;
      return;
   }
   
   // Verificar cooldown por falta de órdenes o expansiones en ambos lados
   bool triggerCooldown = false;
   string reason = "";
   
   if(CountPendingOrders() == 0 && InpCooldownHours > 0)
   {
      triggerCooldown = true;
      reason = "No quedan órdenes pendientes en ningún lado.";
   }
   else if(InpCooldownHours > 0 && HasExpansionOrdersOrPositions("Buy") && HasExpansionOrdersOrPositions("Sell"))
   {
      triggerCooldown = true;
      reason = "Se han colocado rejillas de expansión en ambos extremos.";
   }
   
   if(triggerCooldown)
   {
      Print(reason, " Cerrando todas las posiciones y activando cooldown de ", InpCooldownHours, " horas.");
      accumulatedProfit += totalProfit;
      CancelAllPendingOrders();
      CloseAllPositions();
      closedLossAccumulator = 0.0;
      totalCommissions = 0.0;
      ResetAllGrids();
      gridPlaced = false;
      
      cooldownActive = true;
      cooldownEndTime = TimeCurrent() + (int)(InpCooldownHours * 3600);
      Print("Cooldown activo hasta: ", TimeToString(cooldownEndTime));
      return;
   }
   
   bool isOnlyBuys  = (buyCount > 0 && sellCount == 0);
   bool isOnlySells = (sellCount > 0 && buyCount == 0);
   
   double adjustedProfitTarget = InpProfitTarget + closedLossAccumulator + totalCommissions;
   double adjustedOneDirectionTarget = InpOneDirectionProfitTarget + closedLossAccumulator + totalCommissions;
   
   // --- Caso: ambas direcciones abiertas ---
   if(buyCount > 0 && sellCount > 0)
   {
      onlyBuysMode = false;
      onlySellsMode = false;
      highestPriceSeen = 0.0;
      lowestPriceSeen = DBL_MAX;
      if(totalProfit >= adjustedProfitTarget)
      {
         accumulatedProfit += totalProfit;
         CancelAllPendingOrders();
         CloseAllPositions();
         closedLossAccumulator = 0.0;
         totalCommissions = 0.0;
         ResetAllGrids();
         gridPlaced = false;
      }
      return;
   }
   
   // --- Caso: solo compras ---
   if(isOnlyBuys)
   {
      if(!onlyBuysMode)
      {
         onlyBuysMode = true;
         onlySellsMode = false;
         highestPriceSeen = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      }
      else
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(currentBid > highestPriceSeen)
            highestPriceSeen = currentBid;
      }
      
      if(totalProfit >= adjustedOneDirectionTarget)
      {
         accumulatedProfit += totalProfit;
         CancelAllPendingOrders();
         CloseAllPositions();
         closedLossAccumulator = 0.0;
         totalCommissions = 0.0;
         ResetAllGrids();
         gridPlaced = false;
         return;
      }
      
      if(trailingEnabled && InpTrailingStopPoints > 0)
      {
         double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double trailingStopPrice = highestPriceSeen - InpTrailingStopPoints * point;
         if(currentBid <= trailingStopPrice)
         {
            accumulatedProfit += totalProfit;
            CancelAllPendingOrders();
            CloseAllPositions();
            closedLossAccumulator = 0.0;
            totalCommissions = 0.0;
            ResetAllGrids();
            gridPlaced = false;
            return;
         }
      }
   }
   
   // --- Caso: solo ventas ---
   if(isOnlySells)
   {
      if(!onlySellsMode)
      {
         onlySellsMode = true;
         onlyBuysMode = false;
         lowestPriceSeen = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      }
      else
      {
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(currentAsk < lowestPriceSeen)
            lowestPriceSeen = currentAsk;
      }
      
      if(totalProfit >= adjustedOneDirectionTarget)
      {
         accumulatedProfit += totalProfit;
         CancelAllPendingOrders();
         CloseAllPositions();
         closedLossAccumulator = 0.0;
         totalCommissions = 0.0;
         ResetAllGrids();
         gridPlaced = false;
         return;
      }
      
      if(trailingEnabled && InpTrailingStopPoints > 0)
      {
         double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double trailingStopPrice = lowestPriceSeen + InpTrailingStopPoints * point;
         if(currentAsk >= trailingStopPrice)
         {
            accumulatedProfit += totalProfit;
            CancelAllPendingOrders();
            CloseAllPositions();
            closedLossAccumulator = 0.0;
            totalCommissions = 0.0;
            ResetAllGrids();
            gridPlaced = false;
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Reinicia todas las variables de rejilla                           |
//+------------------------------------------------------------------+
void ResetAllGrids()
{
   gridCounter = 1;
   lastBuyGridPrice = 0.0;
   lastSellGridPrice = 0.0;
   buyGridActivationCount = 0;
   sellGridActivationCount = 0;
   ArrayResize(gridStates, 0);
}

//+------------------------------------------------------------------+
//| Cancela órdenes pendientes de una rejilla específica             |
//+------------------------------------------------------------------+
void CancelOrdersByGridId(int gridId)
{
   string gridPrefix = "Grid" + IntegerToString(gridId);
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            string comment = OrderGetString(ORDER_COMMENT);
            if(StringFind(comment, gridPrefix) != -1)
            {
               trade.OrderDelete(ticket);
               Print("Cancelada orden de rejilla ", gridId, ": ", comment);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Cierra posiciones del lado contrario por cada rejilla            |
//+------------------------------------------------------------------+
void CloseOppositePositions(ENUM_POSITION_TYPE expansionType, int count)
{
   if(count <= 0)
      return;
   
   ENUM_POSITION_TYPE oppositeType = (expansionType == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   double totalClosedLoss = 0.0;
   int totalClosed = 0;
   
   for(int idx = 0; idx < ArraySize(gridStates); idx++)
   {
      int gId = gridStates[idx].gridId;
      string gridPrefix = "Grid" + IntegerToString(gId);
      string typeSuffix = (oppositeType == POSITION_TYPE_BUY) ? "_BuyStop_" : "_SellStop_";
      
      struct PosInfo
      {
         ulong ticket;
         double profit;
      };
      PosInfo positions[];
      
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket))
         {
            if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
               PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
               PositionGetInteger(POSITION_TYPE) == oppositeType)
            {
               string comment = PositionGetString(POSITION_COMMENT);
               if(StringFind(comment, gridPrefix) != -1 && StringFind(comment, typeSuffix) != -1)
               {
                  int size = ArraySize(positions);
                  ArrayResize(positions, size + 1);
                  positions[size].ticket = ticket;
                  positions[size].profit = PositionGetDouble(POSITION_PROFIT);
               }
            }
         }
      }
      
      if(ArraySize(positions) > 1)
      {
         for(int i = 0; i < ArraySize(positions)-1; i++)
         {
            for(int j = i+1; j < ArraySize(positions); j++)
            {
               if(positions[i].profit > positions[j].profit)
               {
                  PosInfo temp = positions[i];
                  positions[i] = positions[j];
                  positions[j] = temp;
               }
            }
         }
      }
      
      int closed = 0;
      for(int i = 0; i < ArraySize(positions) && closed < count; i++)
      {
         if(trade.PositionClose(positions[i].ticket))
         {
            totalClosedLoss += positions[i].profit;
            totalClosed++;
            closed++;
            Print("Cerrada posición contraria (", (oppositeType == POSITION_TYPE_BUY ? "compra" : "venta"), 
                  ") Grid", gId, " ticket ", positions[i].ticket, 
                  " profit: ", positions[i].profit);
         }
      }
   }
   
   if(totalClosed > 0 && totalClosedLoss < 0)
   {
      closedLossAccumulator += MathAbs(totalClosedLoss);
      Print("Pérdidas acumuladas por cierres de expansión: ", closedLossAccumulator, 
            " (nuevo profit target ajustado: ", InpProfitTarget + closedLossAccumulator + totalCommissions, ")");
   }
}

//+------------------------------------------------------------------+
//| Verifica y añade nuevas órdenes o rejillas                       |
//+------------------------------------------------------------------+
void CheckAndAddOrders()
{
   if(dailyDrawdownReached || dailyProfitReached || cooldownActive)
      return;
   
   if(!IsTradingAllowed())
      return;
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0 || tick.bid <= 0)
      return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double distance = InpDistancePoints * point;
   double ask = tick.ask;
   double bid = tick.bid;
   
   int totalPos = PositionsTotal();
   bool hasBuyPos = false, hasSellPos = false;
   for(int i = 0; i < totalPos; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(posType == POSITION_TYPE_BUY)
               hasBuyPos = true;
            else if(posType == POSITION_TYPE_SELL)
               hasSellPos = true;
         }
      }
   }
   
   if(!hasBuyPos || !hasSellPos)
      return;
   
   buyGridActivationCount = CountPositionsByGrid(gridCounter, POSITION_TYPE_BUY);
   sellGridActivationCount = CountPositionsByGrid(gridCounter, POSITION_TYPE_SELL);
   
   if(InpEnableGridExpansion && InpMaxGrids != 0)
   {
      bool triggerBuy = false, triggerSell = false;
      int half = InpNumberOfOrders / 2;
      
      if(buyGridActivationCount > half && lastBuyGridPrice > 0 && ask <= lastBuyGridPrice + point * 0.5)
         triggerBuy = true;
      
      if(sellGridActivationCount > half && lastSellGridPrice > 0 && bid >= lastSellGridPrice - point * 0.5)
         triggerSell = true;
      
      if((triggerBuy || triggerSell) && (InpMaxGrids == 0 || gridCounter < InpMaxGrids))
      {
         PlaceDoubleGrid();
         return;
      }
   }
   
   if(InpMaxExpansionOrders > 0)
   {
      for(int idx = 0; idx < ArraySize(gridStates); idx++)
      {
         if(gridStates[idx].isDisabled)
         {
            int gId = gridStates[idx].gridId;
            int activatedBuys = CountPositionsByGrid(gId, POSITION_TYPE_BUY);
            int activatedSells = CountPositionsByGrid(gId, POSITION_TYPE_SELL);
            if(activatedBuys > 0 || activatedSells > 0)
            {
               gridStates[idx].isDisabled = false;
               gridStates[idx].retryCount = 0;
               Print("Rejilla ", gId, " reactivada (hay posiciones activas).");
            }
            continue;
         }
         
         int gId = gridStates[idx].gridId;
         
         int activatedBuys = CountPositionsByGrid(gId, POSITION_TYPE_BUY);
         int totalBuyOrders = InpNumberOfOrders;
         
         if(activatedBuys >= totalBuyOrders)
         {
            int pendingBuys = CountPendingOrdersByGrid(gId, ORDER_TYPE_BUY_STOP);
            if(pendingBuys == 0)
            {
               if(gridStates[idx].lastBuyStopPrice == 0.0)
                  gridStates[idx].lastBuyStopPrice = GetLastBuyPriceForGrid(gId);
               
               if(ask >= gridStates[idx].lastBuyStopPrice + distance - point * 0.5)
               {
                  if(gridStates[idx].buyExpansionCount < InpMaxExpansionOrders)
                  {
                     double newBuyPrice = gridStates[idx].lastBuyStopPrice + distance;
                     newBuyPrice = AdjustPriceForStops(newBuyPrice, ask, true);
                     string comment = "ExpBuy_" + IntegerToString(gId) + "_" + IntegerToString(gridStates[idx].buyExpansionCount+1);
                     if(SendStopOrder(ORDER_TYPE_BUY_STOP, newBuyPrice, InpLotSize, comment))
                     {
                        gridStates[idx].lastBuyStopPrice = newBuyPrice;
                        gridStates[idx].buyExpansionCount++;
                        Print("Expansión compra para Grid", gId, " #", gridStates[idx].buyExpansionCount, " a ", newBuyPrice);
                        gridStates[idx].retryCount = 0;
                        
                        if(InpCloseOppositeCount > 0)
                           CloseOppositePositions(POSITION_TYPE_BUY, InpCloseOppositeCount);
                     }
                     else
                     {
                        gridStates[idx].retryCount++;
                        if(gridStates[idx].retryCount >= 3)
                        {
                           gridStates[idx].isDisabled = true;
                           Print("Rejilla ", gId, " desactivada temporalmente por fallos repetidos.");
                        }
                     }
                  }
               }
            }
         }
         
         int activatedSells = CountPositionsByGrid(gId, POSITION_TYPE_SELL);
         if(activatedSells >= totalBuyOrders)
         {
            int pendingSells = CountPendingOrdersByGrid(gId, ORDER_TYPE_SELL_STOP);
            if(pendingSells == 0)
            {
               if(gridStates[idx].lastSellStopPrice == 0.0)
                  gridStates[idx].lastSellStopPrice = GetLastSellPriceForGrid(gId);
               
               if(bid <= gridStates[idx].lastSellStopPrice - distance + point * 0.5)
               {
                  if(gridStates[idx].sellExpansionCount < InpMaxExpansionOrders)
                  {
                     double newSellPrice = gridStates[idx].lastSellStopPrice - distance;
                     newSellPrice = AdjustPriceForStops(newSellPrice, bid, false);
                     string comment = "ExpSell_" + IntegerToString(gId) + "_" + IntegerToString(gridStates[idx].sellExpansionCount+1);
                     if(SendStopOrder(ORDER_TYPE_SELL_STOP, newSellPrice, InpLotSize, comment))
                     {
                        gridStates[idx].lastSellStopPrice = newSellPrice;
                        gridStates[idx].sellExpansionCount++;
                        Print("Expansión venta para Grid", gId, " #", gridStates[idx].sellExpansionCount, " a ", newSellPrice);
                        gridStates[idx].retryCount = 0;
                        
                        if(InpCloseOppositeCount > 0)
                           CloseOppositePositions(POSITION_TYPE_SELL, InpCloseOppositeCount);
                     }
                     else
                     {
                        gridStates[idx].retryCount++;
                        if(gridStates[idx].retryCount >= 3)
                        {
                           gridStates[idx].isDisabled = true;
                           Print("Rejilla ", gId, " desactivada temporalmente por fallos repetidos.");
                        }
                     }
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Obtiene el precio de entrada más alto de una rejilla (compra)    |
//+------------------------------------------------------------------+
double GetLastBuyPriceForGrid(int gridId)
{
   double highestPrice = 0.0;
   string gridPrefix = "Grid" + IntegerToString(gridId);
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         {
            string comment = PositionGetString(POSITION_COMMENT);
            if(StringFind(comment, gridPrefix) != -1 && StringFind(comment, "_BuyStop_") != -1)
            {
               double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               if(entryPrice > highestPrice)
                  highestPrice = entryPrice;
            }
         }
      }
   }
   return highestPrice;
}

//+------------------------------------------------------------------+
//| Obtiene el precio de entrada más bajo de una rejilla (venta)     |
//+------------------------------------------------------------------+
double GetLastSellPriceForGrid(int gridId)
{
   double lowestPrice = DBL_MAX;
   string gridPrefix = "Grid" + IntegerToString(gridId);
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         {
            string comment = PositionGetString(POSITION_COMMENT);
            if(StringFind(comment, gridPrefix) != -1 && StringFind(comment, "_SellStop_") != -1)
            {
               double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               if(entryPrice < lowestPrice)
                  lowestPrice = entryPrice;
            }
         }
      }
   }
   return (lowestPrice == DBL_MAX) ? 0.0 : lowestPrice;
}

//+------------------------------------------------------------------+
//| Cuenta posiciones de una rejilla específica y tipo               |
//+------------------------------------------------------------------+
int CountPositionsByGrid(int gridId, ENUM_POSITION_TYPE posType)
{
   int count = 0;
   string gridPrefix = "Grid" + IntegerToString(gridId);
   string typeSuffix = (posType == POSITION_TYPE_BUY) ? "_BuyStop_" : "_SellStop_";
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetInteger(POSITION_TYPE) == posType)
         {
            string comment = PositionGetString(POSITION_COMMENT);
            if(StringFind(comment, gridPrefix) != -1 && StringFind(comment, typeSuffix) != -1)
               count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Cuenta órdenes pendientes de una rejilla específica y tipo       |
//+------------------------------------------------------------------+
int CountPendingOrdersByGrid(int gridId, ENUM_ORDER_TYPE orderType)
{
   int count = 0;
   string gridPrefix = "Grid" + IntegerToString(gridId);
   string typeSuffix = (orderType == ORDER_TYPE_BUY_STOP) ? "_BuyStop_" : "_SellStop_";
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber &&
            OrderGetInteger(ORDER_TYPE) == orderType)
         {
            string comment = OrderGetString(ORDER_COMMENT);
            if(StringFind(comment, gridPrefix) != -1 && StringFind(comment, typeSuffix) != -1)
               count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Añade un nuevo estado de rejilla al array                         |
//+------------------------------------------------------------------+
void AddGridState(int gridId)
{
   int size = ArraySize(gridStates);
   ArrayResize(gridStates, size + 1);
   gridStates[size].gridId = gridId;
   gridStates[size].lastBuyStopPrice = 0.0;
   gridStates[size].lastSellStopPrice = 0.0;
   gridStates[size].buyExpansionCount = 0;
   gridStates[size].sellExpansionCount = 0;
   gridStates[size].retryCount = 0;
   gridStates[size].isDisabled = false;
}

//+------------------------------------------------------------------+
//| Coloca una nueva rejilla en ambas direcciones (sin cancelar)     |
//+------------------------------------------------------------------+
void PlaceDoubleGrid()
{
   if(dailyDrawdownReached || dailyProfitReached || cooldownActive)
      return;
   
   if(!IsTradingAllowed())
      return;
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0 || tick.bid <= 0)
      return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double distance = InpDistancePoints * point;
   double ask = tick.ask;
   double bid = tick.bid;
   double minDist = MathMax(distance, stopsLevel + 20 * point);
   
   int newGridId = ++gridCounter;
   double lot = CalculateLotForGrid(newGridId);
   bool success = true;
   
   for(int i = 1; i <= InpNumberOfOrders; i++)
   {
      double price = ask + MathMax(i * distance, minDist);
      price = AdjustPriceForStops(price, ask, true);
      string comment = "Grid" + IntegerToString(newGridId) + "_BuyStop_" + IntegerToString(i);
      if(!SendStopOrder(ORDER_TYPE_BUY_STOP, price, lot, comment))
      {
         success = false;
         Print("Error colocando orden de compra en Grid", newGridId, ", cancelando rejilla.");
         break;
      }
   }
   
   if(!success)
   {
      CancelOrdersByGridId(newGridId);
      return;
   }
   
   for(int i = 1; i <= InpNumberOfOrders; i++)
   {
      double price = bid - MathMax(i * distance, minDist);
      price = AdjustPriceForStops(price, bid, false);
      string comment = "Grid" + IntegerToString(newGridId) + "_SellStop_" + IntegerToString(i);
      if(!SendStopOrder(ORDER_TYPE_SELL_STOP, price, lot, comment))
      {
         success = false;
         Print("Error colocando orden de venta en Grid", newGridId, ", cancelando rejilla.");
         break;
      }
   }
   
   if(!success)
   {
      CancelOrdersByGridId(newGridId);
      return;
   }
   
   AddGridState(newGridId);
   lastBuyGridPrice = ask;
   lastSellGridPrice = bid;
   buyGridActivationCount = 0;
   sellGridActivationCount = 0;
   
   Print("Nueva rejilla #", newGridId, " colocada (ambas direcciones). Lote: ", lot, " | Ask=", ask, " Bid=", bid);
}

//+------------------------------------------------------------------+
//| Coloca la rejilla inicial                                        |
//+------------------------------------------------------------------+
bool PlaceGrid()
{
   if(dailyDrawdownReached || dailyProfitReached || cooldownActive)
      return false;
   
   if(!IsTradingAllowed())
      return false;
   
   CancelAllPendingOrders();
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0 || tick.bid <= 0)
      return false;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double distance = InpDistancePoints * point;
   double ask = tick.ask;
   double bid = tick.bid;
   double minDist = MathMax(distance, stopsLevel + 20 * point);
   
   ResetAllGrids();
   gridCounter = 1;
   double lot = InpLotSize;
   bool success = true;
   
   for(int i = 1; i <= InpNumberOfOrders; i++)
   {
      double buyPrice = ask + MathMax(i * distance, minDist);
      buyPrice = AdjustPriceForStops(buyPrice, ask, true);
      double sellPrice = bid - MathMax(i * distance, minDist);
      sellPrice = AdjustPriceForStops(sellPrice, bid, false);
      
      string buyComment = "Grid1_BuyStop_" + IntegerToString(i);
      string sellComment = "Grid1_SellStop_" + IntegerToString(i);
      
      if(!SendStopOrder(ORDER_TYPE_BUY_STOP, buyPrice, lot, buyComment))
      {
         success = false;
         break;
      }
      if(!SendStopOrder(ORDER_TYPE_SELL_STOP, sellPrice, lot, sellComment))
      {
         success = false;
         break;
      }
   }
   
   if(!success)
   {
      CancelOrdersByGridId(1);
      Print("Fallo al colocar rejilla inicial. Las posiciones residuales se cerrarán en el próximo tick.");
      return false;
   }
   
   AddGridState(1);
   lastBuyGridPrice = ask;
   lastSellGridPrice = bid;
   buyGridActivationCount = 0;
   sellGridActivationCount = 0;
   
   Print("Rejilla inicial colocada. Lote: ", lot, " | Ask=", ask, " Bid=", bid);
   return true;
}

//+------------------------------------------------------------------+
//| Envía una orden stop                                             |
//+------------------------------------------------------------------+
bool SendStopOrder(ENUM_ORDER_TYPE type, double price, double volume, string comment)
{
   if(dailyDrawdownReached || dailyProfitReached || cooldownActive)
      return false;
   
   if(!IsTradingAllowed())
      return false;
   
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   
   bool result = false;
   if(type == ORDER_TYPE_BUY_STOP)
      result = trade.BuyStop(volume, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment);
   else if(type == ORDER_TYPE_SELL_STOP)
      result = trade.SellStop(volume, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment);
   
   if(!result)
   {
      Print("Error al enviar orden stop: ", trade.ResultRetcodeDescription(), " | Precio: ", price, " | Tipo: ", (type == ORDER_TYPE_BUY_STOP ? "BUY" : "SELL"));
   }
   return result;
}

//+------------------------------------------------------------------+
//| Cuenta todas las órdenes pendientes                              |
//+------------------------------------------------------------------+
int CountPendingOrders()
{
   int count = 0;
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
               count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Cancela todas las órdenes pendientes                             |
//+------------------------------------------------------------------+
void CancelAllPendingOrders()
{
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
               trade.OrderDelete(ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Cierra todas las posiciones                                      |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            trade.PositionClose(ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Actualiza el drawdown máximo                                     |
//+------------------------------------------------------------------+
void UpdateMaxDrawdown()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > maxEquity)
      maxEquity = equity;
   double drawdown = maxEquity - equity;
   if(drawdown > maxDrawdown)
      maxDrawdown = drawdown;
}

//+------------------------------------------------------------------+
//| FUNCIONES DEL PANEL VISUAL                                        |
//+------------------------------------------------------------------+
void CreatePanel(int panelX, int panelY, int panelWidth, int panelHeight)
{
   ObjectsDeleteAll(0, "GridPanel_");
   
   int rowHeight = MathMax(InpFontSizeLabels + 8, 28);
   int totalRows = 9; // 9 filas
   int calculatedHeight = (totalRows * rowHeight) + 55;
   panelHeight = MathMax(panelHeight, calculatedHeight);
   
   ObjectCreate(0, "GridPanel_Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_XSIZE, panelWidth);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_YSIZE, panelHeight);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_BACK, 1);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_BORDER_COLOR, clrGray);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_ZORDER, 0);
   ObjectSetInteger(0, "GridPanel_Background", OBJPROP_BACK, 1);
   
   int yPos = panelY + 5;
   int labelX = panelX + 10;
   int valueX = labelX + InpPanelSeparation;
   
   CreateLabel("GridPanel_Title", labelX, yPos, "=== EA Grid Trading v1.98 ===", InpColorTitle, InpFontSizeTitle);
   yPos += rowHeight;
   CreateLabel("GridPanel_ProfitLabel", labelX, yPos, "Profit actual:", InpColorLabels, InpFontSizeLabels);
   CreateLabel("GridPanel_ProfitValue", valueX, yPos, "0.00", InpColorValues, InpFontSizeValues);
   yPos += rowHeight;
   CreateLabel("GridPanel_BuyCountLabel", labelX, yPos, "Compras activas:", InpColorLabels, InpFontSizeLabels);
   CreateLabel("GridPanel_BuyCountValue", valueX, yPos, "0", InpColorValues, InpFontSizeValues);
   yPos += rowHeight;
   CreateLabel("GridPanel_SellCountLabel", labelX, yPos, "Ventas activas:", InpColorLabels, InpFontSizeLabels);
   CreateLabel("GridPanel_SellCountValue", valueX, yPos, "0", InpColorValues, InpFontSizeValues);
   yPos += rowHeight;
   CreateLabel("GridPanel_AccumLabel", labelX, yPos, "Profit acumulado:", InpColorLabels, InpFontSizeLabels);
   CreateLabel("GridPanel_AccumValue", valueX, yPos, "0.00", InpColorValues, InpFontSizeValues);
   yPos += rowHeight;
   CreateLabel("GridPanel_DrawdownLabel", labelX, yPos, "Drawdown máx:", InpColorLabels, InpFontSizeLabels);
   CreateLabel("GridPanel_DrawdownValue", valueX, yPos, "0.00", InpColorValues, InpFontSizeValues);
   yPos += rowHeight;
   CreateLabel("GridPanel_ProfitDailyLabel", labelX, yPos, "Falta profit diario:", InpColorLabels, InpFontSizeLabels);
   CreateLabel("GridPanel_ProfitDailyValue", valueX, yPos, "---", InpColorValues, InpFontSizeValues);
   yPos += rowHeight;
   CreateLabel("GridPanel_LimitsLabel", labelX, yPos, "Límites alcanzados:", InpColorLabels, InpFontSizeLabels);
   string limitsText = "Profits: 0 | Drawdowns: 0";
   CreateLabel("GridPanel_LimitsValue", valueX, yPos, limitsText, InpColorValues, InpFontSizeValues);
   yPos += rowHeight;
   // Nueva línea: Profit de cierre por límite de posiciones
   CreateLabel("GridPanel_CloseLimitLabel", labelX, yPos, "Profit cierre por límite:", InpColorLabels, InpFontSizeLabels);
   CreateLabel("GridPanel_CloseLimitValue", valueX, yPos, "---", InpColorValues, InpFontSizeValues);
   yPos += rowHeight + 5;
   
   // Botón Trailing
   string btnName = "GridPanel_TrailingBtn";
   ObjectCreate(0, btnName, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, btnName, OBJPROP_XDISTANCE, labelX);
   ObjectSetInteger(0, btnName, OBJPROP_YDISTANCE, yPos);
   ObjectSetInteger(0, btnName, OBJPROP_XSIZE, 120);
   ObjectSetInteger(0, btnName, OBJPROP_YSIZE, 25);
   ObjectSetInteger(0, btnName, OBJPROP_BORDER_COLOR, clrGray);
   ObjectSetInteger(0, btnName, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, btnName, OBJPROP_BACK, 1);
   ObjectSetInteger(0, btnName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, btnName, OBJPROP_ZORDER, 1);
   ObjectSetInteger(0, btnName, OBJPROP_STATE, 0);
   ObjectSetInteger(0, btnName, OBJPROP_FONTSIZE, InpFontSizeLabels);
   ObjectSetString(0, btnName, OBJPROP_TEXT, trailingEnabled ? "Trailing: ON" : "Trailing: OFF");
   ObjectSetInteger(0, btnName, OBJPROP_BGCOLOR, trailingEnabled ? clrDarkGreen : clrDarkRed);
   
   if(InpTrailingStopPoints <= 0)
   {
      ObjectSetInteger(0, btnName, OBJPROP_STATE, 1);
      ObjectSetInteger(0, btnName, OBJPROP_BGCOLOR, clrGray);
      ObjectSetString(0, btnName, OBJPROP_TEXT, "Trailing: OFF");
   }
   
   ChartRedraw();
}

void CreateLabel(string name, int x, int y, string text, color clr, int fontSize)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_BACK, 1);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void UpdatePanel()
{
   int totalPos = PositionsTotal();
   int buyCount = 0, sellCount = 0;
   double totalProfit = 0.0;
   
   for(int i = 0; i < totalPos; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(IsMySymbol(PositionGetString(POSITION_SYMBOL)) && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            totalProfit += PositionGetDouble(POSITION_PROFIT);
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(posType == POSITION_TYPE_BUY)
               buyCount++;
            else if(posType == POSITION_TYPE_SELL)
               sellCount++;
         }
      }
   }
   
   ObjectSetString(0, "GridPanel_ProfitValue", OBJPROP_TEXT, DoubleToString(totalProfit, 2));
   color profitColor = (totalProfit >= 0) ? InpColorValues : clrRed;
   ObjectSetInteger(0, "GridPanel_ProfitValue", OBJPROP_COLOR, profitColor);
   ObjectSetString(0, "GridPanel_BuyCountValue", OBJPROP_TEXT, IntegerToString(buyCount));
   ObjectSetString(0, "GridPanel_SellCountValue", OBJPROP_TEXT, IntegerToString(sellCount));
   ObjectSetString(0, "GridPanel_AccumValue", OBJPROP_TEXT, DoubleToString(accumulatedProfit, 2));
   ObjectSetString(0, "GridPanel_DrawdownValue", OBJPROP_TEXT, DoubleToString(maxDrawdown, 2));
   if(maxDrawdown > 0)
      ObjectSetInteger(0, "GridPanel_DrawdownValue", OBJPROP_COLOR, clrRed);
   else
      ObjectSetInteger(0, "GridPanel_DrawdownValue", OBJPROP_COLOR, InpColorValues);
   
   // Profit restante diario
   string dailyProfitText = "---";
   if(dailyProfitEnabled)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(dailyStartEquity > 0)
      {
         if(dailyProfitReached)
            dailyProfitText = "Alcanzado";
         else
         {
            double currentProfit = equity - dailyStartEquity;
            if(InpDailyProfitMode == 0)
            {
               double currentPercent = (currentProfit / dailyStartEquity) * 100.0;
               double remaining = dailyProfitTarget - currentPercent;
               if(remaining < 0) remaining = 0;
               dailyProfitText = DoubleToString(remaining, 2) + "%";
            }
            else
            {
               double remaining = dailyProfitTarget - currentProfit;
               if(remaining < 0) remaining = 0;
               dailyProfitText = "$" + DoubleToString(remaining, 2);
            }
         }
      }
      else
         dailyProfitText = "---";
   }
   else
      dailyProfitText = "Desactivado";
   ObjectSetString(0, "GridPanel_ProfitDailyValue", OBJPROP_TEXT, dailyProfitText);
   if(dailyProfitEnabled && !dailyProfitReached && dailyStartEquity > 0)
      ObjectSetInteger(0, "GridPanel_ProfitDailyValue", OBJPROP_COLOR, InpColorValues);
   else if(dailyProfitReached)
      ObjectSetInteger(0, "GridPanel_ProfitDailyValue", OBJPROP_COLOR, clrGold);
   else
      ObjectSetInteger(0, "GridPanel_ProfitDailyValue", OBJPROP_COLOR, clrGray);
   
   // Contadores de límites alcanzados
   string limitsText = "Profits: " + IntegerToString(dailyProfitCount) + " | Drawdowns: " + IntegerToString(dailyDrawdownCount);
   ObjectSetString(0, "GridPanel_LimitsValue", OBJPROP_TEXT, limitsText);
   if(dailyProfitCount > 0 || dailyDrawdownCount > 0)
      ObjectSetInteger(0, "GridPanel_LimitsValue", OBJPROP_COLOR, clrGold);
   else
      ObjectSetInteger(0, "GridPanel_LimitsValue", OBJPROP_COLOR, clrGray);
   
   // Profit de cierre por límite de posiciones
   string closeLimitText = (lastMaxPositionsProfit != 0.0) ? DoubleToString(lastMaxPositionsProfit, 2) : "---";
   ObjectSetString(0, "GridPanel_CloseLimitValue", OBJPROP_TEXT, closeLimitText);
   if(lastMaxPositionsProfit != 0.0)
   {
      if(lastMaxPositionsProfit > 0)
         ObjectSetInteger(0, "GridPanel_CloseLimitValue", OBJPROP_COLOR, clrGold);
      else
         ObjectSetInteger(0, "GridPanel_CloseLimitValue", OBJPROP_COLOR, clrRed);
   }
   else
      ObjectSetInteger(0, "GridPanel_CloseLimitValue", OBJPROP_COLOR, clrGray);
   
   if(InpTrailingStopPoints > 0)
   {
      string btnName = "GridPanel_TrailingBtn";
      ObjectSetString(0, btnName, OBJPROP_TEXT, trailingEnabled ? "Trailing: ON" : "Trailing: OFF");
      ObjectSetInteger(0, btnName, OBJPROP_BGCOLOR, trailingEnabled ? clrDarkGreen : clrDarkRed);
   }
   
   ChartRedraw();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == "GridPanel_TrailingBtn")
      {
         if(InpTrailingStopPoints > 0)
         {
            trailingEnabled = !trailingEnabled;
            UpdatePanel();
            Print("Trailing stop ", trailingEnabled ? "activado" : "desactivado");
         }
         else
            Print("Trailing stop desactivado permanentemente (InpTrailingStopPoints = 0)");
      }
   }
}
//+------------------------------------------------------------------+