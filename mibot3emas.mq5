//+------------------------------------------------------------------+
//|                                            TuEstrategiaCompleta.mq5 |
//|                                  Generado según reglas del usuario |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Tu EA Personalizado"
#property version "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

// --- Entradas del usuario ---
input double InpRiskPercent = 1.0;      // % riesgo por operación (sobre saldo real)
input int InpStopLossPips = 30;         // Stop Loss en pips (1 pip = 10 puntos)
input double InpMaxDrawdownDaily = 4.0; // Drawdown diario máximo (%)
input int InpMaxPositions = 4;          // Máximo de posiciones abiertas totales
input int InpMagicNumber = 20250405;    // Magic Number para identificar órdenes del EA

// --- Parámetros de las EMAs ---
input int InpEma1Period = 15;
input int InpEma2Period = 20;
input int InpEma3Period = 50;

// --- Gestión de trailing dinámico ---
input int InpPipsToTrailingTP = 20; // Cuando el precio está a X pips del TP, se mueve SL/TP

// --- Variables globales ---
CTrade trade;
CPositionInfo positionInfo;
CAccountInfo accountInfo;
CHistoryOrderInfo historyOrder;

int ema1Handle, ema2Handle, ema3Handle;
double ema1[], ema2[], ema3[];

datetime lastBarTime = 0;
double dailyEquityPeak;
double dailyStartBalance;
bool drawdownExceeded = false;

// Variables para pérdidas consecutivas
int consecutiveLosses = 0;
bool specialTradeActive = false; // true si la operación actual es 1:1 sin trailing
ulong specialTradeTicket = 0;
bool waitingForSpecialTradeResult = false;

// Variables para reentrada tras SL sin cruce
struct SLReentryInfo
{
   bool pendingReentry;
   int direction;  // 1 compra, -1 venta
   double slPrice; // Precio donde se ejecutó el SL
   datetime lossTime;
};
SLReentryInfo slReentry = {false, 0, 0.0, 0};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Crear handles de las EMAs
   ema1Handle = iMA(_Symbol, PERIOD_H1, InpEma1Period, 0, MODE_EMA, PRICE_CLOSE);
   ema2Handle = iMA(_Symbol, PERIOD_H1, InpEma2Period, 0, MODE_EMA, PRICE_CLOSE);
   ema3Handle = iMA(_Symbol, PERIOD_H1, InpEma3Period, 0, MODE_EMA, PRICE_CLOSE);

   if (ema1Handle == INVALID_HANDLE || ema2Handle == INVALID_HANDLE || ema3Handle == INVALID_HANDLE)
   {
      Print("Error creando handles de EMAs");
      return (INIT_FAILED);
   }

   // Inicializar control diario
   ResetDailyStats();

   trade.SetExpertMagicNumber(InpMagicNumber);

   return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(ema1Handle);
   IndicatorRelease(ema2Handle);
   IndicatorRelease(ema3Handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Actualizar trailing dinámico en cada tick
   UpdateTrailing();

   // Verificar si alguna operación se cerró por SL (para reentrada o pérdidas consecutivas)
   CheckClosedPositions();

   // Solo operar al cierre de vela en H1 para nuevas entradas
   if (!IsNewBar())
      return;

   // Actualizar control de drawdown diario
   UpdateDailyDrawdown();
   if (drawdownExceeded)
      return;

   // Obtener valores actuales de las EMAs
   if (!GetEmaValues())
      return;

   // Determinar tendencia mayor (EMA2 vs EMA3)
   bool tendenciaAlcista = (ema2[1] > ema3[1]);
   bool tendenciaBajista = (ema2[1] < ema3[1]);

   // Detectar cambio de tendencia (cierre de todas las operaciones y apertura contraria)
   CheckTrendChangeAndCloseAll(tendenciaAlcista, tendenciaBajista);

   // Verificar reentrada pendiente por SL sin cruce
   CheckPendingSLReentry(tendenciaAlcista, tendenciaBajista);

   // Verificar si podemos abrir nuevas operaciones
   if (!CanOpenNewTrade())
      return;

   // Determinar dirección según reglas
   int direction = GetTradeDirection(tendenciaAlcista, tendenciaBajista);
   if (direction == 0)
      return;

   // Abrir operación
   OpenTrade(direction);
}

