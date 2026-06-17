//+------------------------------------------------------------------+
//|                                            GridTradingEA.mq5     |
//|                                    Copyright 2025, Your Name     |
//|                                             https://www.yoursite |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Your Name"
#property link "https://www.yoursite"
#property version "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- parámetros de entrada
input double InpLotSize = 0.01;                  // Lote fijo
input int InpNumberOfOrders = 11;                // Número de órdenes por lado
input int InpDistancePoints = 50;                // Distancia entre órdenes (puntos)
input double InpProfitTarget = 4.0;              // Profit target (ambas direcciones) en USD
input double InpOneDirectionProfitTarget = 10.0; // Profit target (una dirección) en USD
input int InpTrailingStopPoints = 100;           // Trailing stop (puntos)
input int InpMagicNumber = 123456;               // Número mágico

//--- variables globales
CTrade trade;

//+------------------------------------------------------------------+
//| Función de inicialización                                         |
//+------------------------------------------------------------------+
int OnInit()
{
  // Configurar el objeto trade
  trade.SetExpertMagicNumber(InpMagicNumber);
  trade.SetDeviationInPoints(50);
  trade.SetTypeFilling(ORDER_FILLING_IOC);

  // Si no hay posiciones ni órdenes pendientes, colocar rejilla
  if (PositionsTotal() == 0 && CountPendingOrders() == 0)
  {
    PlaceGrid();
  }
  else if (PositionsTotal() == 0 && CountPendingOrders() > 0)
  {
    // Si hay órdenes pendientes pero sin posiciones, las cancelamos y recolocamos
    CancelAllPendingOrders();
    PlaceGrid();
  }
  // Si hay posiciones, se gestionarán en OnTick

  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Función de desinicialización                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  // No se requiere limpieza específica
}

//+------------------------------------------------------------------+
//| Función principal OnTick                                          |
//+------------------------------------------------------------------+
void OnTick()
{
  ManagePositions();
}

//+------------------------------------------------------------------+
//| Gestiona las posiciones abiertas                                  |
//+------------------------------------------------------------------+
void ManagePositions()
{
  int totalPos = PositionsTotal();
  int buyCount = 0, sellCount = 0;
  double totalProfit = 0.0;

  // Variables estáticas para el trailing stop
  static double highestPriceSeen = 0.0;
  static double lowestPriceSeen = DBL_MAX;
  static bool onlyBuysMode = false;
  static bool onlySellsMode = false;

  // Recorrer las posiciones
  for (int i = 0; i < totalPos; i++)
  {
    ulong ticket = PositionGetTicket(i);
    if (PositionSelectByTicket(ticket))
    {
      if (PositionGetString(POSITION_SYMBOL) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
        totalProfit += PositionGetDouble(POSITION_PROFIT);
        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if (posType == POSITION_TYPE_BUY)
        {
          buyCount++;
        }
        else if (posType == POSITION_TYPE_SELL)
        {
          sellCount++;
        }
      }
    }
  }

  // Si no hay posiciones
  if (buyCount == 0 && sellCount == 0)
  {
    // Resetear modos
    onlyBuysMode = false;
    onlySellsMode = false;
    highestPriceSeen = 0.0;
    lowestPriceSeen = DBL_MAX;

    // Si no hay órdenes pendientes, colocar nueva rejilla
    if (CountPendingOrders() == 0)
      PlaceGrid();
    return;
  }

  // Determinar si solo hay un lado
  bool isOnlyBuys = (buyCount > 0 && sellCount == 0);
  bool isOnlySells = (sellCount > 0 && buyCount == 0);

  // --- Caso: ambas direcciones abiertas ---
  if (buyCount > 0 && sellCount > 0)
  {
    // Resetear modos de una dirección
    onlyBuysMode = false;
    onlySellsMode = false;
    highestPriceSeen = 0.0;
    lowestPriceSeen = DBL_MAX;

    // Verificar profit target
    if (totalProfit > InpProfitTarget)
    {
      CloseAllPositions();
      CancelAllPendingOrders();
      PlaceGrid();
    }
    return;
  }

  // --- Caso: solo compras ---
  if (isOnlyBuys)
  {
    // Inicializar modo si es la primera vez
    if (!onlyBuysMode)
    {
      onlyBuysMode = true;
      onlySellsMode = false;
      // Establecer precio más alto desde el momento actual
      highestPriceSeen = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      lowestPriceSeen = DBL_MAX;
    }
    else
    {
      // Actualizar máximo alcanzado
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if (currentBid > highestPriceSeen)
        highestPriceSeen = currentBid;
    }

    // Verificar profit target para una dirección
    if (totalProfit > InpOneDirectionProfitTarget)
    {
      CloseAllPositions();
      CancelAllPendingOrders();
      PlaceGrid();
      return;
    }

    // Verificar trailing stop
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double trailingStopPrice = highestPriceSeen - InpTrailingStopPoints * point;
    if (currentBid <= trailingStopPrice)
    {
      CloseAllPositions();
      CancelAllPendingOrders();
      PlaceGrid();
      return;
    }
  }

  // --- Caso: solo ventas ---
  if (isOnlySells)
  {
    if (!onlySellsMode)
    {
      onlySellsMode = true;
      onlyBuysMode = false;
      lowestPriceSeen = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      highestPriceSeen = 0.0;
    }
    else
    {
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if (currentAsk < lowestPriceSeen)
        lowestPriceSeen = currentAsk;
    }

    if (totalProfit > InpOneDirectionProfitTarget)
    {
      CloseAllPositions();
      CancelAllPendingOrders();
      PlaceGrid();
      return;
    }

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double trailingStopPrice = lowestPriceSeen + InpTrailingStopPoints * point;
    if (currentAsk >= trailingStopPrice)
    {
      CloseAllPositions();
      CancelAllPendingOrders();
      PlaceGrid();
      return;
    }
  }
}

