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
// --- Gestión de trailing dinámico ---
input bool InpUseTrailing = true;    // Activar/Desactivar trailing dinámico
input int InpPipsToTrailingTP = 20;  // Distancia al TP para activar trailing (solo si está activado)
input int InpTrailingStartPips = 15; // Pips ganados para activar trailing (0 = desactivado)
// Agrega esta variable global en la sección de variables
bool pendingSpecialTrade = false;        // Para abrir operación 1:1 en la siguiente vela
datetime specialTradeActivationTime = 0; // Momento en que se activó el modo 1:1

// --- Gestión de riesgo y ratios ---
input double InpInitialRatio = 3.0; // Ratio beneficio inicial (ej: 3 = 1:3, 4 = 1:4, etc.)

// --- Parámetros de las EMAs ---
input int InpEma1Period = 15;
input int InpEma2Period = 20;
input int InpEma3Period = 50;

// --- Variables globales ---
CTrade trade;
CPositionInfo positionInfo;
CAccountInfo accountInfo;
datetime lastSLTime = 0; // Para evitar múltiples SL en el mismo momento
ulong lastProcessedDealTicket = 0;
datetime lastProcessedDealTime = 0;
datetime lastReversionLogTime = 0; // Para evitar logs repetidos de reversión
int reversionLogCount = 0;         // Contador de logs de reversión en la misma vela

ulong processedDeals[1000]; // Guardar hasta 1000 deals
int processedDealsCount = 0;

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
  int originalDirection; // Dirección original de la operación que perdió
  double slPrice;
  datetime lossTime;
  int reentryCount;
};
SLReentryInfo slReentry = {false, 0, 0.0, 0, 0};

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
  Print("EA finalizado. Total de deals procesados: ", processedDealsCount);
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
  CheckPendingSpecialTrade(); // ← AÑADE ESTA LÍNEA

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

// ========== FUNCIÓN PARA VERIFICAR SI UNA PÉRDIDA DEBE CONTAR (ACTUALIZADA) ==========
bool IsValidLoss(ulong dealTicket, double slPips)
{
  // Obtener el profit
  double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);

  // Si el profit es positivo, NO es pérdida válida
  if (profit >= 0)
    return false;

  // Obtener precio de apertura y cierre
  double openPrice = 0;
  double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

  // Obtener el precio de apertura de la posición
  ulong positionId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
  if (positionId > 0)
  {
    HistorySelect(0, TimeCurrent());
    int totalDeals = HistoryDealsTotal();
    for (int i = 0; i < totalDeals; i++)
    {
      ulong tempTicket = HistoryDealGetTicket(i);
      if (tempTicket == 0)
        continue;

      ulong tempPositionId = HistoryDealGetInteger(tempTicket, DEAL_POSITION_ID);
      long tempEntry = HistoryDealGetInteger(tempTicket, DEAL_ENTRY);

      if (tempPositionId == positionId && tempEntry == DEAL_ENTRY_IN)
      {
        openPrice = HistoryDealGetDouble(tempTicket, DEAL_PRICE);
        break;
      }
    }
  }

  // Obtener la dirección de la operación
  long posType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
  int direction = (posType == DEAL_TYPE_BUY) ? 1 : -1;

  // Calcular pips usando la diferencia de precios
  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  double pipSize = 10 * point; // 1 pip = 10 points

  double lossPips = 0;
  if (direction == 1) // Compra
  {
    lossPips = (openPrice - closePrice) / pipSize;
  }
  else // Venta
  {
    lossPips = (closePrice - openPrice) / pipSize;
  }

  lossPips = MathAbs(lossPips);

  // Una pérdida válida solo si está entre 20 y slPips+5 pips
  if (lossPips >= 20 && lossPips <= slPips + 5)
  {
    return true;
  }

  return false;
}

// ========== FUNCIÓN PARA VERIFICAR SI UN DEAL YA FUE PROCESADO ==========
bool IsDealAlreadyProcessed(ulong dealTicket)
{
  // Primero verificar el último procesado (optimización)
  if (dealTicket == lastProcessedDealTicket)
    return true;

  // Buscar en el array de deals procesados
  for (int i = 0; i < processedDealsCount; i++)
  {
    if (processedDeals[i] == dealTicket)
      return true;
  }

  return false;
}

