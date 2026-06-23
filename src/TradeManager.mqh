//+------------------------------------------------------------------+
//|                                              TradeManager.mqh    |
//|                         Trend Flowing EA — Module 5               |
//|              BE + TP1 Partial Close + Trailing + Time Exit        |
//+------------------------------------------------------------------+
#ifndef TRADE_MANAGER_MQH
#define TRADE_MANAGER_MQH

#include "EntryEngine.mqh"      // EntryState
#include <Trade\Trade.mqh>      // CTrade

//+------------------------------------------------------------------+
//| TradeState struct                                                  |
//+------------------------------------------------------------------+
struct TradeState
{
   bool           hasPosition;       // yönetilecek pozisyon var mı?
   ulong          positionTicket;    // pozisyon ticket
   double         openPrice;         // giriş fiyatı
   double         currentSL;         // anlık SL
   double         originalSL;        // giriş anındaki SL — değişmez
   double         tp1Price;          // TP1 seviyesi
   double         lotSize;           // toplam lot
   bool           tp1Hit;            // TP1 tetiklendi mi?
   bool           beActive;          // breakeven aktif mi?
   double         trailingATR;       // son trailing ATR değeri
   string         rejectReason;
   datetime       lastUpdateTime;
};

//+------------------------------------------------------------------+
//| CTradeManager                                                     |
//+------------------------------------------------------------------+
class CTradeManager
{
private:
   string          m_symbol;
   long            m_magic;
   ENUM_TIMEFRAMES m_ltfTF;
   int             m_hATR;

   double          m_beTriggerRR;
   double          m_trailingATRMult;
   bool            m_useTimeExit;

   TradeState      m_state;
   CTrade          m_trade;

   bool            FindPosition();
   void            CheckBreakeven();
   void            CheckTP1();
   void            CheckTrailing();
   void            CheckTimeExit();
   void            ResetState();

public:
                   CTradeManager();
                  ~CTradeManager();
   bool            Init(string sym, long magic, ENUM_TIMEFRAMES ltfTF,
                        double trailMult, double beTriggerRR, bool useTimeExit);
   void            Deinit();
   bool            Update(const EntryState &es);

   TradeState      GetState()      const { return m_state; }
   bool            HasPosition()   const { return m_state.hasPosition; }
};

//+------------------------------------------------------------------+
//| Constructor / Destructor                                          |
//+------------------------------------------------------------------+
CTradeManager::CTradeManager()
   : m_hATR(INVALID_HANDLE)
{
   ZeroMemory(m_state);
}

