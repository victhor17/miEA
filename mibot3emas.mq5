//+------------------------------------------------------------------+
//|                                            TuEstrategiaFinal.mq5   |
//|                                            Versión 3.0 - Corregida |
//+------------------------------------------------------------------+
#property copyright "Tu EA Personalizado"
#property version "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Entradas del usuario ---
input double InpRiskPercent = 1.0;      // % riesgo por operación
input int InpStopLossPips = 30;         // Stop Loss en pips
input double InpMaxDrawdownDaily = 4.0; // Drawdown diario máximo (%)
input int InpMaxPositions = 4;          // Máximo de posiciones abiertas
input int InpMagicNumber = 20250405;    // Magic Number

// --- Parámetros de las EMAs ---
input int InpEma1Period = 15;
input int InpEma2Period = 20;
input int InpEma3Period = 50;

// --- Gestión de trailing dinámico ---
input int InpPipsToTrailingTP = 20;

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

// Variables para reentrada tras SL
struct SLReentryInfo
{
  bool pendingReentry;
  int direction;
  double slPrice;
  datetime lossTime;
};
SLReentryInfo slReentry = {false, 0, 0.0, 0};

// Variables para control de último cruce de EMA1/EMA2
struct LastCruceInfo
{
  int direction; // 1 compra, -1 venta, 0 ninguno
  datetime barTime;
  bool used; // Si ya se usó para abrir operación
};
LastCruceInfo lastCruceEMA1 = {0, 0, false};

// Variables para bloqueo después de TP
struct TPBlockInfo
{
  bool active;
  int blockedDirection; // Dirección bloqueada (1 compra, -1 venta)
  datetime blockStartTime;
};
TPBlockInfo tpBlock = {false, 0, 0};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
  ema1Handle = iMA(_Symbol, PERIOD_H1, InpEma1Period, 0, MODE_EMA, PRICE_CLOSE);
  ema2Handle = iMA(_Symbol, PERIOD_H1, InpEma2Period, 0, MODE_EMA, PRICE_CLOSE);
  ema3Handle = iMA(_Symbol, PERIOD_H1, InpEma3Period, 0, MODE_EMA, PRICE_CLOSE);

  if (ema1Handle == INVALID_HANDLE || ema2Handle == INVALID_HANDLE || ema3Handle == INVALID_HANDLE)
    return (INIT_FAILED);

  ArraySetAsSeries(ema1, true);
  ArraySetAsSeries(ema2, true);
  ArraySetAsSeries(ema3, true);

  ResetDailyStats();
  trade.SetExpertMagicNumber(InpMagicNumber);

  Print("EA inicializado correctamente");
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
  UpdateTrailing();
  CheckClosedPositions();

  if (!IsNewBar())
    return;

  UpdateDailyDrawdown();
  if (drawdownExceeded)
    return;

  if (!GetEmaValues())
    return;

  // Detectar tendencia mayor
  bool tendenciaAlcista = (ema2[0] > ema3[0]);
  bool tendenciaBajista = (ema2[0] < ema3[0]);

  // VERIFICAR CRUCE DE EMA2/EMA3 (CAMBIO DE TENDENCIA) - PRIORIDAD MÁXIMA
  CheckTrendChange(tendenciaAlcista, tendenciaBajista);

  // Verificar reentrada pendiente por SL
  CheckPendingSLReentry(tendenciaAlcista, tendenciaBajista);

  // Verificar si podemos abrir nuevas operaciones
  if (!CanOpenNewTrade())
    return;

  // Determinar dirección según reglas
  int direction = GetTradeDirection(tendenciaAlcista, tendenciaBajista);
  if (direction == 0)
    return;

  OpenTrade(direction);
}