// ========== FUNCIÓN PARA REGISTRAR UN DEAL COMO PROCESADO ==========
void MarkDealAsProcessed(ulong dealTicket)
{
  if (processedDealsCount < 1000)
  {
    processedDeals[processedDealsCount] = dealTicket;
    processedDealsCount++;
    lastProcessedDealTicket = dealTicket;
  }
}

// ========== FUNCIÓN PARA VERIFICAR SI DEBEMOS MOSTRAR LOG DE REVERSIÓN ==========
bool CanShowReversionLog()
{
  datetime currentTime = TimeCurrent();
  datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);

  // Resetear contador si es una nueva vela
  static datetime lastBarTimeLog = 0;
  if (currentBarTime != lastBarTimeLog)
  {
    lastBarTimeLog = currentBarTime;
    reversionLogCount = 0;
  }

  // Solo mostrar el log una vez por vela
  if (reversionLogCount == 0)
  {
    reversionLogCount++;
    return true;
  }

  return false;
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
//| Determina dirección de entrada según reglas (CON NUEVA REGLA)    |
//+------------------------------------------------------------------+

int GetTradeDirection(bool tendenciaAlcista, bool tendenciaBajista)
{
  // Detectar cruce de EMA1 y EMA2
  bool cruceEma1Ema2Up = (ema1[0] > ema2[0] && ema1[1] <= ema2[1]);
  bool cruceEma1Ema2Down = (ema1[0] < ema2[0] && ema1[1] >= ema2[1]);

  if (!cruceEma1Ema2Up && !cruceEma1Ema2Down)
  {
    return 0;
  }

  int currentDirection = cruceEma1Ema2Up ? 1 : -1;
  datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);

  // ========== BLOQUEO POR TP - ELIMINADO ==========
  // Ya no bloqueamos nada después de TP

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

  // ========== REVERSIÓN ANTICIPADA ==========
  bool operacionesContrarias = false;
  int direccionOperaciones = 0;

  if (hayCompra && !hayVenta)
    direccionOperaciones = 1;
  if (hayVenta && !hayCompra)
    direccionOperaciones = -1;

  if (tendenciaAlcista && direccionOperaciones == -1)
    operacionesContrarias = true;
  if (tendenciaBajista && direccionOperaciones == 1)
    operacionesContrarias = true;

  if (operacionesContrarias)
  {
    bool cruceAFavor = false;

    if (tendenciaAlcista && cruceEma1Ema2Up)
      cruceAFavor = true;
    if (tendenciaBajista && cruceEma1Ema2Down)
      cruceAFavor = true;

    if (cruceAFavor)
    {
      Print("🔄 REVERSIÓN ANTICIPADA: Operaciones contrarias detectadas");

      // Cerrar todas las operaciones actuales
      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
        if (positionInfo.SelectByIndex(i) && positionInfo.Magic() == InpMagicNumber)
        {
          trade.PositionClose(positionInfo.Ticket());
          Print("   Cerrando posición por reversión: ", positionInfo.Ticket());
        }
      }

      // Resetear estados
      specialTradeActive = false;
      specialTradeTicket = 0;
      slReentry.pendingReentry = false;
      slReentry.reentryCount = 0;

      // Registrar el cruce
      lastCruceEMA1.direction = currentDirection;
      lastCruceEMA1.barTime = currentBarTime;
      lastCruceEMA1.used = true;

      Print("✅ Abriendo nueva operación a favor: ", (currentDirection == 1 ? "COMPRA" : "VENTA"));
      return currentDirection;
    }
  }

  // ========== CASO 1: SIN POSICIONES ABIERTAS ==========
  if (!hayPosiciones)
  {
    // Evitar el mismo cruce en la misma vela
    if (lastCruceEMA1.direction == currentDirection &&
        lastCruceEMA1.barTime == currentBarTime && lastCruceEMA1.used)
    {
      Print("❌ Mismo cruce en misma vela, ignorando");
      return 0;
    }

    Print("✅ SIN POSICIONES: Abriendo ", (currentDirection == 1 ? "COMPRA" : "VENTA"),
          " por cruce de EMA1/EMA2");

    lastCruceEMA1.direction = currentDirection;
    lastCruceEMA1.barTime = currentBarTime;
    lastCruceEMA1.used = true;

    return currentDirection;
  }

  // ========== CASO 2: CON POSICIONES ABIERTAS Y NO CONTRARIAS ==========

  // Caso: Compras abiertas y tendencia alcista
  if (tendenciaAlcista && hayCompra && !hayVenta)
  {
    if (currentDirection == 1)
    {
      if (lastCruceEMA1.direction == 1 && lastCruceEMA1.barTime == currentBarTime && lastCruceEMA1.used)
      {
        Print("❌ Mismo cruce alcista en misma vela, ignorando");
        return 0;
      }

      Print("✅ NUEVO CRUCE ALCISTA a favor. Abriendo nueva COMPRA");

      lastCruceEMA1.direction = currentDirection;
      lastCruceEMA1.barTime = currentBarTime;
      lastCruceEMA1.used = true;

      return 1;
    }
    else
    {
      Print("❌ Cruce bajista ignorado (tendencia alcista con compras)");
      return 0;
    }
  }

  // Caso: Ventas abiertas y tendencia bajista
  if (tendenciaBajista && hayVenta && !hayCompra)
  {
    if (currentDirection == -1)
    {
      if (lastCruceEMA1.direction == -1 && lastCruceEMA1.barTime == currentBarTime && lastCruceEMA1.used)
      {
        Print("❌ Mismo cruce bajista en misma vela, ignorando");
        return 0;
      }

      Print("✅ NUEVO CRUCE BAJISTA a favor. Abriendo nueva VENTA");

      lastCruceEMA1.direction = currentDirection;
      lastCruceEMA1.barTime = currentBarTime;
      lastCruceEMA1.used = true;

      return -1;
    }
    else
    {
      Print("❌ Cruce alcista ignorado (tendencia bajista con ventas)");
      return 0;
    }
  }

  return 0;
}

