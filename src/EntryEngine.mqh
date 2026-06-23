//+------------------------------------------------------------------+
//|                                                EntryEngine.mqh   |
//|                         Trend Flowing EA — Module 3               |
//|                 Limit Order Entry + SL/TP/Lot Calculation          |
//+------------------------------------------------------------------+
#ifndef ENTRY_ENGINE_MQH
#define ENTRY_ENGINE_MQH

#include "TrendDetector.mqh"    // ENUM_TREND_DIR
#include "SetupDetector.mqh"    // SetupState
#include <Trade\Trade.mqh>      // CTrade

//+------------------------------------------------------------------+
//| EntryState struct                                                  |
//+------------------------------------------------------------------+
struct EntryState
{
   bool           orderPending;     // bekleyen limit emir var mı?
   ulong          orderTicket;      // MT5 order ticket
   double         entryPrice;       // limit fiyatı (fvgMid)
   double         stopLoss;         // SL fiyatı
   double         takeProfit1;      // TP1 fiyatı (1.5R)
   double         lotSize;          // hesaplanan lot
   int            barsSinceEntry;   // emir kaç bardır bekliyor
   bool           entryFired;       // emir doldu mu?
   string         rejectReason;
   datetime       lastUpdateTime;
};

//+------------------------------------------------------------------+
//| CEntryEngine                                                      |
//+------------------------------------------------------------------+
class CEntryEngine
{
private:
   string          m_symbol;
   long            m_magic;
   ENUM_TIMEFRAMES m_ltfTF;       // 15M — bar tracking
   int             m_hATR;        // ATR(14) on 15M

   //--- Parameters (set via Init)
   double          m_riskPercent;
   int             m_slBuffer;
   double          m_slAtrMinMult;
   double          m_slAtrMaxMult;
   double          m_tp1RR;
   int             m_maxOpenTrades;
   int             m_fvgMaxBars;
   bool            m_useSessionFilter;
   int             m_londonStart, m_londonEnd;
   int             m_nyStart, m_nyEnd;

   EntryState      m_state;
   CTrade          m_trade;
   datetime        m_lastLTFBar;
   datetime        m_blockedSetupTime;
   double          m_blockedSetupMid;
   ENUM_TREND_DIR  m_blockedSetupDir;

   //--- Internal
   bool            IsNewLTFBar();
   bool            CheckSpread(int maxSpread);
   bool            CheckSession();
   bool            CheckLimitPrice(ENUM_TREND_DIR dir, double entry);
   int             CountPositions();
   int             CountPendingOrders();
   bool            HasExistingOrder();
   double          GetATRValue();
   double          CalcLotSize(double balance, double slDistance);
   bool            SendLimitOrder(ENUM_TREND_DIR dir);
   bool            IsBlockedSetup(const SetupState &ss) const;
   void            BlockSetup(const SetupState &ss, string reason);
   void            ClearBlockedSetup();
   void            CheckOrderFilled();
   void            CancelPendingOrder(const SetupState &ss, string reason = "ORDER_CANCELLED");
   void            ResetState();

public:
                   CEntryEngine();
                  ~CEntryEngine();
   bool            Init(string sym, long magic, ENUM_TIMEFRAMES ltfTF,
                        double riskPct, int slBuf, double slAtrMin, double slAtrMax,
                        double tp1rr, int maxTrades, int fvgMaxBars,
                        bool useSessionFilter,
                        int londonS, int londonE, int nyS, int nyE);
   void            Deinit();
   bool            Update(const SetupState &ss, double balance, int maxSpread, bool allowNewEntry = true);

   EntryState      GetState()     const { return m_state; }
   bool            IsPending()    const { return m_state.orderPending; }
   bool            IsFired()      const { return m_state.entryFired; }
};

//+------------------------------------------------------------------+
//| Constructor / Destructor                                          |
//+------------------------------------------------------------------+
CEntryEngine::CEntryEngine()
   : m_hATR(INVALID_HANDLE),
     m_lastLTFBar(0),
     m_blockedSetupTime(0),
     m_blockedSetupMid(0),
     m_blockedSetupDir(TREND_NONE)
{
   ZeroMemory(m_state);
}