//+------------------------------------------------------------------+
//| Verifica nueva vela                                             |
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
//| Obtiene valores de EMAs                                         |
//+------------------------------------------------------------------+
bool GetEmaValues()
{
  if (CopyBuffer(ema1Handle, 0, 0, 2, ema1) < 2)
    return false;
  if (CopyBuffer(ema2Handle, 0, 0, 2, ema2) < 2)
    return false;
  if (CopyBuffer(ema3Handle, 0, 0, 2, ema3) < 2)
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
//| Actualiza drawdown diario                                       |
//+------------------------------------------------------------------+
void UpdateDailyDrawdown()
{
  double currentEquity = accountInfo.Equity();
  if (currentEquity > dailyEquityPeak)
    dailyEquityPeak = currentEquity;

  double drawdownPercent = (dailyEquityPeak - currentEquity) / dailyEquityPeak * 100.0;
  if (drawdownPercent >= InpMaxDrawdownDaily)
    drawdownExceeded = true;

  static datetime lastDay = 0;
  datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
  if (currentDay != lastDay)
  {
    lastDay = currentDay;
    ResetDailyStats();
  }
}

//+------------------------------------------------------------------+
//| Retorna dirección de las operaciones abiertas                   |
//+------------------------------------------------------------------+
int GetCurrentDirection()
{
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
  if (hasBuy && !hasSell)
    return 1;
  if (hasSell && !hasBuy)
    return -1;
  return 0;
}

//+------------------------------------------------------------------+
//| VERIFICA CRUCE DE EMA2/EMA3 Y CIERRA OPERACIONES CONTRARIAS     |
//+------------------------------------------------------------------+
void CheckTrendChange(bool alcista, bool bajista)
{
  static bool lastAlcista = false;
  static bool lastBajista = false;

  // Detectar cruce en la vela actual
  bool nuevoCruceAlcista = (alcista && !lastAlcista);
  bool nuevoCruceBajista = (bajista && !lastBajista);

  // También detectar cuando se invierte la tendencia (cruce)
  bool inversionAlcista = (alcista && lastBajista);
  bool inversionBajista = (bajista && lastAlcista);

  bool hayCambio = inversionAlcista || inversionBajista;

  if (hayCambio)
  {
    int direccionActual = GetCurrentDirection();

    // Determinar si el cambio es CONTRARIO a las operaciones abiertas
    bool cerrarOperaciones = false;

    if (inversionAlcista && direccionActual == -1) // Cruce a alcista con ventas abiertas
    {
      cerrarOperaciones = true;
      Print("CAMBIO DE TENDENCIA ALCISTA - Cerrando ventas");
    }
    else if (inversionBajista && direccionActual == 1) // Cruce a bajista con compras abiertas
    {
      cerrarOperaciones = true;
      Print("CAMBIO DE TENDENCIA BAJISTA - Cerrando compras");
    }
    else if (direccionActual == 0) // Sin operaciones abiertas
    {
      cerrarOperaciones = false;
    }

    if (cerrarOperaciones)
    {
      // Cerrar todas las posiciones
      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
        if (positionInfo.SelectByIndex(i) && positionInfo.Magic() == InpMagicNumber)
        {
          trade.PositionClose(positionInfo.Ticket());
          Print("Cerrando posición por cambio de tendencia: ", positionInfo.Ticket());
        }
      }

      // Resetear estados
      specialTradeActive = false;
      specialTradeTicket = 0;
      slReentry.pendingReentry = false;
      lastCruceEMA1.direction = 0;
      lastCruceEMA1.used = false;
      tpBlock.active = false;

      // Abrir nueva operación a favor de la nueva tendencia
      if (inversionAlcista)
      {
        Print("Abriendo nueva compra por cambio de tendencia");
        OpenTrade(1);
      }
      else if (inversionBajista)
      {
        Print("Abriendo nueva venta por cambio de tendencia");
        OpenTrade(-1);
      }
    }
  }

  lastAlcista = alcista;
  lastBajista = bajista;
}