//+------------------------------------------------------------------+
//| Abre una operación (con ratio inicial personalizado)            |
//+------------------------------------------------------------------+
void OpenTrade(int direction)
{
  double slPips = InpStopLossPips;
  double tpPips = specialTradeActive ? slPips : slPips * InpInitialRatio; // Usar ratio personalizado

  double price = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  double slPrice = (direction == 1) ? price - slPips * 10 * point : price + slPips * 10 * point;
  double tpPrice = (direction == 1) ? price + tpPips * 10 * point : price - tpPips * 10 * point;

  // Calcular volumen según riesgo
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

  string comment = specialTradeActive ? "EA_1:1" : "EA_" + DoubleToString(InpInitialRatio, 0) + ":1";

  if (direction == 1)
    trade.Buy(lot, _Symbol, price, slPrice, tpPrice, comment);
  else
    trade.Sell(lot, _Symbol, price, slPrice, tpPrice, comment);

  if (trade.ResultRetcode() == TRADE_RETCODE_DONE)
  {
    Print("OPERACIÓN ABIERTA: ", comment, " Lote:", lot, " ", (direction == 1 ? "COMPRA" : "VENTA"));
    Print("   SL: ", slPips, " pips | TP: ", tpPips, " pips (Ratio 1:", InpInitialRatio, ")");

    if (specialTradeActive)
      specialTradeTicket = trade.ResultOrder();
  }
  else
  {
    Print("Error al abrir operación: ", trade.ResultRetcodeDescription());
  }
}

