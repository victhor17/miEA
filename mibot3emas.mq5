//+------------------------------------------------------------------+
//|                                            TuEstrategiaCompleta.mq5 |
//|                                  Generado según reglas del usuario |
//|                                            Versión final corregida |
//+------------------------------------------------------------------+
#property copyright "Tu EA Personalizado"
#property version "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

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

int ema1Handle, ema2Handle, ema3Handle;
double ema1[], ema2[], ema3[];

datetime lastBarTime = 0;
double dailyEquityPeak;
double dailyStartBalance;
bool drawdownExceeded = false;

// Variables para pérdidas consecutivas
int consecutiveLosses = 0;
bool specialTradeActive = false;
ulong specialTradeTicket = 0;
bool waitingForSpecialTradeResult = false;

// Variables para reentrada tras SL sin cruce
struct SLReentryInfo
{
  bool pendingReentry;
  int direction;
  double slPrice;
  datetime lossTime;
};
SLReentryInfo slReentry = {false, 0, 0.0, 0};

// Variables para control de último cruce utilizado
struct LastCruceInfo
{
  int direction;    // 1 compra, -1 venta, 0 ninguno
  datetime barTime; // Tiempo de la vela donde ocurrió el cruce
};
LastCruceInfo lastCruce = {0, 0};

