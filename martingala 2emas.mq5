//+------------------------------------------------------------------+
//|                                      MultiEMA_TrendTrader.mq5    |
//|                                  Copyright 2025, EA Consultant   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, EA Consultant"
#property version "1.12"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/AccountInfo.mqh>

// --- Inputs ---
input double InpRiskPercent = 0.35;        // Riesgo primera operación (%)
input double InpDailyTargetPercent = 0.7;  // Objetivo diario (%)
input double InpWeeklyTargetPercent = 4.0; // Objetivo semanal (%)
input double InpMultiplier = 1.3;          // Multiplicador de lote
input int InpMAPeriod1 = 20;               // EMA Periodo 1
input int InpMAPeriod2 = 50;               // EMA Periodo 2
input int InpVirtualSL_pips = 20;          // Virtual SL para cálculo de lote (pips)
input int InpMagicNumber = 20250331;       // Número mágico del EA
input bool InpCloseOnTrendChange = true;   // Cerrar operaciones al cambiar tendencia
input int InpStartHour = 1;                // Hora de inicio (0-23)
input bool InpUseDailyTargetTP = true;     // Usar TP basado en objetivo diario

// --- Estructura para almacenar información de posiciones ---
struct SPositionInfo
{
  ulong ticket;
  double entryPrice;
  double volume;
  ENUM_POSITION_TYPE type;
};

// --- Globales ---
CTrade g_trade;
CPositionInfo g_positionInfo;
CAccountInfo g_accountInfo;

// Objetivos
double g_dailyTargetAmount = 0;
double g_weeklyTargetAmount = 0;
double g_startBalance = 0;
double g_weeklyStartBalance = 0;

// Control de estado
double g_lastLote = 0;
double g_initialLoteDay = 0;
bool g_newDay = true;
bool g_newWeek = true;
bool g_targetReached = false;
bool g_weeklyTargetReached = false;
bool g_closingInProgress = false;
bool g_trendChangedBlock = false;
ENUM_POSITION_TYPE g_direccionBloqueada = WRONG_VALUE;

// Control de tiempo
datetime g_lastBarTime = 0;
datetime g_lastDayResetTime = 0;
datetime g_lastWeekResetTime = 0;
bool g_weekInitialized = false;

string g_symbol;
double g_point;
double g_tickValue;
double g_tickSize;
int g_handleEMA1 = INVALID_HANDLE;
int g_handleEMA2 = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Obtener todas las posiciones abiertas del EA                     |
//+------------------------------------------------------------------+
int GetPosicionesAbiertas(SPositionInfo &posiciones[])
{
  int count = 0;
  ArrayResize(posiciones, 0);

  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    if (g_positionInfo.SelectByIndex(i) && g_positionInfo.Magic() == InpMagicNumber &&
        g_positionInfo.Symbol() == g_symbol)
    {
      SPositionInfo pos;
      pos.ticket = g_positionInfo.Ticket();
      pos.entryPrice = g_positionInfo.PriceOpen();
      pos.volume = g_positionInfo.Volume();
      pos.type = g_positionInfo.PositionType();

      ArrayResize(posiciones, count + 1);
      posiciones[count] = pos;
      count++;
    }
  }
  return count;
}

//+------------------------------------------------------------------+
//| Calcular precio de salida común para todas las posiciones        |
//+------------------------------------------------------------------+
double CalcularPrecioSalidaComun(double objetivoRestante)
{
  SPositionInfo posiciones[];
  int totalPos = GetPosicionesAbiertas(posiciones);

  if (totalPos == 0)
    return 0;

  if (objetivoRestante <= 0)
    return 0;

  // Sumar (lote * precio_entrada) y lote total
  double sumaLotePorPrecio = 0;
  double sumaLote = 0;

  for (int i = 0; i < totalPos; i++)
  {
    sumaLotePorPrecio += posiciones[i].volume * posiciones[i].entryPrice;
    sumaLote += posiciones[i].volume;
  }

  // Fórmula: P_salida = [ObjetivoRestante / (ValorPunto * 10) + suma(Lote * Precio)] / suma(Lote)
  // Nota: El valorPunto está en moneda de cuenta por lote estándar
  // Ajuste: El profit en USD = volume * (precio_salida - precio_entrada) * 10 * tickValue?
  // Para simplificar, usamos la fórmula estándar de MQL5

  double valorPunto = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
  double punto = SymbolInfoDouble(g_symbol, SYMBOL_POINT);

  if (valorPunto <= 0 || punto <= 0)
    return 0;

  // Para USDJPY: valorPunto para lote 1.0 ≈ $9.xx por pip (10 puntos)
  // profit = volume * (precio_salida - precio_entrada) / punto * valorPunto
  // Despejando precio_salida:
  // precio_salida = (objetivoRestante * punto / valorPunto + suma(volume * precio_entrada)) / suma(volume)

  double precioSalida = (objetivoRestante * punto / valorPunto + sumaLotePorPrecio) / sumaLote;

  return precioSalida;
}