void ReentradaPost11()
{
  Print("🔄 REENTRADA POST-1:1 - Buscando operación a favor de la tendencia");

  // Esta función se llama DESPUÉS de desactivar specialTradeActive
  // Así que las nuevas operaciones usarán el ratio normal

  if (!GetEmaValues())
  {
    Print("⚠️ Reentrada post-1:1 cancelada: No se pudieron obtener valores de EMAs");
    return;
  }

  bool tendenciaAlcista = (ema2[0] > ema3[0]);
  bool tendenciaBajista = (ema2[0] < ema3[0]);

  int direccionNueva = 0;
  if (tendenciaAlcista)
    direccionNueva = 1;
  else if (tendenciaBajista)
    direccionNueva = -1;
  else
  {
    Print("⚠️ Reentrada post-1:1 cancelada: No hay tendencia clara");
    return;
  }

  if (!CanOpenNewTrade())
  {
    Print("⚠️ Reentrada post-1:1 cancelada: Límite de posiciones alcanzado");
    return;
  }

  // Ya no hay specialTradeActive, se abre con ratio normal
  OpenTrade(direccionNueva);
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

    if (IsDealAlreadyProcessed(dealTicket))
      continue;

    long reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
    double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
    ulong positionTicket = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
    double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

    long posType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
    int closedDirection = (posType == DEAL_TYPE_BUY) ? 1 : -1;

    double slPips = InpStopLossPips;

    MarkDealAsProcessed(dealTicket);

    // ========== CIERRE POR SL ==========

    if (reason == DEAL_REASON_SL)
    {
      // Verificar si es una pérdida válida (profit negativo y >20 pips)
      bool esPerdidaValida = IsValidLoss(dealTicket, slPips);

      if (esPerdidaValida)
      {
        consecutiveLosses++;
        Print("📉 PÉRDIDA VÁLIDA por SL (", (closedDirection == 1 ? "COMPRA" : "VENTA"),
              "). Consecutivas: ", consecutiveLosses);

        // CORRECCIÓN: Si era la operación especial, desactivarla (pero mantener el modo)
        if (specialTradeActive && positionTicket == specialTradeTicket)
        {
          specialTradeActive = false; // ← CORREGIDO: antes estaba "true"
          specialTradeTicket = 0;
          Print("   Operación especial cerrada con pérdida");
        }

        // Activar nuevo modo 1:1 si llegamos a 4 pérdidas
        if (consecutiveLosses >= 4 && !specialTradeActive && !pendingSpecialTrade)
        {
          specialTradeActive = true;
          pendingSpecialTrade = true; // Marcar que debemos abrir en la siguiente vela
          specialTradeActivationTime = TimeCurrent();
          Print("⚠️ ACTIVANDO MODO 1:1 por 4 pérdidas consecutivas");
          Print("   Se abrirá operación 1:1 en la siguiente vela");
        }

        // REENTRADA POR SL - AHORA SIEMPRE se ejecuta (incluso en modo 1:1)
        if (!slReentry.pendingReentry && slReentry.reentryCount < 3)
        {
          slReentry.pendingReentry = true;
          slReentry.originalDirection = closedDirection;
          slReentry.slPrice = closePrice;
          slReentry.lossTime = TimeCurrent();
          slReentry.reentryCount++;
          Print("🔄 SL DETECTADO. Reentrada pendiente en ",
                (closedDirection == 1 ? "COMPRA" : "VENTA"));
        }
      }
      else
      {
        // Pérdida NO válida (SL en positivo o pérdida menor a 20 pips)
        Print("⚠️ SL en profit positivo o pérdida menor a 20 pips - NO se activa reentrada");

        // Resetear el contador de pérdidas si la operación cerró con ganancia
        if (profit > 0)
        {
          if (consecutiveLosses > 0)
          {
            Print("📈 SL en positivo (cierre con ganancia). Reiniciando contador de pérdidas.");
          }
          consecutiveLosses = 0;
        }
      }

      lastCruceEMA1.direction = 0;
      lastCruceEMA1.used = false;
      lastSLTime = TimeCurrent();
      continue;
    }

    // ========== CIERRE POR TP ==========
    if (reason == DEAL_REASON_TP)
    {
      Print("🎯 TP ALCANZADO en ", (closedDirection == 1 ? "COMPRA" : "VENTA"));

      lastCruceEMA1.direction = 0;
      lastCruceEMA1.used = false;

      // Resetear contador de pérdidas
      if (consecutiveLosses > 0)
      {
        Print("📈 TP - Reiniciando contador de pérdidas consecutivas (era ", consecutiveLosses, ")");
      }
      consecutiveLosses = 0;

      // Si era una operación especial 1:1, desactivar modo y abrir nueva
      if (specialTradeActive && positionTicket == specialTradeTicket)
      {
        specialTradeActive = false;
        specialTradeTicket = 0;
        pendingSpecialTrade = false; // Limpiar pendiente
        Print("MODO 1:1 DESACTIVADO por TP");

        // Abrir nueva operación a favor de la tendencia
        ReentradaPost11();
      }
      else if (specialTradeActive)
      {
        // Si el TP no era de la operación especial, igual desactivamos modo 1:1
        specialTradeActive = false;
        pendingSpecialTrade = false;
        Print("MODO 1:1 DESACTIVADO - TP alcanzado en otra operación");
      }

      continue;
    }

    // ========== CIERRE POR REVERSIÓN ==========
    if (reason == DEAL_REASON_CLIENT || reason == DEAL_REASON_EXPERT)
    {
      Print("🔄 Cierre por REVERSIÓN");

      // Verificar si es una pérdida válida
      bool esPerdidaValida = IsValidLoss(dealTicket, slPips);

      if (esPerdidaValida)
      {
        // Pérdida válida en reversión: NO afecta contador (no incrementa, no resetea)
        Print("   Reversión con pérdida válida (>20 pips) - NO afecta contador");
      }
      else
      {
        // No es pérdida válida (profit positivo o pérdida menor a 20 pips)
        // Resetear el contador de pérdidas
        if (consecutiveLosses > 0)
        {
          Print("   Reversión SIN pérdida válida. Reiniciando contador de pérdidas (era ",
                consecutiveLosses, ")");
        }
        else
        {
          Print("   Reversión SIN pérdida válida. Pérdidas consecutivas: 0");
        }
        consecutiveLosses = 0;
      }

      // Resetear reentradas pendientes siempre
      slReentry.pendingReentry = false;
      slReentry.reentryCount = 0;

      continue;
    }

    // ========== GANANCIAS (cualquier otro cierre con profit positivo) ==========
    if (profit > 0)
    {
      // Verificar si era una operación especial 1:1 (solo si no fue TP, porque TP ya se procesó arriba)
      bool eraOperacionEspecial = (specialTradeActive && positionTicket == specialTradeTicket);

      if (consecutiveLosses > 0)
      {
        Print("📈 GANANCIA registrada. Reiniciando contador de pérdidas consecutivas (era ",
              consecutiveLosses, ")");
      }
      else
      {
        Print("📈 GANANCIA registrada. Pérdidas consecutivas: 0");
      }

      consecutiveLosses = 0;

      // Si era una operación especial 1:1 (cierre por otro motivo que no sea TP)
      if (eraOperacionEspecial)
      {
        specialTradeActive = false;
        specialTradeTicket = 0;
        Print("MODO 1:1 DESACTIVADO por ganancia");

        // Abrir nueva operación a favor de la tendencia
        ReentradaPost11();
      }

      continue;
    }
  }
}