//+------------------------------------------------------------------+
//| Verifica si es una nueva vela en H1                             |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if (currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Obtiene los valores de las 3 EMAs (índice 1 = vela anterior)    |
//+------------------------------------------------------------------+
bool GetEmaValues()
{
   if (CopyBuffer(ema1Handle, 0, 1, 2, ema1) < 2)
      return false;
   if (CopyBuffer(ema2Handle, 0, 1, 2, ema2) < 2)
      return false;
   if (CopyBuffer(ema3Handle, 0, 1, 2, ema3) < 2)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Resetea estadísticas diarias                                    |
//+------------------------------------------------------------------+
void ResetDailyStats()
{
   dailyStartBalance = accountInfo.Balance();
   dailyEquityPeak = accountInfo.Equity();
   drawdownExceeded = false;
}

//+------------------------------------------------------------------+
//| Actualiza el drawdown diario                                    |
//+------------------------------------------------------------------+
void UpdateDailyDrawdown()
{
   double currentEquity = accountInfo.Equity();
   if (currentEquity > dailyEquityPeak)
      dailyEquityPeak = currentEquity;

   double drawdownPercent = (dailyEquityPeak - currentEquity) / dailyEquityPeak * 100.0;
   if (drawdownPercent >= InpMaxDrawdownDaily)
      drawdownExceeded = true;

   // Si es un nuevo día, resetear
   static datetime lastDay = 0;
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   if (currentDay != lastDay)
   {
      lastDay = currentDay;
      ResetDailyStats();
   }
}

//+------------------------------------------------------------------+
//| Cambio de tendencia: cierra todas y abre a favor                |
//+------------------------------------------------------------------+
void CheckTrendChangeAndCloseAll(bool alcista, bool bajista)
{
   static bool lastAlcista = false;
   static bool lastBajista = false;

   bool trendChanged = false;
   if (alcista && lastBajista)
      trendChanged = true;
   if (bajista && lastAlcista)
      trendChanged = true;

   if (trendChanged)
   {
      // Cerrar todas las posiciones del EA
      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if (positionInfo.SelectByIndex(i))
         {
            if (positionInfo.Magic() == InpMagicNumber)
               trade.PositionClose(positionInfo.Ticket());
         }
      }

      // Resetear modo especial y reentradas pendientes
      specialTradeActive = false;
      specialTradeTicket = 0;
      waitingForSpecialTradeResult = false;
      slReentry.pendingReentry = false;

      // Abrir nueva operación a favor de la nueva tendencia
      if (alcista)
         OpenTrade(1); // Compra
      else if (bajista)
         OpenTrade(-1); // Venta
   }

   lastAlcista = alcista;
   lastBajista = bajista;
}