//+------------------------------------------------------------------+
//| Actualizar Take Profit de todas las posiciones                   |
//+------------------------------------------------------------------+
void ActualizarTakeProfit()
{
  if (!InpUseDailyTargetTP)
    return;

  int totalPosiciones = GetTotalPosiciones();
  if (totalPosiciones == 0)
    return;

  // Obtener valores actuales
  double profitRealizado = GetProfitRealizadoHoy();
  double profitFlotante = GetProfitFlotanteTotal();
  double objetivoRestante = g_dailyTargetAmount - profitRealizado - profitFlotante;

  if (objetivoRestante <= 0)
    return;

  // Calcular precio de salida común
  double precioSalida = CalcularPrecioSalidaComun(objetivoRestante);

  if (precioSalida <= 0)
    return;

  double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
  double punto = SymbolInfoDouble(g_symbol, SYMBOL_POINT);

  Print("🔧 Recalculando TP | Objetivo restante: ", DoubleToString(objetivoRestante, 2),
        " | Precio salida común: ", DoubleToString(precioSalida, 5));

  SPositionInfo posiciones[];
  int total = GetPosicionesAbiertas(posiciones);

  for (int i = 0; i < total; i++)
  {
    ulong ticket = posiciones[i].ticket;
    double entrada = posiciones[i].entryPrice;
    double lote = posiciones[i].volume;
    ENUM_POSITION_TYPE tipo = posiciones[i].type;

    // El TP de cada posición es el precio de salida común
    double tpPrice = precioSalida;

    // Verificar que el TP sea válido (en la dirección correcta)
    bool tpValido = false;
    if (tipo == POSITION_TYPE_BUY && tpPrice > ask)
      tpValido = true;
    else if (tipo == POSITION_TYPE_SELL && tpPrice < bid)
      tpValido = true;

    if (tpValido)
    {
      if (g_trade.PositionModify(ticket, 0, tpPrice))
      {
        double beneficioEsperado = 0;
        if (tipo == POSITION_TYPE_BUY)
          beneficioEsperado = lote * (tpPrice - entrada) / punto * g_tickValue;
        else
          beneficioEsperado = lote * (entrada - tpPrice) / punto * g_tickValue;

        Print("  ✅ TP actualizado | Ticket: ", ticket,
              " | Lote: ", DoubleToString(lote, 2),
              " | Beneficio esperado: ", DoubleToString(beneficioEsperado, 2),
              " | TP: ", DoubleToString(tpPrice, 5));
      }
      else
      {
        Print("  ❌ Error actualizando TP | Ticket: ", ticket, " | Error: ", GetLastError());
      }
    }
    else
    {
      Print("  ⚠️ TP inválido para ticket ", ticket, " | TP: ", DoubleToString(tpPrice, 5));
    }
  }
}

//+------------------------------------------------------------------+
//| Calcular Take Profit para una nueva operación                    |
//+------------------------------------------------------------------+
double CalcularTPParaNuevaOperacion(double lote, ENUM_ORDER_TYPE tipo)
{
  if (!InpUseDailyTargetTP)
    return 0;

  // Obtener posiciones actuales + la nueva
  SPositionInfo posiciones[];
  int totalPos = GetPosicionesAbiertas(posiciones);

  // Simular la nueva posición
  double profitRealizado = GetProfitRealizadoHoy();
  double profitFlotante = GetProfitFlotanteTotal();
  double objetivoRestante = g_dailyTargetAmount - profitRealizado - profitFlotante;

  if (objetivoRestante <= 0)
    return 0;

  // Calcular suma de lote * precio incluyendo la nueva operación
  double sumaVolumenPorPrecio = 0;
  double sumaVolumen = 0;
  double precioActual = (tipo == ORDER_TYPE_BUY) ? SymbolInfoDouble(g_symbol, SYMBOL_ASK) : SymbolInfoDouble(g_symbol, SYMBOL_BID);

  for (int i = 0; i < totalPos; i++)
  {
    sumaVolumenPorPrecio += posiciones[i].volume * posiciones[i].entryPrice;
    sumaVolumen += posiciones[i].volume;
  }

  // Agregar la nueva operación
  sumaVolumenPorPrecio += lote * precioActual;
  sumaVolumen += lote;

  double punto = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
  double valorPunto = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);

  if (valorPunto <= 0 || punto <= 0)
    return 0;

  // Calcular precio de salida común
  double precioSalida = (objetivoRestante * punto / valorPunto + sumaVolumenPorPrecio) / sumaVolumen;

  Print("📊 Cálculo TP nueva operación | Lote: ", DoubleToString(lote, 2),
        " | Precio actual: ", DoubleToString(precioActual, 5),
        " | Precio salida común: ", DoubleToString(precioSalida, 5),
        " | Objetivo restante: ", DoubleToString(objetivoRestante, 2));

  return precioSalida;
}