void CheckPendingSpecialTrade()
{
  if (!pendingSpecialTrade)
    return;

  // Esperar a la siguiente vela (1 hora después de la activación)
  if (TimeCurrent() - specialTradeActivationTime < 3600)
  {
    static datetime lastWaitLog = 0;
    if (TimeCurrent() - lastWaitLog > 300) // Log cada 5 minutos
    {
      lastWaitLog = TimeCurrent();
      Print("⏳ Modo 1:1 - Esperando siguiente vela para abrir operación");
    }
    return;
  }

  // Obtener valores de EMAs para conocer la tendencia
  if (!GetEmaValues())
  {
    Print("⚠️ Modo 1:1 - No se pudieron obtener EMAs, reintentando...");
    return;
  }

  bool tendenciaAlcista = (ema2[0] > ema3[0]);
  bool tendenciaBajista = (ema2[0] < ema3[0]);

  int direction = 0;
  if (tendenciaAlcista)
    direction = 1;
  else if (tendenciaBajista)
    direction = -1;
  else
  {
    Print("⚠️ Modo 1:1 - Sin tendencia clara, esperando...");
    return;
  }

  // Verificar si podemos abrir operación
  if (!CanOpenNewTrade())
  {
    Print("⚠️ Modo 1:1 - Límite de posiciones alcanzado, esperando...");
    return;
  }

  // Abrir la operación especial 1:1
  Print("🚀 EJECUTANDO OPERACIÓN ESPECIAL 1:1");
  Print("   Tendencia actual: ", (direction == 1 ? "ALCISTA" : "BAJISTA"));

  // Temporalmente marcamos que estamos abriendo la especial
  pendingSpecialTrade = false;
  OpenTrade(direction); // Esta operación usará el ratio 1:1 por la variable specialTradeActive = true
}

//+------------------------------------------------------------------+
//| Verifica reentrada tras SL                                      |
//+------------------------------------------------------------------+