// Variables para cooldown después de TP
struct TPCooldown
{
  bool active;
  int direction;
  datetime blockUntilBarTime; // Bloquear hasta esta vela
};
TPCooldown tpCooldown = {false, 0, 0};

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

  // Establecer como series arrays para acceso por tiempo
  ArraySetAsSeries(ema1, true);
  ArraySetAsSeries(ema2, true);
  ArraySetAsSeries(ema3, true);

  // Inicializar control diario
  ResetDailyStats();

  trade.SetExpertMagicNumber(InpMagicNumber);

  Print("EA inicializado correctamente");
  Print("Parámetros: SL=", InpStopLossPips, " pips, Riesgo=", InpRiskPercent, "%, MaxPos=", InpMaxPositions);
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
  Print("EA finalizado. Razón: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                            |
//+------------------------------------------------------------------+
void OnTick()
{
  // Actualizar trailing dinámico en cada tick
  UpdateTrailing();

  // Verificar si alguna operación se cerró (para reentrada o pérdidas consecutivas)
  CheckClosedPositions();

  // Solo operar al cierre de vela en H1 para nuevas entradas
  if (!IsNewBar())
    return;

  // Actualizar control de drawdown diario
  UpdateDailyDrawdown();
  if (drawdownExceeded)
  {
    Print("Drawdown diario máximo alcanzado (", InpMaxDrawdownDaily, "%). Nuevas entradas bloqueadas hasta mañana.");
    return;
  }

  // Obtener valores actuales de las EMAs
  if (!GetEmaValues())
    return;

  // Determinar tendencia mayor (EMA2 vs EMA3)
  bool tendenciaAlcista = (ema2[0] > ema3[0]);
  bool tendenciaBajista = (ema2[0] < ema3[0]);

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
//| Obtiene los valores de las 3 EMAs                               |
//+------------------------------------------------------------------+
bool GetEmaValues()
{
  if (CopyBuffer(ema1Handle, 0, 0, 2, ema1) < 2)
  {
    Print("Error copiando EMA1");
    return false;
  }
  if (CopyBuffer(ema2Handle, 0, 0, 2, ema2) < 2)
  {
    Print("Error copiando EMA2");
    return false;
  }
  if (CopyBuffer(ema3Handle, 0, 0, 2, ema3) < 2)
  {
    Print("Error copiando EMA3");
    return false;
  }
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
  Print("Estadísticas diarias reseteadas. Saldo inicial: ", dailyStartBalance);
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
  if (drawdownPercent >= InpMaxDrawdownDaily && !drawdownExceeded)
  {
    drawdownExceeded = true;
    Print("ALERTA: Drawdown diario alcanzado: ", drawdownPercent, "%");
  }

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
//| Determina la dirección de las operaciones abiertas del EA       |
//+------------------------------------------------------------------+
int GetCurrentDirection()
{
  bool hasBuy = false;
  bool hasSell = false;

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

  if (hasBuy && !hasSell)
    return 1;
  if (hasSell && !hasBuy)
    return -1;
  return 0;
}

//+------------------------------------------------------------------+
//| Cambio de tendencia: SOLO si es contrario a las operaciones     |
//+------------------------------------------------------------------+
void CheckTrendChangeAndCloseAll(bool alcista, bool bajista)
{
  static bool lastAlcista = false;
  static bool lastBajista = false;

  // Detectar si hubo un cruce de EMA2/EMA3 en esta vela
  bool cruceAlcista = (alcista && !lastAlcista && lastBajista);
  bool cruceBajista = (bajista && !lastBajista && lastAlcista);

  if (!cruceAlcista && !cruceBajista)
  {
    lastAlcista = alcista;
    lastBajista = bajista;
    return;
  }

  // Obtener dirección actual de las operaciones abiertas
  int currentDirection = GetCurrentDirection();

  // Determinar si el cruce es CONTRARIO a las operaciones abiertas
  bool cruceContrario = false;

  if (cruceAlcista && currentDirection == -1)
  {
    cruceContrario = true;
    Print("Cruce alcista de EMA2/EMA3 detectado. Es CONTRARIO a las ventas abiertas.");
  }
  else if (cruceBajista && currentDirection == 1)
  {
    cruceContrario = true;
    Print("Cruce bajista de EMA2/EMA3 detectado. Es CONTRARIO a las compras abiertas.");
  }
  else if (currentDirection == 0)
  {
    cruceContrario = true;
    Print("Cruce de EMA2/EMA3 detectado sin operaciones abiertas.");
  }
  else
  {
    Print("Cruce de EMA2/EMA3 a favor de las operaciones abiertas. No se cierra nada.");
  }

  if (cruceContrario)
  {
    // Cerrar todas las posiciones del EA
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
      if (positionInfo.SelectByIndex(i))
      {
        if (positionInfo.Magic() == InpMagicNumber)
        {
          trade.PositionClose(positionInfo.Ticket());
          Print("Cerrando posición: ", positionInfo.Ticket());
        }
      }
    }

    // Resetear modo especial, reentradas pendientes y último cruce
    specialTradeActive = false;
    specialTradeTicket = 0;
    waitingForSpecialTradeResult = false;
    slReentry.pendingReentry = false;
    tpCooldown.active = false;
    lastCruce.direction = 0;
    lastCruce.barTime = 0;

    // Abrir nueva operación a favor de la NUEVA tendencia
    if (cruceAlcista)
    {
      Print("Abriendo nueva compra por cambio de tendencia alcista");
      OpenTrade(1);
      lastCruce.direction = 1;
      lastCruce.barTime = iTime(_Symbol, PERIOD_H1, 0);
    }
    else if (cruceBajista)
    {
      Print("Abriendo nueva venta por cambio de tendencia bajista");
      OpenTrade(-1);
      lastCruce.direction = -1;
      lastCruce.barTime = iTime(_Symbol, PERIOD_H1, 0);
    }
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
  {
    // Print("Límite de posiciones alcanzado: ", totalPositions, "/", InpMaxPositions);
    return false;
  }

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
  {
    Print("ERROR: Operaciones contrarias abiertas simultáneamente");
    return false;
  }

  return true;
}

//+------------------------------------------------------------------+
//| Determina dirección de entrada según reglas                     |
//+------------------------------------------------------------------+
int GetTradeDirection(bool tendenciaAlcista, bool tendenciaBajista)
{
  // Detectar cruce de EMA1 y EMA2 en la vela actual
  bool cruceEma1Ema2Up = (ema1[0] > ema2[0] && ema1[1] <= ema2[1]);
  bool cruceEma1Ema2Down = (ema1[0] < ema2[0] && ema1[1] >= ema2[1]);

  // Si no hay cruce en esta vela, salir
  if (!cruceEma1Ema2Up && !cruceEma1Ema2Down)
    return 0;

  // Determinar la dirección del cruce actual
  int currentCruceDirection = 0;
  if (cruceEma1Ema2Up)
    currentCruceDirection = 1;
  if (cruceEma1Ema2Down)
    currentCruceDirection = -1;

  // Obtener tiempo de la vela actual
  datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);

  // ========== VERIFICAR COOLDOWN POR TP ==========
  if (tpCooldown.active)
  {
    if (currentBarTime > tpCooldown.blockUntilBarTime)
    {
      tpCooldown.active = false;
      Print("Cooldown por TP finalizado.");
    }
    else
    {
      bool cruceContrario = false;
      if (tpCooldown.direction == 1 && cruceEma1Ema2Down)
        cruceContrario = true;
      if (tpCooldown.direction == -1 && cruceEma1Ema2Up)
        cruceContrario = true;

      if (!cruceContrario)
      {
        Print("Bloqueado por TP: dirección ", (tpCooldown.direction == 1 ? "COMPRA" : "VENTA"));
        return 0;
      }
      else
      {
        Print("Cruce contrario después de TP. Permitiendo entrada.");
        tpCooldown.active = false;
      }
    }
  }

  // ========== VERIFICAR POSICIONES ABIERTAS ==========
  bool hayPosicionesAbiertas = false;
  bool hayCompraAbierta = false;
  bool hayVentaAbierta = false;
  int totalPosicionesEA = 0;

  for (int i = 0; i < PositionsTotal(); i++)
  {
    if (positionInfo.SelectByIndex(i) && positionInfo.Magic() == InpMagicNumber)
    {
      hayPosicionesAbiertas = true;
      totalPosicionesEA++;
      if (positionInfo.PositionType() == POSITION_TYPE_BUY)
        hayCompraAbierta = true;
      if (positionInfo.PositionType() == POSITION_TYPE_SELL)
        hayVentaAbierta = true;
    }
  }

  // ========== DETERMINAR SI SE PERMITE LA OPERACIÓN ==========
  bool permitirOperacion = false;

  // Caso 1: No hay posiciones abiertas
  if (!hayPosicionesAbiertas)
  {
    if (lastCruce.direction != currentCruceDirection || currentBarTime > lastCruce.barTime + 3600)
    {
      permitirOperacion = true;
      Print("Sin posiciones, nuevo cruce ", (currentCruceDirection == 1 ? "alcista" : "bajista"));
    }
  }
  // Caso 2: Compras abiertas y tendencia alcista
  else if (tendenciaAlcista && hayCompraAbierta && !hayVentaAbierta)
  {
    if (currentCruceDirection == 1)
    {
      permitirOperacion = true;
      Print("Nuevo cruce alcista a favor de la tendencia. Posiciones abiertas: ", totalPosicionesEA);
    }
  }
  // Caso 3: Ventas abiertas y tendencia bajista
  else if (tendenciaBajista && hayVentaAbierta && !hayCompraAbierta)
  {
    if (currentCruceDirection == -1)
    {
      permitirOperacion = true;
      Print("Nuevo cruce bajista a favor de la tendencia. Posiciones abiertas: ", totalPosicionesEA);
    }
  }

  // Evitar doble operación en la misma vela
  if (permitirOperacion && hayPosicionesAbiertas)
  {
    if (lastCruce.direction == currentCruceDirection && currentBarTime == lastCruce.barTime)
    {
      permitirOperacion = false;
      Print("Mismo cruce en la misma vela, ignorando.");
    }
  }

  if (permitirOperacion)
  {
    lastCruce.direction = currentCruceDirection;
    lastCruce.barTime = currentBarTime;
    return currentCruceDirection;
  }

  return 0;
}

//+------------------------------------------------------------------+
//| Abre una operación                                               |
//+------------------------------------------------------------------+
void OpenTrade(int direction)
{
  double slPips = InpStopLossPips;
  double tpPips = specialTradeActive ? slPips : slPips * 3;

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

  double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

  if (lot < minLot)
    lot = minLot;
  if (lot > maxLot)
    lot = maxLot;
  lot = MathRound(lot / stepLot) * stepLot;

  string comment = specialTradeActive ? "EA_1:1" : "EA_normal";

  if (direction == 1)
    trade.Buy(lot, _Symbol, price, slPrice, tpPrice, comment);
  else
    trade.Sell(lot, _Symbol, price, slPrice, tpPrice, comment);

  if (trade.ResultRetcode() == TRADE_RETCODE_DONE)
  {
    Print("Operación abierta: ", comment, " Lote: ", lot, " Dirección: ", (direction == 1 ? "COMPRA" : "VENTA"));
    if (specialTradeActive)
    {
      specialTradeTicket = trade.ResultOrder();
      waitingForSpecialTradeResult = true;
    }
  }
  else
  {
    Print("Error al abrir operación: ", trade.ResultRetcodeDescription());
  }
}

//+------------------------------------------------------------------+
//| Verifica operaciones cerradas                                   |
//+------------------------------------------------------------------+
void CheckClosedPositions()
{
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

    static ulong lastProcessedDeal = 0;
    if (dealTicket == lastProcessedDeal)
      continue;
    lastProcessedDeal = dealTicket;

    long reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
    double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
    ulong positionTicket = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
    double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

    long posType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
    int closedDirection = (posType == DEAL_TYPE_BUY) ? 1 : -1;

    // Detectar cierre por TP
    if (reason == DEAL_REASON_TP)
    {
      datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
      tpCooldown.active = true;
      tpCooldown.direction = closedDirection;
      tpCooldown.blockUntilBarTime = currentBarTime + 3600;
      Print("TP alcanzado en ", (closedDirection == 1 ? "COMPRA" : "VENTA"), ". Cooldown activado.");
    }

    // Manejo de pérdidas consecutivas
    if (profit <= 0)
    {
      consecutiveLosses++;
      Print("Pérdida. Consecutivas: ", consecutiveLosses);

      if (specialTradeActive && positionTicket == specialTradeTicket)
      {
        specialTradeActive = true;
        waitingForSpecialTradeResult = false;
        specialTradeTicket = 0;
      }
      else
      {
        if (consecutiveLosses >= 4 && !specialTradeActive)
        {
          specialTradeActive = true;
          waitingForSpecialTradeResult = false;
          Print("Activando modo 1:1 por 4 pérdidas consecutivas");
        }
      }
    }
    else
    {
      consecutiveLosses = 0;
      if (specialTradeActive && positionTicket == specialTradeTicket)
      {
        specialTradeActive = false;
        waitingForSpecialTradeResult = false;
        specialTradeTicket = 0;
        Print("Modo 1:1 desactivado por ganancia.");
      }
    }

    // Manejo de reentrada tras SL
    if (reason == DEAL_REASON_SL)
    {
      if (!slReentry.pendingReentry)
      {
        slReentry.pendingReentry = true;
        slReentry.direction = closedDirection;
        slReentry.slPrice = closePrice;
        slReentry.lossTime = TimeCurrent();
        Print("SL detectado. Reentrada pendiente en ", (closedDirection == 1 ? "COMPRA" : "VENTA"));
      }
      // Resetear lastCruce para permitir nuevos cruces después de SL
      lastCruce.direction = 0;
      lastCruce.barTime = 0;
    }
  }
}

//+------------------------------------------------------------------+
//| Verifica reentrada tras SL                                      |
//+------------------------------------------------------------------+
void CheckPendingSLReentry(bool tendenciaAlcista, bool tendenciaBajista)
{
  if (!slReentry.pendingReentry)
    return;

  bool cruceEma1Ema2Up = (ema1[0] > ema2[0] && ema1[1] <= ema2[1]);
  bool cruceEma1Ema2Down = (ema1[0] < ema2[0] && ema1[1] >= ema2[1]);

  bool mismoCruceNoOcurrido = false;

  if (slReentry.direction == 1)
  {
    if (!cruceEma1Ema2Down)
      mismoCruceNoOcurrido = true;
  }
  else
  {
    if (!cruceEma1Ema2Up)
      mismoCruceNoOcurrido = true;
  }

  if (mismoCruceNoOcurrido)
  {
    if (CanOpenNewTrade())
    {
      bool hayCompraAbierta = false, hayVentaAbierta = false;
      for (int i = 0; i < PositionsTotal(); i++)
      {
        if (positionInfo.SelectByIndex(i) && positionInfo.Magic() == InpMagicNumber)
        {
          if (positionInfo.PositionType() == POSITION_TYPE_BUY)
            hayCompraAbierta = true;
          if (positionInfo.PositionType() == POSITION_TYPE_SELL)
            hayVentaAbierta = true;
        }
      }

      bool reentryAllowed = false;
      if (!hayCompraAbierta && !hayVentaAbierta)
        reentryAllowed = true;
      else if (tendenciaAlcista && hayCompraAbierta && slReentry.direction == 1)
        reentryAllowed = true;
      else if (tendenciaBajista && hayVentaAbierta && slReentry.direction == -1)
        reentryAllowed = true;

      if (reentryAllowed)
      {
        Print("Ejecutando reentrada por SL");
        OpenTrade(slReentry.direction);
        slReentry.pendingReentry = false;
      }
    }
  }
  else
  {
    slReentry.pendingReentry = false;
    Print("Reentrada cancelada: ocurrió cruce contrario");
  }
}

//+------------------------------------------------------------------+
//| Trailing dinámico                                                |
//+------------------------------------------------------------------+
void UpdateTrailing()
{
  for (int i = 0; i < PositionsTotal(); i++)
  {
    if (!positionInfo.SelectByIndex(i))
      continue;
    if (positionInfo.Magic() != InpMagicNumber)
      continue;
    if (specialTradeActive && positionInfo.Ticket() == specialTradeTicket)
      continue;

    double openPrice = positionInfo.PriceOpen();
    double currentPrice = (positionInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = positionInfo.StopLoss();
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    int direction = (positionInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
    double profitPips = (currentPrice - openPrice) / point / 10 * direction;
    double originalSLPips = InpStopLossPips;
    double originalTPPips = originalSLPips * 3;

    double ratio = profitPips / originalTPPips;
    int level = (int)MathFloor(ratio);

    if (level >= 3 && level <= 15)
    {
      double newSLPips = 0;
      double newTPPips = originalSLPips * (level + 1);

      if (level == 3)
        newSLPips = 0;
      else
        newSLPips = originalSLPips * (level - 2);

      double currentTPPrice = (direction == 1) ? openPrice + newTPPips * 10 * point : openPrice - newTPPips * 10 * point;
      double distanceToNewTP = MathAbs(currentPrice - currentTPPrice);

      if (distanceToNewTP <= InpPipsToTrailingTP * 10 * point)
      {
        double newSLPrice = (direction == 1) ? openPrice + newSLPips * 10 * point : openPrice - newSLPips * 10 * point;
        double newTPPrice = currentTPPrice;

        if ((direction == 1 && newSLPrice > sl) || (direction == -1 && newSLPrice < sl) || sl == 0)
        {
          trade.PositionModify(positionInfo.Ticket(), newSLPrice, newTPPrice);
          Print("Trailing: nivel ", level + 1, ":1, SL: ", newSLPips, " pips, TP: ", newTPPips, " pips");
        }
      }
    }
  }
}