//+------------------------------------------------------------------+
//| Obtener el inicio de la semana (lunes a la hora de inicio)       |
//+------------------------------------------------------------------+
datetime GetWeekStart(datetime time)
{
  MqlDateTime dt;
  TimeToStruct(time, dt);

  int daysFromMonday = dt.day_of_week;
  if (daysFromMonday == 0)
    daysFromMonday = 7;
  daysFromMonday--;

  datetime monday = time - daysFromMonday * 86400;

  MqlDateTime dtMonday;
  TimeToStruct(monday, dtMonday);
  dtMonday.hour = InpStartHour;
  dtMonday.min = 0;
  dtMonday.sec = 0;

  return StructToTime(dtMonday);
}

//+------------------------------------------------------------------+
//| Verificar si es hora de operar (después de la hora de inicio)    |
//+------------------------------------------------------------------+
bool EsHoraOperar(MqlDateTime &dt)
{
  if (dt.hour > InpStartHour)
    return true;
  if (dt.hour == InpStartHour && dt.min >= 0)
    return true;
  return false;
}

//+------------------------------------------------------------------+
//| Verificar si es nueva semana                                     |
//+------------------------------------------------------------------+
bool EsNuevaSemana(datetime currentTime)
{
  if (!g_weekInitialized)
    return true;

  datetime currentWeekStart = GetWeekStart(currentTime);
  datetime lastWeekStart = GetWeekStart(g_lastWeekResetTime);

  return (currentWeekStart > lastWeekStart);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
  g_symbol = Symbol();
  g_point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
  g_tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
  g_tickSize = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);

  g_trade.SetExpertMagicNumber(InpMagicNumber);
  g_trade.SetDeviationInPoints(10);
  g_trade.SetTypeFilling(ORDER_FILLING_FOK);

  if (InpRiskPercent <= 0 || InpDailyTargetPercent <= 0 || InpMultiplier <= 0 || InpWeeklyTargetPercent <= 0)
  {
    Print("❌ Error: Inputs inválidos (deben ser > 0)");
    return (INIT_PARAMETERS_INCORRECT);
  }

  if (InpStartHour < 0 || InpStartHour > 23)
  {
    Print("❌ Error: Hora de inicio inválida (debe estar entre 0 y 23)");
    return (INIT_PARAMETERS_INCORRECT);
  }

  g_handleEMA1 = iMA(g_symbol, PERIOD_H1, InpMAPeriod1, 0, MODE_EMA, PRICE_CLOSE);
  g_handleEMA2 = iMA(g_symbol, PERIOD_H1, InpMAPeriod2, 0, MODE_EMA, PRICE_CLOSE);

  if (g_handleEMA1 == INVALID_HANDLE || g_handleEMA2 == INVALID_HANDLE)
  {
    Print("❌ Error al crear handles de EMA. Error: ", GetLastError());
    return (INIT_FAILED);
  }

  g_startBalance = g_accountInfo.Balance();
  g_weeklyStartBalance = g_startBalance;
  g_dailyTargetAmount = g_startBalance * InpDailyTargetPercent / 100.0;
  g_weeklyTargetAmount = g_startBalance * InpWeeklyTargetPercent / 100.0;
  g_lastLote = 0;
  g_initialLoteDay = 0;
  g_targetReached = false;
  g_weeklyTargetReached = false;
  g_closingInProgress = false;
  g_trendChangedBlock = false;
  g_direccionBloqueada = WRONG_VALUE;
  g_newDay = true;
  g_newWeek = true;
  g_weekInitialized = false;
  g_lastDayResetTime = 0;
  g_lastWeekResetTime = 0;
  g_lastBarTime = iTime(g_symbol, PERIOD_H1, 0);

  Print("🚀 EA INICIALIZADO");
  Print("📊 Símbolo: ", g_symbol);
  Print("💰 Balance inicial: ", DoubleToString(g_startBalance, 2));
  Print("🎯 Objetivo diario: ", DoubleToString(g_dailyTargetAmount, 2), " (", InpDailyTargetPercent, "%)");
  Print("🎯 Objetivo semanal: ", DoubleToString(g_weeklyTargetAmount, 2), " (", InpWeeklyTargetPercent, "%)");
  Print("🔢 Número mágico: ", InpMagicNumber);
  Print("📈 EMA1: ", InpMAPeriod1, " | EMA2: ", InpMAPeriod2);
  Print("⚙️ Multiplicador: ", InpMultiplier, " | Riesgo: ", InpRiskPercent, "%");
  Print("🔀 Cerrar al cambiar tendencia: ", InpCloseOnTrendChange ? "SÍ ✅" : "NO ❌");
  Print("⏰ Hora de inicio: ", InpStartHour, ":00");
  Print("🎯 TP por objetivo diario (Opción E - TP Común): ", InpUseDailyTargetTP ? "SÍ ✅" : "NO ❌");

  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  if (g_handleEMA1 != INVALID_HANDLE)
    IndicatorRelease(g_handleEMA1);
  if (g_handleEMA2 != INVALID_HANDLE)
    IndicatorRelease(g_handleEMA2);
  Print("🛑 EA desinicializado. Razón: ", reason);
}