CEntryEngine::~CEntryEngine() { Deinit(); }

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
bool CEntryEngine::Init(string sym, long magic, ENUM_TIMEFRAMES ltfTF,
                         double riskPct, int slBuf, double slAtrMin, double slAtrMax,
                         double tp1rr, int maxTrades, int fvgMaxBars,
                         bool useSessionFilter,
                         int londonS, int londonE, int nyS, int nyE)
{
   m_symbol       = sym;
   m_magic        = magic;
   m_ltfTF        = ltfTF;
   m_riskPercent  = riskPct;
   m_slBuffer     = slBuf;
   m_slAtrMinMult = slAtrMin;
   m_slAtrMaxMult = slAtrMax;
   m_tp1RR        = tp1rr;
   m_maxOpenTrades = maxTrades;
   m_fvgMaxBars   = fvgMaxBars;
   m_useSessionFilter = useSessionFilter;
   m_londonStart  = londonS;
   m_londonEnd    = londonE;
   m_nyStart      = nyS;
   m_nyEnd        = nyE;

   //--- ATR handle on LTF
   m_hATR = iATR(m_symbol, m_ltfTF, 14);
   if(m_hATR == INVALID_HANDLE)
   {
      PrintFormat("[EntryEngine] ATR handle failed: %d", GetLastError());
      return false;
   }

   //--- Configure CTrade
   m_trade.SetExpertMagicNumber(m_magic);
   m_trade.SetDeviationInPoints(10);
   m_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   ZeroMemory(m_state);
   m_lastLTFBar = 0;
   ClearBlockedSetup();

   PrintFormat("[EntryEngine] OK: %s magic=%d risk=%.1f%% SL_buf=%d ATR_mult=[%.1f,%.1f] TP1=%.1fR maxTrades=%d sessionFilter=%s",
               m_symbol, m_magic, m_riskPercent, m_slBuffer,
               m_slAtrMinMult, m_slAtrMaxMult, m_tp1RR, m_maxOpenTrades,
               (m_useSessionFilter ? "ON" : "OFF"));
   return true;
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void CEntryEngine::Deinit()
{
   if(m_hATR != INVALID_HANDLE)
   {
      IndicatorRelease(m_hATR);
      m_hATR = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| New 15M bar check                                                 |
//+------------------------------------------------------------------+
bool CEntryEngine::IsNewLTFBar()
{
   datetime t[];
   if(CopyTime(m_symbol, m_ltfTF, 0, 1, t) != 1) return false;
   if(t[0] == m_lastLTFBar) return false;
   m_lastLTFBar = t[0];
   return true;
}

//+------------------------------------------------------------------+
//| Spread check                                                      |
//+------------------------------------------------------------------+
bool CEntryEngine::CheckSpread(int maxSpread)
{
   int spread = (int)SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
   if(spread > maxSpread)
   {
      m_state.rejectReason = StringFormat("ENTRY_REJECT | SPREAD | current=%d max=%d", spread, maxSpread);
      PrintFormat("[EntryEngine] %s", m_state.rejectReason);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Session check — London (08-12 GMT) or NY (13-17 GMT)              |
//+------------------------------------------------------------------+
bool CEntryEngine::CheckSession()
{
   if(!m_useSessionFilter)
      return true;

   MqlDateTime dt;
   TimeGMT(dt);
   int hour = dt.hour;

   bool london = (hour >= m_londonStart && hour < m_londonEnd);
   bool ny     = (hour >= m_nyStart && hour < m_nyEnd);

   if(!london && !ny)
   {
      m_state.rejectReason = StringFormat("ENTRY_REJECT | SESSION | hour=%d", hour);
      PrintFormat("[EntryEngine] %s", m_state.rejectReason);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Limit price validity check                                       |
//+------------------------------------------------------------------+
bool CEntryEngine::CheckLimitPrice(ENUM_TREND_DIR dir, double entry)
{
   double tickSize = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0)
      tickSize = _Point;

   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);

   if(dir == TREND_LONG && entry >= (ask - tickSize * 0.5))
   {
      m_state.rejectReason = StringFormat("ENTRY_REJECT | MISSED_LIMIT | ask=%.5f entry=%.5f", ask, entry);
      PrintFormat("[EntryEngine] %s", m_state.rejectReason);
      return false;
   }

   if(dir == TREND_SHORT && entry <= (bid + tickSize * 0.5))
   {
      m_state.rejectReason = StringFormat("ENTRY_REJECT | MISSED_LIMIT | bid=%.5f entry=%.5f", bid, entry);
      PrintFormat("[EntryEngine] %s", m_state.rejectReason);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Count positions with our magic number on this symbol              |
//+------------------------------------------------------------------+
int CEntryEngine::CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == m_symbol &&
         PositionGetInteger(POSITION_MAGIC) == m_magic)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count pending orders with our magic number on this symbol         |
//+------------------------------------------------------------------+
int CEntryEngine::CountPendingOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == m_symbol &&
         OrderGetInteger(ORDER_MAGIC) == m_magic)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if we already have an order/position on this symbol+magic   |
//+------------------------------------------------------------------+
bool CEntryEngine::HasExistingOrder()
{
   return (CountPositions() > 0 || CountPendingOrders() > 0);
}

//+------------------------------------------------------------------+
//| Get ATR(14) value from 15M (last completed bar)                   |
//+------------------------------------------------------------------+
double CEntryEngine::GetATRValue()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(m_hATR, 0, 0, 3, atr) < 3) return 0;
   return atr[1];  // last completed bar
}

//+------------------------------------------------------------------+
//| Lot calculation:                                                   |
//| lot = (balance × risk%) / (slDistance / _Point × tickValue)       |
//+------------------------------------------------------------------+
double CEntryEngine::CalcLotSize(double balance, double slDistance)
{
   if(slDistance <= 0) return 0;

   double tickSize  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0;

   double riskMoney = balance * m_riskPercent / 100.0;
   double slTicks   = slDistance / tickSize;
   double lot       = riskMoney / (slTicks * tickValue);

   //--- Broker limits
   double minLot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0)
      lot = MathFloor(lot / lotStep) * lotStep;

   lot = NormalizeDouble(lot, 2);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

//+------------------------------------------------------------------+
//| Send limit order                                                   |
//+------------------------------------------------------------------+
bool CEntryEngine::SendLimitOrder(ENUM_TREND_DIR dir)
{
   int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   double entry = NormalizeDouble(m_state.entryPrice, digits);
   double sl    = NormalizeDouble(m_state.stopLoss, digits);
   double tp    = NormalizeDouble(m_state.takeProfit1, digits);
   double lot   = m_state.lotSize;

   bool result = false;

   if(dir == TREND_LONG)
   {
      result = m_trade.BuyLimit(lot, entry, m_symbol, sl, tp, ORDER_TIME_GTC, 0,
                                StringFormat("TF_Long_FVG_%.5f", entry));
   }
   else if(dir == TREND_SHORT)
   {
      result = m_trade.SellLimit(lot, entry, m_symbol, sl, tp, ORDER_TIME_GTC, 0,
                                 StringFormat("TF_Short_FVG_%.5f", entry));
   }

   if(result)
   {
      m_state.orderTicket  = m_trade.ResultOrder();
      m_state.orderPending = true;
      m_state.barsSinceEntry = 0;
      ClearBlockedSetup();
      PrintFormat("[EntryEngine] ✓ %s Limit: ticket=%d entry=%.5f SL=%.5f TP1=%.5f lot=%.2f",
                  (dir == TREND_LONG ? "BUY" : "SELL"),
                  m_state.orderTicket, entry, sl, tp, lot);
   }
   else
   {
      m_state.rejectReason = StringFormat("OrderSend failed: %d — %s",
                                          m_trade.ResultRetcode(),
                                          m_trade.ResultRetcodeDescription());
      PrintFormat("[EntryEngine] ✗ %s", m_state.rejectReason);
   }

   return result;
}

//+------------------------------------------------------------------+
//| Blocked setup helpers                                            |
//+------------------------------------------------------------------+
bool CEntryEngine::IsBlockedSetup(const SetupState &ss) const
{
   if(m_blockedSetupTime == 0 || !ss.setupReady)
      return false;

   return (ss.fvgTime == m_blockedSetupTime &&
           ss.setupDirection == m_blockedSetupDir &&
           MathAbs(ss.fvgMid - m_blockedSetupMid) <= (_Point * 0.5));
}

void CEntryEngine::BlockSetup(const SetupState &ss, string reason)
{
   m_blockedSetupTime = ss.fvgTime;
   m_blockedSetupMid  = ss.fvgMid;
   m_blockedSetupDir  = ss.setupDirection;

   PrintFormat("[EntryEngine] SETUP_BLOCKED until new FVG: %s", reason);
}

void CEntryEngine::ClearBlockedSetup()
{
   m_blockedSetupTime = 0;
   m_blockedSetupMid  = 0;
   m_blockedSetupDir  = TREND_NONE;
}

//+------------------------------------------------------------------+
//| Check if pending order was filled (became a position)             |
//+------------------------------------------------------------------+
void CEntryEngine::CheckOrderFilled()
{
   if(!m_state.orderPending || m_state.orderTicket == 0) return;

   //--- Check if order still exists in pending orders
   bool found = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == m_state.orderTicket)
      { found = true; break; }
   }

   if(!found)
   {
      //--- Order no longer pending — check if it became a position
      bool isPosition = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) == m_symbol &&
            PositionGetInteger(POSITION_MAGIC) == m_magic)
         {
            isPosition = true;
            break;
         }
      }

      if(isPosition)
      {
         m_state.entryFired   = true;
         m_state.orderPending = false;
         PrintFormat("[EntryEngine] ★ Order FILLED: ticket=%d", m_state.orderTicket);
      }
      else
      {
         //--- Order was cancelled (externally or by broker)
         PrintFormat("[EntryEngine] Order disappeared: ticket=%d — resetting", m_state.orderTicket);
         ResetState();
      }
   }
}