//+------------------------------------------------------------------+
//| Verifica límites para abrir operación                           |
//+------------------------------------------------------------------+
bool CanOpenNewTrade()
{
  int totalPositions = 0;
  for (int i = 0; i < PositionsTotal(); i++)
  {
    if (positionInfo.SelectByIndex(i) && positionInfo.Magic() == InpMagicNumber)
      totalPositions++;
  }
  if (totalPositions >= InpMaxPositions)
    return false;

  // Verificar operaciones contrarias
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
  // Detectar cruce de EMA1 y EMA2
  bool cruceEma1Ema2Up = (ema1[0] > ema2[0] && ema1[1] <= ema2[1]);
  bool cruceEma1Ema2Down = (ema1[0] < ema2[0] && ema1[1] >= ema2[1]);

  if (!cruceEma1Ema2Up && !cruceEma1Ema2Down)
  {
    // No hay cruce, resetear bandera de usado
    lastCruceEMA1.used = false;
    return 0;
  }

  int currentDirection = cruceEma1Ema2Up ? 1 : -1;
  datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);

  // ========== BLOQUEO POR TP ==========
  if (tpBlock.active && currentDirection == tpBlock.blockedDirection)
  {
    Print("BLOQUEO POR TP: No se permiten ", (currentDirection == 1 ? "COMPRAS" : "VENTAS"),
          " después de TP. Esperando cruce contrario.");
    return 0;
  }

  // ========== VERIFICAR POSICIONES ABIERTAS ==========
  bool hayPosiciones = false;
  bool hayCompra = false, hayVenta = false;
  int totalPos = 0;

  for (int i = 0; i < PositionsTotal(); i++)
  {
    if (positionInfo.SelectByIndex(i) && positionInfo.Magic() == InpMagicNumber)
    {
      hayPosiciones = true;
      totalPos++;
      if (positionInfo.PositionType() == POSITION_TYPE_BUY)
        hayCompra = true;
      if (positionInfo.PositionType() == POSITION_TYPE_SELL)
        hayVenta = true;
    }
  }

  // ========== LÓGICA DE PERMISO ==========
  bool permitir = false;

  // Caso 1: Sin posiciones abiertas
  if (!hayPosiciones)
  {
    // Verificar que sea un cruce nuevo (no el mismo de la vela anterior sin usar)
    if (lastCruceEMA1.direction != currentDirection || !lastCruceEMA1.used)
    {
      permitir = true;
      Print("Nuevo cruce sin posiciones: ", (currentDirection == 1 ? "COMPRA" : "VENTA"));
    }
  }
  // Caso 2: Compras abiertas y tendencia alcista - permitir NUEVOS cruces alcistas
  else if (tendenciaAlcista && hayCompra && !hayVenta)
  {
    if (currentDirection == 1)
    {
      permitir = true;
      Print("Nuevo cruce alcista a favor. Posiciones: ", totalPos);
    }
  }
  // Caso 3: Ventas abiertas y tendencia bajista - permitir NUEVOS cruces bajistas
  else if (tendenciaBajista && hayVenta && !hayCompra)
  {
    if (currentDirection == -1)
    {
      permitir = true;
      Print("Nuevo cruce bajista a favor. Posiciones: ", totalPos);
    }
  }

  // Evitar el mismo cruce en la misma vela
  if (permitir && lastCruceEMA1.direction == currentDirection &&
      lastCruceEMA1.barTime == currentBarTime && lastCruceEMA1.used)
  {
    permitir = false;
    Print("Mismo cruce en misma vela, ignorando");
  }

  if (permitir)
  {
    lastCruceEMA1.direction = currentDirection;
    lastCruceEMA1.barTime = currentBarTime;
    lastCruceEMA1.used = true;
    return currentDirection;
  }

  return 0;
}