//+------------------------------------------------------------------+
//| Verifica condiciones para abrir nueva operación                 |
//+------------------------------------------------------------------+
bool CanOpenNewTrade()
{
   // Límite de posiciones totales
   int totalPositions = 0;
   for (int i = 0; i < PositionsTotal(); i++)
   {
      if (positionInfo.SelectByIndex(i))
         if (positionInfo.Magic() == InpMagicNumber)
            totalPositions++;
   }
   if (totalPositions >= InpMaxPositions)
      return false;

   // No operaciones contrarias abiertas
   bool hasBuy = false, hasSell = false;
   for (int i = 0; i < PositionsTotal(); i++)
   {
      if (positionInfo.SelectByIndex(i) && positionInfo.Magic() == InpMagicNumber)
      {
         if (positionInfo.PositionType() == POSITION_TYPE_BUY)
            hasBuy = true;
         if (positionInfo.PositionType() == POSITION_TYPE_SELL)
            hasSell = true;
      }
   }
   if (hasBuy && hasSell)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Determina dirección de entrada según reglas                     |
//+------------------------------------------------------------------+
int GetTradeDirection(bool tendenciaAlcista, bool tendenciaBajista)
{
   bool cruceEma1Ema2Up = (ema1[1] > ema2[1] && ema1[2] <= ema2[2]);
   bool cruceEma1Ema2Down = (ema1[1] < ema2[1] && ema1[2] >= ema2[2]);

   bool hayPosicionesAbiertas = false;
   bool hayCompraAbierta = false;
   bool hayVentaAbierta = false;

   for (int i = 0; i < PositionsTotal(); i++)
   {
      if (positionInfo.SelectByIndex(i) && positionInfo.Magic() == InpMagicNumber)
      {
         hayPosicionesAbiertas = true;
         if (positionInfo.PositionType() == POSITION_TYPE_BUY)
            hayCompraAbierta = true;
         if (positionInfo.PositionType() == POSITION_TYPE_SELL)
            hayVentaAbierta = true;
      }
   }

   // Si no hay posiciones abiertas, cualquier cruce es válido
   if (!hayPosicionesAbiertas)
   {
      if (cruceEma1Ema2Up)
         return 1;
      if (cruceEma1Ema2Down)
         return -1;
      return 0;
   }

   // Si hay posiciones abiertas y tendencia alcista con compras abiertas
   if (tendenciaAlcista && hayCompraAbierta && !hayVentaAbierta)
   {
      if (cruceEma1Ema2Up)
         return 1;
      else
         return 0;
   }

   // Si hay posiciones abiertas y tendencia bajista con ventas abiertas
   if (tendenciaBajista && hayVentaAbierta && !hayCompraAbierta)
   {
      if (cruceEma1Ema2Down)
         return -1;
      else
         return 0;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Abre una operación (direction = 1 compra, -1 venta)             |
//+------------------------------------------------------------------+
void OpenTrade(int direction)
{
   double slPips = InpStopLossPips;
   double tpPips = specialTradeActive ? slPips : slPips * 3; // 1:1 o 1:3

   double price = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double slPrice = (direction == 1) ? price - slPips * 10 * point : price + slPips * 10 * point;
   double tpPrice = (direction == 1) ? price + tpPips * 10 * point : price - tpPips * 10 * point;

   // Calcular volumen según riesgo 1% sobre saldo real
   double balance = accountInfo.Balance();
   double riskMoney = balance * (InpRiskPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double slInPoints = slPips * 10;
   double lot = riskMoney / (slInPoints * tickValue);
   lot = NormalizeDouble(lot, 2);

   if (lot < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
      lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if (lot > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX))
      lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if (direction == 1)
      trade.Buy(lot, _Symbol, price, slPrice, tpPrice, specialTradeActive ? "EA 1:1" : "EA normal");
   else
      trade.Sell(lot, _Symbol, price, slPrice, tpPrice, specialTradeActive ? "EA 1:1" : "EA normal");

   // Si es operación especial 1:1, guardar ticket y marcar espera de resultado
   if (specialTradeActive && trade.ResultRetcode() == TRADE_RETCODE_DONE)
   {
      specialTradeTicket = trade.ResultOrder();
      waitingForSpecialTradeResult = true;
   }
}

//+------------------------------------------------------------------+
//| Verifica operaciones cerradas (para pérdidas consecutivas y reentrada) |
//+------------------------------------------------------------------+
void CheckClosedPositions()
{
   // Configurar historial
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();

   for (int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if (dealTicket == 0)
         continue;

      long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if (dealMagic != InpMagicNumber)
         continue;

      long dealType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      if (dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
         continue;

      long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if (dealEntry != DEAL_ENTRY_OUT)
         continue;

      // Verificar si ya procesamos este cierre
      static ulong lastProcessedDeal = 0;
      if (dealTicket == lastProcessedDeal)
         continue;
      lastProcessedDeal = dealTicket;

      // Obtener razón de cierre
      long reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      ulong positionTicket = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

      // Determinar dirección de la posición cerrada
      long posType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      int closedDirection = (posType == DEAL_TYPE_BUY) ? 1 : -1;

      // Obtener precio de cierre
      double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

      // --- Manejo de pérdidas consecutivas ---
      if (profit <= 0) // Pérdida (SL o cierre en negativo)
      {
         consecutiveLosses++;

         // Si era una operación especial 1:1 que perdió, mantenemos modo especial
         if (specialTradeActive && positionTicket == specialTradeTicket)
         {
            // La operación 1:1 perdió, seguimos en modo especial para la siguiente
            specialTradeActive = true;
            waitingForSpecialTradeResult = false;
            specialTradeTicket = 0;
         }
         else
         {
            // Operación normal que perdió
            if (consecutiveLosses >= 4 && !specialTradeActive)
            {
               specialTradeActive = true;
               waitingForSpecialTradeResult = false;
               Print("Activando modo especial 1:1 por 4 pérdidas consecutivas");
            }
         }
      }
      else // Ganancia
      {
         // Resetear pérdidas consecutivas
         consecutiveLosses = 0;

         // Si era operación especial 1:1 que ganó, desactivamos modo especial
         if (specialTradeActive && positionTicket == specialTradeTicket)
         {
            specialTradeActive = false;
            waitingForSpecialTradeResult = false;
            specialTradeTicket = 0;
            Print("Operación especial 1:1 ganada. Volviendo a modo normal.");
         }
      }

      // --- Manejo de reentrada tras SL sin cruce ---
      if (reason == DEAL_REASON_SL) // Cierre por Stop Loss
      {
         // Verificar si ya hay una reentrada pendiente para esta posición
         if (!slReentry.pendingReentry)
         {
            // Guardar información para posible reentrada
            slReentry.pendingReentry = true;
            slReentry.direction = closedDirection;
            slReentry.slPrice = closePrice;
            slReentry.lossTime = TimeCurrent();

            Print("SL detectado. Preparando reentrada en dirección ",
                  (closedDirection == 1 ? "COMPRA" : "VENTA"), " a precio ", closePrice);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Verifica si se debe hacer reentrada tras SL sin cruce de EMAs   |
//+------------------------------------------------------------------+
void CheckPendingSLReentry(bool tendenciaAlcista, bool tendenciaBajista)
{
   if (!slReentry.pendingReentry)
      return;

   // Obtener estado actual de cruce EMA1/EMA2
   bool cruceEma1Ema2Up = (ema1[1] > ema2[1] && ema1[2] <= ema2[2]);
   bool cruceEma1Ema2Down = (ema1[1] < ema2[1] && ema1[2] >= ema2[2]);

   bool mismoCruceNoOcurrido = false;

   // Verificar si ha ocurrido un nuevo cruce en la dirección contraria a la reentrada
   if (slReentry.direction == 1) // La posición perdida era compra, esperamos que no haya cruce hacia abajo
   {
      if (!cruceEma1Ema2Down) // No ha ocurrido cruce hacia abajo (todavía válido para reentrada)
         mismoCruceNoOcurrido = true;
   }
   else // Era venta, esperamos que no haya cruce hacia arriba
   {
      if (!cruceEma1Ema2Up)
         mismoCruceNoOcurrido = true;
   }

   // Si no ha ocurrido cruce contrario, procedemos con reentrada
   if (mismoCruceNoOcurrido)
   {
      // Verificar que podemos abrir nueva operación
      if (CanOpenNewTrade())
      {
         // Verificar consistencia con la tendencia mayor si hay posiciones abiertas
         bool hayPosicionesAbiertas = false;
         bool hayCompraAbierta = false;
         bool hayVentaAbierta = false;

         for (int i = 0; i < PositionsTotal(); i++)
         {
            if (positionInfo.SelectByIndex(i) && positionInfo.Magic() == InpMagicNumber)
            {
               hayPosicionesAbiertas = true;
               if (positionInfo.PositionType() == POSITION_TYPE_BUY)
                  hayCompraAbierta = true;
               if (positionInfo.PositionType() == POSITION_TYPE_SELL)
                  hayVentaAbierta = true;
            }
         }

         bool reentryAllowed = false;

         if (!hayPosicionesAbiertas)
         {
            reentryAllowed = true; // Sin posiciones, cualquier reentrada es válida
         }
         else if (tendenciaAlcista && hayCompraAbierta && slReentry.direction == 1)
         {
            reentryAllowed = true; // Tendencia alcista con compras, reentrada de compra válida
         }
         else if (tendenciaBajista && hayVentaAbierta && slReentry.direction == -1)
         {
            reentryAllowed = true; // Tendencia bajista con ventas, reentrada de venta válida
         }

         if (reentryAllowed)
         {
            Print("Reentrada por SL sin cruce. Abriendo operación en dirección ",
                  (slReentry.direction == 1 ? "COMPRA" : "VENTA"));

            // Abrir la reentrada al precio del SL (usando orden de mercado)
            double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            double price = (slReentry.direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

            double slPips = InpStopLossPips;
            double tpPips = specialTradeActive ? slPips : slPips * 3;

            double slPrice = (slReentry.direction == 1) ? price - slPips * 10 * point : price + slPips * 10 * point;
            double tpPrice = (slReentry.direction == 1) ? price + tpPips * 10 * point : price - tpPips * 10 * point;

            // Calcular lote nuevamente con el saldo actual
            double balance = accountInfo.Balance();
            double riskMoney = balance * (InpRiskPercent / 100.0);
            double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
            double slInPoints = slPips * 10;
            double lot = riskMoney / (slInPoints * tickValue);
            lot = NormalizeDouble(lot, 2);

            if (lot < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
               lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            if (lot > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX))
               lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

            if (slReentry.direction == 1)
               trade.Buy(lot, _Symbol, price, slPrice, tpPrice, "Reentrada tras SL");
            else
               trade.Sell(lot, _Symbol, price, slPrice, tpPrice, "Reentrada tras SL");

            // Si la reentrada es la operación especial 1:1
            if (specialTradeActive && trade.ResultRetcode() == TRADE_RETCODE_DONE)
            {
               specialTradeTicket = trade.ResultOrder();
               waitingForSpecialTradeResult = true;
            }

            // Limpiar bandera de reentrada
            slReentry.pendingReentry = false;
         }
      }
   }
   else
   {
      // Ocurrió un cruce contrario, cancelamos la reentrada pendiente
      slReentry.pendingReentry = false;
      Print("Reentrada cancelada: ocurrió cruce contrario de EMA1/EMA2");
   }
}

//+------------------------------------------------------------------+
//| Trailing dinámico según reglas                                   |
//+------------------------------------------------------------------+
void UpdateTrailing()
{
   for (int i = 0; i < PositionsTotal(); i++)
   {
      if (!positionInfo.SelectByIndex(i))
         continue;
      if (positionInfo.Magic() != InpMagicNumber)
         continue;

      // Si es operación especial 1:1, no aplicar trailing
      if (specialTradeActive && positionInfo.Ticket() == specialTradeTicket)
         continue;

      double openPrice = positionInfo.PriceOpen();
      double currentPrice = (positionInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = positionInfo.StopLoss();
      double tp = positionInfo.TakeProfit();
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      int direction = (positionInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
      double profitPips = (currentPrice - openPrice) / point / 10 * direction;
      double originalSLPips = InpStopLossPips;
      double originalTPPips = originalSLPips * 3;

      // Determinar ratio actual de profit respecto al TP original
      double ratio = profitPips / originalTPPips;

      // Buscar el tramo de trailing: 1:3 -> SL a BE, TP a 1:4, etc.
      int level = (int)MathFloor(ratio);
      if (level >= 3 && level <= 15)
      {
         double newSLPips = 0;
         double newTPPips = originalSLPips * (level + 1);

         if (level == 3)
            newSLPips = 0; // BE
         else
            newSLPips = originalSLPips * (level - 2); // 1:4 -> SL 1:1 (30 pips), 1:5 -> SL 1:2 (60 pips), etc.

         // Calcular distancia actual al nuevo TP
         double currentTPPrice = (direction == 1) ? openPrice + newTPPips * 10 * point : openPrice - newTPPips * 10 * point;
         double distanceToNewTP = MathAbs(currentPrice - currentTPPrice);

         // Si estamos a menos de X pips del nuevo TP, mover SL/TP
         if (distanceToNewTP <= InpPipsToTrailingTP * 10 * point)
         {
            double newSLPrice = (direction == 1) ? openPrice + newSLPips * 10 * point : openPrice - newSLPips * 10 * point;
            double newTPPrice = currentTPPrice;

            // Solo modificar si mejora la posición actual
            if ((direction == 1 && newSLPrice > sl) || (direction == -1 && newSLPrice < sl) || sl == 0)
            {
               trade.PositionModify(positionInfo.Ticket(), newSLPrice, newTPPrice);
               Print("Trailing activado: nivel ", level + 1, ":1, SL a ", newSLPips, " pips, TP a ", newTPPips, " pips");
            }
         }
      }
   }
}