//+------------------------------------------------------------------+
//| Coloca la rejilla de órdenes stop                                |
//+------------------------------------------------------------------+
bool PlaceGrid()
{
  // Cancelar órdenes pendientes existentes
  CancelAllPendingOrders();

  MqlTick tick;
  if (!SymbolInfoTick(_Symbol, tick))
    return false;

  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
  double distance = InpDistancePoints * point;
  double ask = tick.ask;
  double bid = tick.bid;

  // Asegurar que la distancia mínima sea al menos el nivel de stops del broker
  double minDist = MathMax(distance, stopsLevel);

  for (int i = 1; i <= InpNumberOfOrders; i++)
  {
    double buyPrice = ask + MathMax(i * distance, minDist);
    double sellPrice = bid - MathMax(i * distance, minDist);

    // Enviar Buy Stop
    if (!SendStopOrder(ORDER_TYPE_BUY_STOP, buyPrice, InpLotSize, "BuyStop " + IntegerToString(i)))
      return false;

    // Enviar Sell Stop
    if (!SendStopOrder(ORDER_TYPE_SELL_STOP, sellPrice, InpLotSize, "SellStop " + IntegerToString(i)))
      return false;
  }
  return true;
}

//+------------------------------------------------------------------+
//| Envía una orden stop (compra o venta)                            |
//+------------------------------------------------------------------+
bool SendStopOrder(ENUM_ORDER_TYPE type, double price, double volume, string comment)
{
  trade.SetExpertMagicNumber(InpMagicNumber);
  trade.SetDeviationInPoints(50);

  bool result = false;
  if (type == ORDER_TYPE_BUY_STOP)
    result = trade.BuyStop(volume, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment);
  else if (type == ORDER_TYPE_SELL_STOP)
    result = trade.SellStop(volume, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment);

  if (!result)
    Print("Error al enviar orden stop: ", trade.ResultRetcodeDescription());

  return result;
}

//+------------------------------------------------------------------+
//| Cuenta las órdenes pendientes del EA                             |
//+------------------------------------------------------------------+
int CountPendingOrders()
{
  int count = 0;
  int total = OrdersTotal();
  for (int i = 0; i < total; i++)
  {
    ulong ticket = OrderGetTicket(i);
    if (OrderSelect(ticket))
    {
      if (OrderGetString(ORDER_SYMBOL) == _Symbol &&
          OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
        ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
        if (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
          count++;
      }
    }
  }
  return count;
}

//+------------------------------------------------------------------+
//| Cancela todas las órdenes pendientes del EA                      |
//+------------------------------------------------------------------+
void CancelAllPendingOrders()
{
  int total = OrdersTotal();
  for (int i = total - 1; i >= 0; i--)
  {
    ulong ticket = OrderGetTicket(i);
    if (OrderSelect(ticket))
    {
      if (OrderGetString(ORDER_SYMBOL) == _Symbol &&
          OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
        ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
        if (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
        {
          trade.OrderDelete(ticket);
        }
      }
    }
  }
}

//+------------------------------------------------------------------+
//| Cierra todas las posiciones del EA                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
  int total = PositionsTotal();
  for (int i = total - 1; i >= 0; i--)
  {
    ulong ticket = PositionGetTicket(i);
    if (PositionSelectByTicket(ticket))
    {
      if (PositionGetString(POSITION_SYMBOL) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
        trade.PositionClose(ticket);
      }
    }
  }
}
//+------------------------------------------------------------------+