void CheckPendingSLReentry(bool tendenciaAlcista, bool tendenciaBajista)
{
  if (!slReentry.pendingReentry)
    return;

  // Evitar reentradas si acaba de ocurrir un SL (esperar al menos 1 vela)
  datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
  static datetime lastReentryCheckBar = 0;

  // Solo verificar una vez por vela
  if (currentBarTime == lastReentryCheckBar)
    return;
  lastReentryCheckBar = currentBarTime;

  if (TimeCurrent() - lastSLTime < 3600)
  {
    static datetime lastWaitLogBar = 0;
    if (currentBarTime != lastWaitLogBar)
    {
      lastWaitLogBar = currentBarTime;
      Print("⏳ Reentrada: Esperando 1 hora después de SL");
    }
    return;
  }

  // ========== NUEVO: Verificar si ha ocurrido cruce contrario al ORIGINAL ==========
  // Pero ahora no cancelamos, solo evaluamos según tendencia actual

  // ========== DETERMINAR DIRECCIÓN DE REENTRADA SEGÚN TENDENCIA ACTUAL ==========
  int nuevaDireccion = 0;
  string razon = "";

  // Si la tendencia actual es alcista, la reentrada debe ser COMPRA
  if (tendenciaAlcista)
  {
    nuevaDireccion = 1;
    razon = "Tendencia actual ALCISTA";
  }
  // Si la tendencia actual es bajista, la reentrada debe ser VENTA
  else if (tendenciaBajista)
  {
    nuevaDireccion = -1;
    razon = "Tendencia actual BAJISTA";
  }
  else
  {
    // Sin tendencia clara, usar la dirección original
    nuevaDireccion = slReentry.originalDirection;
    razon = "Sin tendencia clara, usando dirección original";
  }

  // Verificar si ya hay posiciones abiertas que impidan la reentrada
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
  string bloqueoRazon = "";

  // Verificar si podemos abrir en la nueva dirección
  if (!hayCompra && !hayVenta)
  {
    reentryAllowed = true;
    bloqueoRazon = "sin posiciones abiertas";
  }
  else if (tendenciaAlcista && hayCompra && !hayVenta && nuevaDireccion == 1)
  {
    reentryAllowed = true;
    bloqueoRazon = "tendencia alcista con compras abiertas";
  }
  else if (tendenciaBajista && hayVenta && !hayCompra && nuevaDireccion == -1)
  {
    reentryAllowed = true;
    bloqueoRazon = "tendencia bajista con ventas abiertas";
  }
  else if (hayCompra && nuevaDireccion == -1)
  {
    bloqueoRazon = "hay compras abiertas, no se pueden abrir ventas";
  }
  else if (hayVenta && nuevaDireccion == 1)
  {
    bloqueoRazon = "hay ventas abiertas, no se pueden abrir compras";
  }
  else
  {
    bloqueoRazon = "condiciones no cumplidas";
  }

  if (reentryAllowed)
  {
    // Verificar también el límite de posiciones
    if (CanOpenNewTrade())
    {
      Print("✅ EJECUTANDO REENTRADA por SL");
      Print("   Dirección original: ", (slReentry.originalDirection == 1 ? "COMPRA" : "VENTA"));
      Print("   Nueva dirección según tendencia: ", (nuevaDireccion == 1 ? "COMPRA" : "VENTA"));
      Print("   Razón: ", razon);

      OpenTrade(nuevaDireccion);
      slReentry.pendingReentry = false;
      // No resetear reentryCount aquí, se resetea cuando se completa o cancela
    }
    else
    {
      Print("⚠️ Reentrada cancelada: límite de posiciones alcanzado");
      slReentry.pendingReentry = false;
    }
  }
  else
  {
    // Solo mostrar log si hay un cambio relevante
    static int lastLogDirection = 0;
    if (lastLogDirection != nuevaDireccion)
    {
      lastLogDirection = nuevaDireccion;
      Print("⏳ Reentrada pendiente - ", bloqueoRazon, ". Dirección deseada: ",
            (nuevaDireccion == 1 ? "COMPRA" : "VENTA"));
    }
  }
}