//+------------------------------------------------------------------+
//| Cancel pending order via OrderDelete                               |
//+------------------------------------------------------------------+
void CEntryEngine::CancelPendingOrder(const SetupState &ss, string reason)
{
   if(!m_state.orderPending || m_state.orderTicket == 0) return;

   if(m_trade.OrderDelete(m_state.orderTicket))
   {
      PrintFormat("[EntryEngine] ✗ Order cancelled: ticket=%d bars=%d",
                  m_state.orderTicket, m_state.barsSinceEntry);
   }
   else
   {
      PrintFormat("[EntryEngine] OrderDelete failed: ticket=%d err=%d",
                  m_state.orderTicket, GetLastError());
   }
   if(ss.setupReady)
      BlockSetup(ss, reason);
   ResetState();
}

//+------------------------------------------------------------------+
//| Reset entry state                                                  |
//+------------------------------------------------------------------+
void CEntryEngine::ResetState()
{
   m_state.orderPending   = false;
   m_state.orderTicket    = 0;
   m_state.entryPrice     = 0;
   m_state.stopLoss       = 0;
   m_state.takeProfit1    = 0;
   m_state.lotSize        = 0;
   m_state.barsSinceEntry = 0;
   m_state.entryFired     = false;
   m_state.rejectReason   = "";
}