//+------------------------------------------------------------------+
//| Obtener valor de EMA                                             |
//+------------------------------------------------------------------+
double GetEMA(int handle, int index)
{
  double buffer[1];
  if (CopyBuffer(handle, 0, index, 1, buffer) == 1)
    return buffer[0];
  return 0;
}

//+------------------------------------------------------------------+
//| Obtener todas las posiciones abiertas del EA (simple count)      |
//+------------------------------------------------------------------+
int GetTotalPosiciones()
{
  int count = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    if (g_positionInfo.SelectByIndex(i) && g_positionInfo.Magic() == InpMagicNumber &&
        g_positionInfo.Symbol() == g_symbol)
      count++;
  }
  return count;
}

//+------------------------------------------------------------------+
//| Obtener profit flotante total                                    |
//+------------------------------------------------------------------+
double GetProfitFlotanteTotal()
{
  double profit = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    if (g_positionInfo.SelectByIndex(i) && g_positionInfo.Magic() == InpMagicNumber &&
        g_positionInfo.Symbol() == g_symbol)
    {
      profit += g_positionInfo.Profit();
    }
  }
  return profit;
}

//+------------------------------------------------------------------+
//| Obtener profit realizado desde una fecha                         |
//+------------------------------------------------------------------+
double GetProfitRealizadoDesde(datetime desde)
{
  double profit = 0;
  HistorySelect(desde, TimeCurrent() + 86400);
  int total = HistoryDealsTotal();

  for (int i = 0; i < total; i++)
  {
    ulong ticket = HistoryDealGetTicket(i);
    if (ticket > 0 && HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagicNumber &&
        HistoryDealGetString(ticket, DEAL_SYMBOL) == g_symbol &&
        HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
    {
      profit += HistoryDealGetDouble(ticket, DEAL_PROFIT);
    }
  }
  return profit;
}

//+------------------------------------------------------------------+
//| Profit realizado hoy                                             |
//+------------------------------------------------------------------+
double GetProfitRealizadoHoy()
{
  datetime inicioDia = GetDayStart(TimeCurrent());
  return GetProfitRealizadoDesde(inicioDia);
}

//+------------------------------------------------------------------+
//| Profit realizado en la semana                                    |
//+------------------------------------------------------------------+
double GetProfitRealizadoSemana()
{
  datetime inicioSemana = GetWeekStart(TimeCurrent());
  return GetProfitRealizadoDesde(inicioSemana);
}

//+------------------------------------------------------------------+
//| Obtener inicio del día (a la hora configurada)                   |
//+------------------------------------------------------------------+
datetime GetDayStart(datetime time)
{
  MqlDateTime dt;
  TimeToStruct(time, dt);
  dt.hour = InpStartHour;
  dt.min = 0;
  dt.sec = 0;
  return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Verificar si es nuevo día                                        |
//+------------------------------------------------------------------+
bool EsNuevoDia(datetime currentTime)
{
  datetime currentDayStart = GetDayStart(currentTime);
  datetime lastDayStart = GetDayStart(g_lastDayResetTime);
  return (currentDayStart > lastDayStart);
}

//+------------------------------------------------------------------+
//| Obtener la dirección de las posiciones existentes                |
//+------------------------------------------------------------------+
ENUM_POSITION_TYPE GetDireccionPosicionesExistentes()
{
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    if (g_positionInfo.SelectByIndex(i) && g_positionInfo.Magic() == InpMagicNumber &&
        g_positionInfo.Symbol() == g_symbol)
    {
      return (ENUM_POSITION_TYPE)g_positionInfo.PositionType();
    }
  }
  return WRONG_VALUE;
}

//+------------------------------------------------------------------+
//| Verificar si hay posiciones en contra de una dirección           |
//+------------------------------------------------------------------+
bool HayPosicionesEnContraDe(ENUM_POSITION_TYPE direccion)
{
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    if (g_positionInfo.SelectByIndex(i) && g_positionInfo.Magic() == InpMagicNumber &&
        g_positionInfo.Symbol() == g_symbol)
    {
      if (g_positionInfo.PositionType() != direccion)
        return true;
    }
  }
  return false;
}