//+------------------------------------------------------------------+
//| Abre operación                                                   |
//+------------------------------------------------------------------+
void OpenTrade(int direction)
{
  double slPips = InpStopLossPips;
  double tpPips = specialTradeActive ? slPips : slPips * 3;

  double price = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  double slPrice = (direction == 1) ? price - slPips * 10 * point : price + slPips * 10 * point;
  double tpPrice = (direction == 1) ? price + tpPips * 10 * point : price - tpPips * 10 * point;

  // Calcular lote por riesgo
  double balance = accountInfo.Balance();
  double riskMoney = balance * (InpRiskPercent / 100.0);
  double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  double lot = riskMoney / (slPips * 10 * tickValue);
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
    Print("OPERACIÓN ABIERTA: ", comment, " Lote:", lot, " ", (direction == 1 ? "COMPRA" : "VENTA"));
    if (specialTradeActive)
      specialTradeTicket = trade.ResultOrder();
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

    static ulong lastProcessed = 0;
    if (dealTicket == lastProcessed)
      continue;
    lastProcessed = dealTicket;

    long reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
    double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
    ulong positionTicket = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
    double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

    long posType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
    int closedDirection = (posType == DEAL_TYPE_BUY) ? 1 : -1;

    // ========== CIERRE POR TP - ACTIVAR BLOQUEO ==========
    if (reason == DEAL_REASON_TP)
    {
      tpBlock.active = true;
      tpBlock.blockedDirection = closedDirection;
      tpBlock.blockStartTime = TimeCurrent();

      // Resetear el último cruce para que no se reutilice
      lastCruceEMA1.direction = 0;
      lastCruceEMA1.used = false;

      Print("TP ALCANZADO en ", (closedDirection == 1 ? "COMPRA" : "VENTA"),
            ". BLOQUEADAS nuevas ", (closedDirection == 1 ? "COMPRAS" : "VENTAS"),
            " hasta cruce contrario.");
    }

    // ========== CIERRE POR SL - REENTRADA PENDIENTE ==========
    if (reason == DEAL_REASON_SL)
    {
      if (!slReentry.pendingReentry)
      {
        slReentry.pendingReentry = true;
        slReentry.direction = closedDirection;
        slReentry.slPrice = closePrice;
        slReentry.lossTime = TimeCurrent();
        Print("SL DETECTADO. Reentrada pendiente en ", (closedDirection == 1 ? "COMPRA" : "VENTA"));
      }

      // Resetear lastCruce para permitir nuevos cruces
      lastCruceEMA1.direction = 0;
      lastCruceEMA1.used = false;
    }

    // ========== PÉRDIDAS CONSECUTIVAS ==========
    if (profit <= 0)
    {
      consecutiveLosses++;
      Print("Pérdida. Consecutivas: ", consecutiveLosses);

      if (specialTradeActive && positionTicket == specialTradeTicket)
      {
        specialTradeActive = true;
        specialTradeTicket = 0;
      }
      else if (consecutiveLosses >= 4 && !specialTradeActive)
      {
        specialTradeActive = true;
        Print("ACTIVANDO MODO 1:1 por 4 pérdidas consecutivas");
      }
    }
    else
    {
      consecutiveLosses = 0;
      if (specialTradeActive && positionTicket == specialTradeTicket)
      {
        specialTradeActive = false;
        specialTradeTicket = 0;
        Print("MODO 1:1 DESACTIVADO por ganancia");
      }
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

  // Verificar si ha ocurrido cruce contrario
  bool cruceEma1Ema2Up = (ema1[0] > ema2[0] && ema1[1] <= ema2[1]);
  bool cruceEma1Ema2Down = (ema1[0] < ema2[0] && ema1[1] >= ema2[1]);

  bool cruceContrarioOcurrido = false;

  if (slReentry.direction == 1 && cruceEma1Ema2Down)
    cruceContrarioOcurrido = true;
  if (slReentry.direction == -1 && cruceEma1Ema2Up)
    cruceContrarioOcurrido = true;

  if (cruceContrarioOcurrido)
  {
    slReentry.pendingReentry = false;
    Print("Reentrada cancelada: ocurrió cruce contrario");
    return;
  }

  // Verificar condiciones para reentrar
  if (CanOpenNewTrade())
  {
    bool hayCompra = false, hayVenta = false;
    for (int i = 0; i < PositionsTotal(); i++)
    {
      if (positionInfo.SelectByIndex(i) && positionInfo.Magic() == InpMagicNumber)
      {
        if (positionInfo.PositionType() == POSITION_TYPE_BUY)
          hayCompra = true;
        if (positionInfo.PositionType() == POSITION_TYPE_SELL)
          hayVenta = true;
      }
    }

    bool reentryAllowed = false;

    if (!hayCompra && !hayVenta)
      reentryAllowed = true;
    else if (tendenciaAlcista && hayCompra && slReentry.direction == 1)
      reentryAllowed = true;
    else if (tendenciaBajista && hayVenta && slReentry.direction == -1)
      reentryAllowed = true;

    if (reentryAllowed)
    {
      Print("EJECUTANDO REENTRADA por SL");
      OpenTrade(slReentry.direction);
      slReentry.pendingReentry = false;
    }
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

        if ((direction == 1 && newSLPrice > sl) || (direction == -1 && newSLPrice < sl) || sl == 0)
        {
          trade.PositionModify(positionInfo.Ticket(), newSLPrice, currentTPPrice);
          Print("Trailing: nivel ", level + 1, ":1");
        }
      }
    }
  }
}