CTradeManager::~CTradeManager() { Deinit(); }

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
bool CTradeManager::Init(string sym, long magic, ENUM_TIMEFRAMES ltfTF,
                          double trailMult, double beTriggerRR, bool useTimeExit)
{
   m_symbol         = sym;
   m_magic          = magic;
   m_ltfTF          = ltfTF;
   m_beTriggerRR    = MathMax(beTriggerRR, 0.5);
   m_trailingATRMult = MathMax(trailMult, 0.5);
   m_useTimeExit    = useTimeExit;

   m_hATR = iATR(m_symbol, m_ltfTF, 14);
   if(m_hATR == INVALID_HANDLE)
   {
      PrintFormat("[TradeManager] ATR handle failed: %d", GetLastError());
      return false;
   }

   m_trade.SetExpertMagicNumber(m_magic);
   m_trade.SetDeviationInPoints(10);
   m_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   ZeroMemory(m_state);

   PrintFormat("[TradeManager] OK: %s magic=%d BE=%.2fR ATR_trail=%.1f TimeExit=%s",
               m_symbol, m_magic, m_beTriggerRR, m_trailingATRMult,
               (m_useTimeExit ? "ON" : "OFF"));
   return true;
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void CTradeManager::Deinit()
{
   if(m_hATR != INVALID_HANDLE)
   {
      IndicatorRelease(m_hATR);
      m_hATR = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Reset trade state                                                  |
//+------------------------------------------------------------------+
void CTradeManager::ResetState()
{
   m_state.hasPosition    = false;
   m_state.positionTicket = 0;
   m_state.openPrice      = 0;
   m_state.currentSL      = 0;
   m_state.originalSL     = 0;
   m_state.tp1Price        = 0;
   m_state.lotSize        = 0;
   m_state.tp1Hit         = false;
   m_state.beActive       = false;
   m_state.trailingATR    = 0;
   m_state.rejectReason   = "";
}

//+------------------------------------------------------------------+
//| Find our position by magic + symbol                               |
//+------------------------------------------------------------------+
bool CTradeManager::FindPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == m_symbol &&
         PositionGetInteger(POSITION_MAGIC) == m_magic)
      {
         m_state.positionTicket = ticket;
         m_state.openPrice      = PositionGetDouble(POSITION_PRICE_OPEN);
         //--- SL only set on first detection — afterwards managed internally
         if(m_state.originalSL == 0)
            m_state.originalSL = PositionGetDouble(POSITION_SL);
         if(m_state.currentSL == 0)
            m_state.currentSL = PositionGetDouble(POSITION_SL);
         m_state.tp1Price        = PositionGetDouble(POSITION_TP);
         m_state.lotSize        = PositionGetDouble(POSITION_VOLUME);
         m_state.hasPosition    = true;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Breakeven — activate at configured R                              |
//| SL distance = |openPrice - originalSL|                            |
//| Trigger: LONG = open + slDist * RR, SHORT = open - slDist * RR   |
//| New SL = openPrice + 2 points buffer (LONG)                       |
//+------------------------------------------------------------------+
void CTradeManager::CheckBreakeven()
{
   if(m_state.beActive) return;  // already at BE

   double slDist = MathAbs(m_state.openPrice - m_state.originalSL);
   if(slDist <= 0) return;

   int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   long posType = PositionGetInteger(POSITION_TYPE);
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);

   if(posType == POSITION_TYPE_BUY)
   {
      double triggerPrice = m_state.openPrice + (slDist * m_beTriggerRR);
      if(bid >= triggerPrice)
      {
         double newSL = NormalizeDouble(m_state.openPrice + (2.0 * _Point), digits);
         if(m_trade.PositionModify(m_state.positionTicket, newSL, m_state.tp1Price))
         {
            m_state.beActive  = true;
            m_state.currentSL = newSL;
            PrintFormat("[TradeManager] ✓ BE activated: SL → %.5f (%.2fR=%.5f)",
                        newSL, m_beTriggerRR, triggerPrice);
         }
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      double triggerPrice = m_state.openPrice - (slDist * m_beTriggerRR);
      if(ask <= triggerPrice)
      {
         double newSL = NormalizeDouble(m_state.openPrice - (2.0 * _Point), digits);
         if(m_trade.PositionModify(m_state.positionTicket, newSL, m_state.tp1Price))
         {
            m_state.beActive  = true;
            m_state.currentSL = newSL;
            PrintFormat("[TradeManager] ✓ BE activated: SL → %.5f (%.2fR=%.5f)",
                        newSL, m_beTriggerRR, triggerPrice);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| TP1 — partial close 50% at TP1 price                              |
//+------------------------------------------------------------------+
void CTradeManager::CheckTP1()
{
   if(m_state.tp1Hit) return;  // already hit
   if(m_state.tp1Price <= 0) return;

   long posType = PositionGetInteger(POSITION_TYPE);
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   bool tp1Reached = false;

   if(posType == POSITION_TYPE_BUY && bid >= m_state.tp1Price)
      tp1Reached = true;
   if(posType == POSITION_TYPE_SELL && ask <= m_state.tp1Price)
      tp1Reached = true;

   if(!tp1Reached) return;

   //--- Calculate 50% lot
   double lotStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
   double closeLot = m_state.lotSize * 0.5;

   if(lotStep > 0)
      closeLot = MathFloor(closeLot / lotStep) * lotStep;
   closeLot = NormalizeDouble(closeLot, 2);
   if(closeLot < minLot) closeLot = minLot;

   //--- Don't close more than we have
   if(closeLot >= m_state.lotSize)
      closeLot = m_state.lotSize;

   if(m_trade.PositionClosePartial(m_state.positionTicket, closeLot))
   {
      m_state.tp1Hit  = true;
      m_state.lotSize = m_state.lotSize - closeLot;
      PrintFormat("[TradeManager] ✓ TP1 hit: closed %.2f lots, remaining=%.2f", closeLot, m_state.lotSize);

      //--- Ensure BE is active after TP1
      if(!m_state.beActive)
      {
         int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
         double newSL = 0;
         if(posType == POSITION_TYPE_BUY)
            newSL = NormalizeDouble(m_state.openPrice + (2.0 * _Point), digits);
         else
            newSL = NormalizeDouble(m_state.openPrice - (2.0 * _Point), digits);

         if(m_trade.PositionModify(m_state.positionTicket, newSL, 0))
         {
            m_state.beActive  = true;
            m_state.currentSL = newSL;
         }
      }
      else
      {
         //--- Remove TP from order (trailing takes over)
         m_trade.PositionModify(m_state.positionTicket, m_state.currentSL, 0);
      }
   }
   else
   {
      PrintFormat("[TradeManager] ✗ TP1 partial close failed: %d — %s",
                  m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Trailing Stop — ATR-based, only after TP1                         |
//+------------------------------------------------------------------+
void CTradeManager::CheckTrailing()
{
   if(!m_state.tp1Hit) return;  // trailing only active post-TP1

   //--- Get ATR
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(m_hATR, 0, 0, 3, atr) < 3) return;
   double atrVal = atr[1];
   m_state.trailingATR = atrVal;

   double trailDist = atrVal * m_trailingATRMult;
   if(trailDist <= 0) return;

   int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   long posType = PositionGetInteger(POSITION_TYPE);
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);

   double newSL = 0;

   if(posType == POSITION_TYPE_BUY)
   {
      newSL = NormalizeDouble(bid - trailDist, digits);
      //--- Only move SL up, never down
      if(newSL <= m_state.currentSL) return;
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      newSL = NormalizeDouble(ask + trailDist, digits);
      //--- Only move SL down, never up
      if(newSL >= m_state.currentSL) return;
   }

   if(m_trade.PositionModify(m_state.positionTicket, newSL, 0))
   {
      m_state.currentSL = newSL;
      PrintFormat("[TradeManager] ✓ Trailing SL → %.5f (ATR=%.5f × %.1f)",
                  newSL, atrVal, m_trailingATRMult);
   }
}

//+------------------------------------------------------------------+
//| Time Exit — close losing positions near NY close (21:45 GMT)      |
//+------------------------------------------------------------------+
void CTradeManager::CheckTimeExit()
{
   if(!m_useTimeExit) return;

   MqlDateTime dt;
   TimeGMT(dt);

   //--- 21:45 GMT check
   if(dt.hour != 21 || dt.min < 45) return;

   //--- Only close if position is in loss
   double profit = PositionGetDouble(POSITION_PROFIT);
   double swap   = PositionGetDouble(POSITION_SWAP);
   double totalPnL = profit + swap;

   if(totalPnL >= 0) return;  // in profit — let trailing handle it

   if(m_trade.PositionClose(m_state.positionTicket))
   {
      PrintFormat("[TradeManager] ✓ Time exit: closed at loss $%.2f @ GMT 21:45", totalPnL);
      ResetState();
   }
   else
   {
      PrintFormat("[TradeManager] ✗ Time exit close failed: %d", m_trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| Update — main entry point                                         |
//| Called from OnTick(), receives EntryState                          |
//+------------------------------------------------------------------+
bool CTradeManager::Update(const EntryState &es)
{
   m_state.lastUpdateTime = TimeCurrent();
   m_state.rejectReason   = "";

   //--- ADIM 1: Position detection
   if(!es.entryFired)
   {
      //--- No position to manage
      if(m_state.hasPosition)
      {
         //--- Check if position still exists (could have been closed by SL/TP)
         if(!FindPosition())
         {
            PrintFormat("[TradeManager] Pozisyon kapandı — state sıfırlandı");
            ResetState();
         }
      }
      return true;
   }

   //--- Locate our position
   if(!FindPosition())
   {
      m_state.hasPosition  = false;
      m_state.rejectReason = "Pozisyon bulunamadı";
      return true;
   }

   //--- First time detecting this position → set TP1 from EntryState
   if(m_state.tp1Price <= 0 && es.takeProfit1 > 0)
   {
      m_state.tp1Price = es.takeProfit1;
   }

   //--- ADIM 2: Breakeven check
   CheckBreakeven();

   //--- ADIM 3: TP1 partial close
   CheckTP1();

   //--- ADIM 4: Trailing stop (post-TP1)
   CheckTrailing();

   //--- ADIM 5: Time exit
   CheckTimeExit();

   return true;
}

#endif // TRADE_MANAGER_MQH