//+------------------------------------------------------------------+
//| Verificar si la última posición tiene profit negativo            |
//+------------------------------------------------------------------+
bool UltimaPosicionNegativa()
{
  datetime ultimaHora = 0;
  ulong ultimoTicket = 0;

  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    if (g_positionInfo.SelectByIndex(i) && g_positionInfo.Magic() == InpMagicNumber &&
        g_positionInfo.Symbol() == g_symbol)
    {
      datetime openTime = g_positionInfo.Time();
      if (openTime > ultimaHora)
      {
        ultimaHora = openTime;
        ultimoTicket = g_positionInfo.Ticket();
      }
    }
  }

  if (ultimoTicket > 0 && g_positionInfo.SelectByTicket(ultimoTicket))
    return (g_positionInfo.Profit() < 0);

  return false;
}

//+------------------------------------------------------------------+
//| Cerrar todas las posiciones                                      |
//+------------------------------------------------------------------+
void CerrarTodasLasPosiciones(string razon)
{
  int cerradas = 0;
  int errores = 0;

  Print("🔒 ", razon, " - Cerrando todas las posiciones...");

  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    if (g_positionInfo.SelectByIndex(i) && g_positionInfo.Magic() == InpMagicNumber &&
        g_positionInfo.Symbol() == g_symbol)
    {
      ulong ticket = g_positionInfo.Ticket();
      if (g_trade.PositionClose(ticket))
      {
        cerradas++;
        Print("  🧹 Cerrada posición #", ticket);
      }
      else
      {
        errores++;
        Print("  ❌ Error cerrando #", ticket, " | Código: ", GetLastError());
      }
    }
  }

  if (cerradas > 0)
    Print("✅ Total cerradas: ", cerradas, " posiciones");
  else
    Print("⚠️ No se encontraron posiciones");
}

//+------------------------------------------------------------------+
//| Calcular lote basado en riesgo % con SL virtual                  |
//+------------------------------------------------------------------+
double CalcularLotePorRiesgo()
{
  double balance = g_accountInfo.Balance();
  double riesgoEnDinero = balance * InpRiskPercent / 100.0;
  double slEnPuntos = InpVirtualSL_pips * 10.0;
  double valorPunto = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);

  if (valorPunto <= 0)
    return 0;

  double lote = riesgoEnDinero / (slEnPuntos * valorPunto);

  double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
  double minLote = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
  double maxLote = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);

  if (step <= 0)
    step = 0.01;
  lote = MathFloor(lote / step) * step;
  if (lote < minLote)
    lote = minLote;
  if (lote > maxLote)
    lote = maxLote;

  return NormalizeDouble(lote, 2);
}

//+------------------------------------------------------------------+
//| Abrir posición con TP calculado (Opción E)                       |
//+------------------------------------------------------------------+
void AbrirPosicionConTP(ENUM_ORDER_TYPE tipo)
{
  if (g_lastLote <= 0)
  {
    Print("❌ Error: lote inválido ", g_lastLote);
    return;
  }

  double precio = (tipo == ORDER_TYPE_BUY) ? SymbolInfoDouble(g_symbol, SYMBOL_ASK) : SymbolInfoDouble(g_symbol, SYMBOL_BID);

  double tpPrice = CalcularTPParaNuevaOperacion(g_lastLote, tipo);

  bool success = false;
  string tipoStr = "";

  if (tipo == ORDER_TYPE_BUY)
  {
    tipoStr = "COMPRA 🟢";
    if (InpUseDailyTargetTP && tpPrice > 0)
      success = g_trade.Buy(g_lastLote, g_symbol, precio, 0, tpPrice, "EMA_Trend");
    else
      success = g_trade.Buy(g_lastLote, g_symbol, precio, 0, 0, "EMA_Trend");
  }
  else
  {
    tipoStr = "VENTA 🔴";
    if (InpUseDailyTargetTP && tpPrice > 0)
      success = g_trade.Sell(g_lastLote, g_symbol, precio, 0, tpPrice, "EMA_Trend");
    else
      success = g_trade.Sell(g_lastLote, g_symbol, precio, 0, 0, "EMA_Trend");
  }

  if (success)
  {
    ulong ticket = g_trade.ResultOrder();
    Print("✅ Orden enviada: ", tipoStr, " | Ticket: ", ticket,
          " | Lote: ", DoubleToString(g_lastLote, 2),
          " | Precio: ", DoubleToString(precio, 5),
          (tpPrice > 0 ? " | TP: " + DoubleToString(tpPrice, 5) : ""));
  }
  else
  {
    Print("❌ Error al enviar orden: ", GetLastError());
  }
}