//+------------------------------------------------------------------+
//| Trailing dinámico por niveles (VERSIÓN ORIGINAL CORREGIDA)       |
//+------------------------------------------------------------------+
void UpdateTrailing()
{
  if (!InpUseTrailing)
    return;

  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  double pipSize = 10 * point;
  double slPips = InpStopLossPips;

  for (int i = 0; i < PositionsTotal(); i++)
  {
    if (!positionInfo.SelectByIndex(i))
      continue;
    if (positionInfo.Magic() != InpMagicNumber)
      continue;

    // No aplicar trailing a operaciones especiales 1:1
    if (specialTradeActive && positionInfo.Ticket() == specialTradeTicket)
      continue;

    double openPrice = positionInfo.PriceOpen();
    double currentPrice = (positionInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double currentSL = positionInfo.StopLoss();
    double currentTP = positionInfo.TakeProfit();

    int direction = (positionInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;

    // Calcular ganancia actual en múltiplos del SL (ratio alcanzado)
    double profitPips = (currentPrice - openPrice) / pipSize * direction;
    int nivelAlcanzado = (int)MathFloor(profitPips / slPips);

    // Solo actuar si hemos alcanzado al menos nivel 2 (1:2)
    if (nivelAlcanzado < 2)
      continue;

    // ========== CALCULAR NUEVO TP ==========
    // Regla: TP nuevo = nivelAlcanzado + 2
    // Ej: nivel 2 -> TP 4, nivel 3 -> TP 5, nivel 4 -> TP 6...
    int nuevoNivelTP = nivelAlcanzado + 2;
    if (nuevoNivelTP > 15)
      nuevoNivelTP = 15;

    double nuevoTPPips = slPips * nuevoNivelTP;
    double nuevoTPPrice = (direction == 1) ? openPrice + nuevoTPPips * pipSize : openPrice - nuevoTPPips * pipSize;

    // ========== CALCULAR NUEVO SL ==========
    // Regla:
    // - Nivel 2: SL no se mueve (sigue siendo el original)
    // - Nivel 3: SL = BE (distancia 0 desde open)
    // - Nivel 4: SL = 1:1 (distancia 1*SL desde open)
    // - Nivel 5: SL = 1:2 (distancia 2*SL desde open)
    // - General: SL = (nivelAlcanzado - 3) * SL

    double nuevoSLPrice = currentSL; // Por defecto, mantener SL actual
    double distanciaSLPips = -1;     // -1 indica "sin cambio"

    if (nivelAlcanzado >= 3)
    {
      distanciaSLPips = (nivelAlcanzado - 3) * slPips;
      if (distanciaSLPips < 0)
        distanciaSLPips = 0;

      if (direction == 1) // Compra
        nuevoSLPrice = openPrice + distanciaSLPips * pipSize;
      else // Venta
        nuevoSLPrice = openPrice - distanciaSLPips * pipSize;
    }

    // ========== VERIFICAR SI ES NECESARIO MODIFICAR ==========
    bool necesitaModificar = false;

    // Verificar TP
    if (direction == 1 && nuevoTPPrice > currentTP)
      necesitaModificar = true;
    if (direction == -1 && nuevoTPPrice < currentTP)
      necesitaModificar = true;

    // Verificar SL (solo si estamos en nivel >=3)
    if (nivelAlcanzado >= 3)
    {
      if (direction == 1 && nuevoSLPrice > currentSL)
        necesitaModificar = true;
      if (direction == -1 && nuevoSLPrice < currentSL)
        necesitaModificar = true;
    }

    // ========== EJECUTAR MODIFICACIÓN ==========
    if (necesitaModificar)
    {
      if (trade.PositionModify(positionInfo.Ticket(), nuevoSLPrice, nuevoTPPrice))
      {
        // Log del cambio
        string slTexto = (nivelAlcanzado < 3) ? "sin cambios" : (distanciaSLPips == 0 ? "BE" : DoubleToString(distanciaSLPips, 0) + " pips");

        Print("📈 TRAILING ACTIVADO - Nivel alcanzado: ", nivelAlcanzado, ":1");
        Print("   Ganancia actual: ", DoubleToString(profitPips, 1), " pips");
        Print("   Nuevo TP: ", nuevoNivelTP, ":1 (", nuevoTPPips, " pips)");
        Print("   Nuevo SL: ", slTexto);
      }
    }
  }
}