//+------------------------------------------------------------------+
//| Update — main entry point                                         |
//| Called from OnTick() when setupReady=true                         |
//+------------------------------------------------------------------+
bool CEntryEngine::Update(const SetupState &ss, double balance, int maxSpread, bool allowNewEntry)
{
   m_state.lastUpdateTime = TimeCurrent();
   m_state.rejectReason   = "";

   //--- If order already fired (position open), check if still alive
   //--- Position management is Module 5's job
   if(m_state.entryFired)
   {
      bool positionStillOpen = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) == m_symbol &&
            PositionGetInteger(POSITION_MAGIC) == m_magic)
         { positionStillOpen = true; break; }
      }
      if(!positionStillOpen)
      {
         if(ss.setupReady)
            BlockSetup(ss, "POSITION_CLOSED");
         PrintFormat("[EntryEngine] Position closed - state reset");
         ResetState();
      }
      else return true;  // pozisyon hâlâ açık, Modül 5 yönetiyor
   }

   //--- If we have a pending order, track its lifecycle
   if(m_state.orderPending)
   {
      //--- Check if filled
      CheckOrderFilled();
      if(m_state.entryFired) return true;  // just got filled

      //--- Bar age tracking on new 15M bar
      if(IsNewLTFBar())
      {
         m_state.barsSinceEntry++;

         //--- Cancel if FVG max bars exceeded
         if(m_state.barsSinceEntry >= m_fvgMaxBars)
         {
            PrintFormat("[EntryEngine] ✗ Order expired: bars=%d >= max=%d",
                        m_state.barsSinceEntry, m_fvgMaxBars);
            CancelPendingOrder(ss, "ORDER_EXPIRED");
            return true;
         }
      }
      return true;  // order still alive, waiting to fill
   }

   if(!ss.setupReady)
   {
      ClearBlockedSetup();
      return true;
   }

   if(IsBlockedSetup(ss))
      return true;

   if(m_blockedSetupTime != 0)
      ClearBlockedSetup();

   //--- Keep state synchronized even when new entries are temporarily blocked
   if(!allowNewEntry)
      return true;

   //--- ADIM 1: Pre-entry checks
   //--- 1a) Spread
   if(!CheckSpread(maxSpread)) return true;

   //--- 1b) Session
   if(!CheckSession()) return true;

   //--- 1c) Existing order/position on this symbol
   if(HasExistingOrder())
   {
      m_state.rejectReason = "ENTRY_REJECT | EXISTING_ORDER";
      PrintFormat("[EntryEngine] %s", m_state.rejectReason);
      return true;
   }

   //--- 1d) Max open trades across all symbols
   int totalPos = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == m_magic)
         totalPos++;
   }
   if(totalPos >= m_maxOpenTrades)
   {
      m_state.rejectReason = StringFormat("ENTRY_REJECT | MAX_TRADES | open=%d max=%d", totalPos, m_maxOpenTrades);
      PrintFormat("[EntryEngine] %s", m_state.rejectReason);
      return true;
   }

   //--- ADIM 2: SL Calculation
   double entry = ss.fvgMid;
   if(!CheckLimitPrice(ss.setupDirection, entry))
   {
      BlockSetup(ss, m_state.rejectReason);
      return true;
   }

   double sl = 0;
   double slDist = 0;

   if(ss.setupDirection == TREND_LONG)
   {
      sl = ss.sweepPrice - (m_slBuffer * _Point);
      slDist = entry - sl;
   }
   else if(ss.setupDirection == TREND_SHORT)
   {
      sl = ss.sweepPrice + (m_slBuffer * _Point);
      slDist = sl - entry;
   }

   if(slDist <= 0)
   {
      m_state.rejectReason = StringFormat("ENTRY_REJECT | INVALID_SL_DISTANCE | entry=%.5f sl=%.5f", entry, sl);
      PrintFormat("[EntryEngine] %s", m_state.rejectReason);
      BlockSetup(ss, m_state.rejectReason);
      return true;
   }

   //--- ATR clamp
   double atr = GetATRValue();
   if(atr <= 0)
   {
      m_state.rejectReason = "ATR verisi alınamadı";
      return true;
   }

   double slMin = atr * m_slAtrMinMult;
   double slMax = atr * m_slAtrMaxMult;

   //--- SL too tight → expand to minimum
   if(slDist < slMin)
   {
      PrintFormat("[EntryEngine] ENTRY_INFO | SL_TOO_TIGHT | dist=%.5f min=%.5f ATR=%.5f — expanding", slDist, slMin, atr);
      if(ss.setupDirection == TREND_LONG)
         sl = entry - slMin;
      else
         sl = entry + slMin;
      slDist = slMin;
   }

   //--- SL too wide -> clamp to ATR max and let lot sizing scale down
   if(slDist > slMax)
   {
      double rawSlDist = slDist;
      if(ss.setupDirection == TREND_LONG)
         sl = entry - slMax;
      else
         sl = entry + slMax;
      slDist = slMax;

      PrintFormat("[EntryEngine] SL_WIDE_CLAMPED: dist=%.5f->%.5f ATR=%.5f lot will be reduced",
                  rawSlDist, slDist, atr);
   }

   //--- ADIM 3: Lot Calculation
   double lot = CalcLotSize(balance, slDist);
   if(lot <= 0)
   {
      m_state.rejectReason = "Lot hesabı başarısız";
      return true;
   }

   //--- ADIM 4: TP1 Calculation
   double tp1 = 0;
   if(ss.setupDirection == TREND_LONG)
      tp1 = entry + (slDist * m_tp1RR);
   else
      tp1 = entry - (slDist * m_tp1RR);

   //--- Store in state
   m_state.entryPrice  = entry;
   m_state.stopLoss    = sl;
   m_state.takeProfit1 = tp1;
   m_state.lotSize     = lot;

   //--- ADIM 5: Send Limit Order
   bool orderSent = SendLimitOrder(ss.setupDirection);
   if(!orderSent && m_trade.ResultRetcode() == TRADE_RETCODE_INVALID_PRICE)
      BlockSetup(ss, m_state.rejectReason);

   return true;
}

#endif // ENTRY_ENGINE_MQH