//+------------------------------------------------------------------+
//| Verificar si hay cambio de tendencia                             |
//+------------------------------------------------------------------+
bool HayCambioTendencia()
{
  double ema1_prev = GetEMA(g_handleEMA1, 1);
  double ema2_prev = GetEMA(g_handleEMA2, 1);
  double ema1_prev2 = GetEMA(g_handleEMA1, 2);
  double ema2_prev2 = GetEMA(g_handleEMA2, 2);

  if (ema1_prev == 0 || ema2_prev == 0 || ema1_prev2 == 0 || ema2_prev2 == 0)
    return false;

  bool prevAlcista = (ema1_prev > ema2_prev);
  bool prevBajista = (ema1_prev < ema2_prev);
  bool prev2Alcista = (ema1_prev2 > ema2_prev2);
  bool prev2Bajista = (ema1_prev2 < ema2_prev2);

  if ((prev2Alcista && prevBajista) || (prev2Bajista && prevAlcista))
    return true;

  return false;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
  if (g_closingInProgress)
    return;

  datetime currentBarTime = iTime(g_symbol, PERIOD_H1, 0);
  if (currentBarTime == g_lastBarTime)
    return;
  g_lastBarTime = currentBarTime;

  MqlDateTime dt;
  TimeToStruct(currentBarTime, dt);

  // ========== VERIFICAR HORA DE OPERAR ==========
  if (!EsHoraOperar(dt))
  {
    if (dt.hour == InpStartHour - 1 && dt.min == 0)
      Print("⏰ Esperando hora de inicio: ", InpStartHour, ":00");
    return;
  }

  // ========== REINICIO SEMANAL ==========
  if (EsNuevaSemana(currentBarTime))
  {
    g_weeklyStartBalance = g_accountInfo.Balance();
    g_weeklyTargetAmount = g_weeklyStartBalance * InpWeeklyTargetPercent / 100.0;
    g_weeklyTargetReached = false;
    g_lastWeekResetTime = currentBarTime;
    g_weekInitialized = true;
    g_newWeek = true;
    g_targetReached = false;
    g_lastLote = 0;
    g_initialLoteDay = 0;
    g_trendChangedBlock = false;
    g_direccionBloqueada = WRONG_VALUE;

    Print("\n📆═══════════════════════════════════════════════════════════════════");
    Print("📆 NUEVA SEMANA | ", TimeToString(currentBarTime));
    Print("💰 Balance inicio semana: ", DoubleToString(g_weeklyStartBalance, 2));
    Print("🎯 Objetivo semanal: ", DoubleToString(g_weeklyTargetAmount, 2), " (", InpWeeklyTargetPercent, "%)");
    Print("📆═══════════════════════════════════════════════════════════════════\n");
  }

  // ========== REINICIO DIARIO ==========
  if (EsNuevoDia(currentBarTime))
  {
    g_startBalance = g_accountInfo.Balance();
    g_dailyTargetAmount = g_startBalance * InpDailyTargetPercent / 100.0;
    g_lastLote = 0;
    g_initialLoteDay = 0;
    g_targetReached = false;
    g_trendChangedBlock = false;
    g_direccionBloqueada = WRONG_VALUE;
    g_newDay = true;
    g_lastDayResetTime = currentBarTime;

    Print("\n📅═══════════════════════════════════════════════════════════════════");
    Print("📅 NUEVO DÍA | ", TimeToString(currentBarTime));
    Print("💰 Balance: ", DoubleToString(g_startBalance, 2));
    Print("🎯 Objetivo diario: ", DoubleToString(g_dailyTargetAmount, 2));
    Print("📅═══════════════════════════════════════════════════════════════════\n");
  }

  g_newDay = false;
  g_newWeek = false;

  // ========== VERIFICAR OBJETIVO SEMANAL ==========
  if (g_weeklyTargetReached)
  {
    Print("📆 Objetivo semanal alcanzado - No se opera");
    return;
  }

  if (g_targetReached)
    return;

  // ========== OBTENER TENDENCIA ==========
  double ema1 = GetEMA(g_handleEMA1, 0);
  double ema2 = GetEMA(g_handleEMA2, 0);
  if (ema1 == 0 || ema2 == 0)
    return;

  bool tendenciaAlcista = (ema1 > ema2);
  bool tendenciaBajista = (ema1 < ema2);
  string tendenciaStr = tendenciaAlcista ? "ALCISTA 🔼" : (tendenciaBajista ? "BAJISTA 🔽" : "NEUTRAL ⏸️");

  // ========== CALCULAR PROFITS ==========
  double flotanteTotal = GetProfitFlotanteTotal();
  double profitRealizadoDia = GetProfitRealizadoHoy();
  double profitRealizadoSemana = GetProfitRealizadoSemana();
  double profitTotalDia = flotanteTotal + profitRealizadoDia;
  double profitTotalSemana = profitRealizadoSemana + flotanteTotal;
  int posicionesAbiertas = GetTotalPosiciones();

  // ========== VERIFICAR OBJETIVO SEMANAL ==========
  if (profitTotalSemana >= g_weeklyTargetAmount && !g_weeklyTargetReached)
  {
    g_weeklyTargetReached = true;
    g_targetReached = true;
    g_closingInProgress = true;

    Print("\n🏆═══════════════════════════════════════════════════════════════════");
    Print("🏆 OBJETIVO SEMANAL ALCANZADO");
    Print("💰 Profit: ", DoubleToString(profitTotalSemana, 2), " / ", DoubleToString(g_weeklyTargetAmount, 2));
    Print("🏆═══════════════════════════════════════════════════════════════════\n");

    CerrarTodasLasPosiciones("Objetivo semanal");

    g_closingInProgress = false;
    return;
  }

  // ========== VERIFICAR OBJETIVO DIARIO ==========
  if (profitTotalDia >= g_dailyTargetAmount && !g_targetReached)
  {
    g_targetReached = true;
    g_closingInProgress = true;

    Print("\n🎯═══════════════════════════════════════════════════════════════════");
    Print("🎯 OBJETIVO DIARIO ALCANZADO");
    Print("💰 Profit: ", DoubleToString(profitTotalDia, 2), " / ", DoubleToString(g_dailyTargetAmount, 2));
    Print("🎯═══════════════════════════════════════════════════════════════════\n");

    CerrarTodasLasPosiciones("Objetivo diario");

    g_closingInProgress = false;
    return;
  }

  // ========== GESTIÓN DE CAMBIO DE TENDENCIA ==========
  bool hayCambioTendencia = HayCambioTendencia();

  if (posicionesAbiertas > 0 && hayCambioTendencia)
  {
    if (InpCloseOnTrendChange)
    {
      g_closingInProgress = true;

      Print("\n⚠️═══════════════════════════════════════════════════════════════════");
      Print("⚠️ CAMBIO DE TENDENCIA - Cerrando posiciones");
      Print("📊 Nueva tendencia: ", tendenciaStr);
      Print("⚠️═══════════════════════════════════════════════════════════════════\n");

      CerrarTodasLasPosiciones("Cambio de tendencia");
      g_trendChangedBlock = false;
      g_direccionBloqueada = WRONG_VALUE;

      g_closingInProgress = false;
      return;
    }
    else
    {
      ENUM_POSITION_TYPE direccionExistente = GetDireccionPosicionesExistentes();

      if (!g_trendChangedBlock)
      {
        g_trendChangedBlock = true;
        g_direccionBloqueada = direccionExistente;

        string dirStr = (g_direccionBloqueada == POSITION_TYPE_BUY) ? "COMPRA 🟢" : "VENTA 🔴";

        Print("\n⚠️═══════════════════════════════════════════════════════════════════");
        Print("⚠️ CAMBIO DE TENDENCIA - Sin cierre");
        Print("📊 Nueva tendencia: ", tendenciaStr);
        Print("✅ SÓLO se abren: ", dirStr);
        Print("⚠️═══════════════════════════════════════════════════════════════════\n");
      }
    }
  }

  // ========== DECISIÓN DE APERTURA ==========
  bool abrirOperacion = false;
  ENUM_ORDER_TYPE direccionPermitida = WRONG_VALUE;
  string razonApertura = "";
  bool puedeAbrir = true;

  if (posicionesAbiertas == 0)
  {
    if (tendenciaAlcista)
      direccionPermitida = ORDER_TYPE_BUY;
    else if (tendenciaBajista)
      direccionPermitida = ORDER_TYPE_SELL;
    else
      puedeAbrir = false;
  }
  else
  {
    if (InpCloseOnTrendChange)
    {
      if (tendenciaAlcista)
        direccionPermitida = ORDER_TYPE_BUY;
      else if (tendenciaBajista)
        direccionPermitida = ORDER_TYPE_SELL;
      else
        puedeAbrir = false;
    }
    else
    {
      if (g_trendChangedBlock)
      {
        if (g_direccionBloqueada == POSITION_TYPE_BUY)
          direccionPermitida = ORDER_TYPE_BUY;
        else if (g_direccionBloqueada == POSITION_TYPE_SELL)
          direccionPermitida = ORDER_TYPE_SELL;
        else
          puedeAbrir = false;
      }
      else
      {
        if (tendenciaAlcista)
          direccionPermitida = ORDER_TYPE_BUY;
        else if (tendenciaBajista)
          direccionPermitida = ORDER_TYPE_SELL;
        else
          puedeAbrir = false;
      }
    }
  }

  if (puedeAbrir && direccionPermitida != WRONG_VALUE)
  {
    if (HayPosicionesEnContraDe((ENUM_POSITION_TYPE)direccionPermitida))
    {
      puedeAbrir = false;
    }
  }

  if (puedeAbrir && direccionPermitida != WRONG_VALUE)
  {
    if (posicionesAbiertas == 0)
    {
      abrirOperacion = true;
      razonApertura = "Primera operación 🆕";
      double lote = CalcularLotePorRiesgo();
      if (lote > 0)
      {
        g_lastLote = lote;
        g_initialLoteDay = lote;
        Print("📊 Lote inicial día: ", DoubleToString(g_initialLoteDay, 2), " (riesgo ", InpRiskPercent, "%)");
      }
      else
      {
        puedeAbrir = false;
        Print("❌ Error calculando lote inicial");
      }
    }
    else
    {
      if (flotanteTotal < 0)
      {
        if (UltimaPosicionNegativa())
        {
          abrirOperacion = true;
          razonApertura = "Profit negativo (" + DoubleToString(flotanteTotal, 2) + ") + multiplicador ➕";
          double nuevoLote = g_lastLote * InpMultiplier;

          double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
          if (step <= 0)
            step = 0.01;
          nuevoLote = MathFloor(nuevoLote / step) * step;
          nuevoLote = NormalizeDouble(nuevoLote, 2);

          if (nuevoLote > 0)
          {
            Print("🔢 Multiplicador: ", DoubleToString(g_lastLote, 2), " → ", DoubleToString(nuevoLote, 2));
            g_lastLote = nuevoLote;
          }
          else
          {
            puedeAbrir = false;
            Print("❌ Error: lote calculado inválido");
          }
        }
      }
    }
  }

  // ========== EJECUTAR APERTURA ==========
  if (abrirOperacion && puedeAbrir && direccionPermitida != WRONG_VALUE && g_lastLote > 0)
  {
    string tipoStr = (direccionPermitida == ORDER_TYPE_BUY) ? "COMPRA 🟢" : "VENTA 🔴";
    Print("📈 ", razonApertura, " | ", tipoStr);
    AbrirPosicionConTP(direccionPermitida);

    // Después de abrir la nueva operación, actualizar TP de todas las existentes
    if (InpUseDailyTargetTP && posicionesAbiertas > 0)
    {
      ActualizarTakeProfit();
    }
  }
  else if (posicionesAbiertas > 0 && !abrirOperacion && (dt.min == 0 || dt.min == 30))
  {
    string dirPermitidaStr = "NINGUNA";
    if (direccionPermitida == ORDER_TYPE_BUY)
      dirPermitidaStr = "COMPRA";
    if (direccionPermitida == ORDER_TYPE_SELL)
      dirPermitidaStr = "VENTA";

    Print("📊 Pos:", posicionesAbiertas, " | Flot:", DoubleToString(flotanteTotal, 1),
          " | Dia:", DoubleToString(profitTotalDia, 1), "/", DoubleToString(g_dailyTargetAmount, 1),
          " | Sem:", DoubleToString(profitTotalSemana, 1), "/", DoubleToString(g_weeklyTargetAmount, 1),
          " | Dir:", dirPermitidaStr);
  }
}

//+------------------------------------------------------------------+