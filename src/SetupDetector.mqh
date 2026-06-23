//+------------------------------------------------------------------+
//|                                              SetupDetector.mqh   |
//|                         Trend Flowing EA — Module 2               |
//|                   1H OB + 15M Sweep/Displacement/FVG              |
//+------------------------------------------------------------------+
#ifndef SETUP_DETECTOR_MQH
#define SETUP_DETECTOR_MQH

#include "TrendDetector.mqh"   // ENUM_TREND_DIR

//+------------------------------------------------------------------+
//| SetupState struct                                                 |
//+------------------------------------------------------------------+
struct SetupState
{
   //--- 1H Order Block
   bool           hasOB;
   double         obHigh;
   double         obLow;
   datetime       obTime;

   //--- 15M Liquidity Sweep
   bool           hasSweep;
   double         sweepPrice;
   datetime       sweepTime;

   //--- 15M Displacement
   bool           hasDisplacement;
   double         dispBodyRatio;
   datetime       dispTime;

   //--- 15M FVG
   bool           hasFVG;
   double         fvgHigh;
   double         fvgLow;
   double         fvgMid;
   datetime       fvgTime;
   int            fvgBarAge;
   bool           fvgValid;

   //--- Combined
   bool           setupReady;
   ENUM_TREND_DIR setupDirection;
   string         rejectReason;
   datetime       lastUpdateTime;
};

//+------------------------------------------------------------------+
//| CSetupDetector                                                    |
//+------------------------------------------------------------------+
class CSetupDetector
{
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_obTF;       // 1H for order blocks
   ENUM_TIMEFRAMES m_ltfTF;      // 15M for sweep/disp/FVG

   int             m_obLookback;
   double          m_dispMultiplier;
   int             m_dispAvgBars;
   int             m_fvgMaxBars;
   int             m_sweepProximity;  // points

   SetupState      m_state;
   datetime        m_lastOBBar;
   datetime        m_lastLTFBar;

   bool            IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastBar);
   bool            FindOrderBlock(ENUM_TREND_DIR dir);
   bool            CheckSweep(ENUM_TREND_DIR dir);
   bool            CheckDisplacement(ENUM_TREND_DIR dir);
   bool            FindFVG(ENUM_TREND_DIR dir);
   void            UpdateFVGAge();
   void            ResetLTF();
   void            ResetAll();

public:
                   CSetupDetector();
                  ~CSetupDetector();
   bool            Init(string sym, ENUM_TIMEFRAMES obTF, ENUM_TIMEFRAMES ltfTF,
                        int obLB, double dispMult, int dispAvg, int fvgMax, int sweepProx);
   void            Deinit() {}  // ileride handle olursa hazır
   bool            Update(ENUM_TREND_DIR trendDir, bool trendValid);
   bool            ConsumeSetup(string reason);

   SetupState      GetState()     const { return m_state; }
   bool            IsReady()      const { return m_state.setupReady; }
   ENUM_TREND_DIR  GetDirection() const { return m_state.setupDirection; }
};

//+------------------------------------------------------------------+
//| Constructor                                                       |
//+------------------------------------------------------------------+
CSetupDetector::CSetupDetector()
   : m_lastOBBar(0), m_lastLTFBar(0)
{
   ZeroMemory(m_state);
   m_state.setupDirection = TREND_NONE;
   m_state.setupReady     = false;
}

CSetupDetector::~CSetupDetector() {}

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
bool CSetupDetector::Init(string sym, ENUM_TIMEFRAMES obTF, ENUM_TIMEFRAMES ltfTF,
                           int obLB, double dispMult, int dispAvg, int fvgMax, int sweepProx)
{
   m_symbol         = sym;
   m_obTF           = obTF;
   m_ltfTF          = ltfTF;
   m_obLookback     = MathMax(obLB, 10);
   m_dispMultiplier = dispMult;
   m_dispAvgBars    = MathMax(dispAvg, 3);
   m_fvgMaxBars     = MathMax(fvgMax, 3);
   m_sweepProximity = sweepProx;

   ZeroMemory(m_state);
   m_state.setupDirection = TREND_NONE;
   m_state.setupReady     = false;
   m_lastOBBar  = 0;
   m_lastLTFBar = 0;

   PrintFormat("[SetupDetector] OK: %s OB_TF=%s LTF=%s OB_LB=%d Disp=%.1fx%d FVG_Max=%d SweepProx=%d",
               m_symbol, EnumToString(m_obTF), EnumToString(m_ltfTF),
               m_obLookback, m_dispMultiplier, m_dispAvgBars, m_fvgMaxBars, m_sweepProximity);
   return true;
}

//+------------------------------------------------------------------+
//| New bar detection for any timeframe                               |
//+------------------------------------------------------------------+
bool CSetupDetector::IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastBar)
{
   datetime t[];
   if(CopyTime(m_symbol, tf, 0, 1, t) != 1) return false;
   if(t[0] == lastBar) return false;
   lastBar = t[0];
   return true;
}

//+------------------------------------------------------------------+
//| Reset all LTF state (keep OB)                                    |
//+------------------------------------------------------------------+
void CSetupDetector::ResetLTF()
{
   m_state.hasSweep        = false;
   m_state.sweepPrice      = 0;
   m_state.sweepTime       = 0;

   m_state.hasDisplacement = false;
   m_state.dispBodyRatio   = 0;
   m_state.dispTime        = 0;

   m_state.hasFVG          = false;
   m_state.fvgHigh         = 0;
   m_state.fvgLow          = 0;
   m_state.fvgMid          = 0;
   m_state.fvgTime         = 0;
   m_state.fvgBarAge       = 0;
   m_state.fvgValid        = false;

   m_state.setupReady      = false;
}

//+------------------------------------------------------------------+
//| Reset everything                                                  |
//+------------------------------------------------------------------+
void CSetupDetector::ResetAll()
{
   m_state.hasOB   = false;
   m_state.obHigh  = 0;
   m_state.obLow   = 0;
   m_state.obTime  = 0;
   ResetLTF();
   m_state.setupDirection = TREND_NONE;
}

//+------------------------------------------------------------------+
//| Consume current setup and reopen the LTF pipeline                |
//+------------------------------------------------------------------+
bool CSetupDetector::ConsumeSetup(string reason)
{
   if(!m_state.hasSweep && !m_state.hasDisplacement && !m_state.hasFVG && !m_state.setupReady)
      return false;

   PrintFormat("[SetupDetector] Setup consumed -> LTF reset (%s)", reason);
   m_state.rejectReason = reason;
   ResetLTF();
   return true;
}

//+------------------------------------------------------------------+
//| FindOrderBlock — 1H last opposing candle before impulse           |
//| Bullish OB: last bearish candle before bullish impulse            |
//| Bearish OB: last bullish candle before bearish impulse            |
//+------------------------------------------------------------------+
bool CSetupDetector::FindOrderBlock(ENUM_TREND_DIR dir)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, m_obTF, 0, m_obLookback + 5, rates);
   if(copied < m_obLookback + 5)
   {
      m_state.rejectReason = "1H veri yetersiz (OB)";
      return false;
   }

   //--- Scan from bar 1 (last completed) forward into history
   for(int i = 1; i < copied - 3; i++)
   {
      if(dir == TREND_LONG)
      {
         //--- Looking for: bearish candle at [i], followed by bullish impulse
         bool isBearish = (rates[i].close < rates[i].open);
         if(!isBearish) continue;

         //--- Check impulse: at least one bar AFTER (more recent, i-1... but i-1 could be 0 = current)
         //--- Actually bars after in time = bars at lower index  
         //--- Check: any bar in range [max(i-3,1)..i-1] closed above the 3 bars' high before it
         double refHigh = 0;
         for(int k = i; k <= i + 2 && k < copied; k++)
            refHigh = MathMax(refHigh, rates[k].high);

         bool impulseFound = false;
         for(int j = i - 1; j >= 1 && j >= i - 3; j--)
         {
            if(rates[j].close > refHigh)
            { impulseFound = true; break; }
         }

         if(impulseFound)
         {
            bool sameOB = (m_state.hasOB &&
                           m_state.obTime == rates[i].time &&
                           MathAbs(m_state.obHigh - rates[i].high) <= (_Point * 0.5) &&
                           MathAbs(m_state.obLow - rates[i].low) <= (_Point * 0.5));

            if(sameOB)
               return true;

            m_state.hasOB  = true;
            m_state.obHigh = rates[i].high;
            m_state.obLow  = rates[i].low;
            m_state.obTime = rates[i].time;
            PrintFormat("[SetupDetector] ✓ Bullish OB: [%.5f - %.5f] @ %s",
                        m_state.obLow, m_state.obHigh, TimeToString(m_state.obTime));
            return true;
         }
      }
      else if(dir == TREND_SHORT)
      {
         //--- Looking for: bullish candle at [i], followed by bearish impulse
         bool isBullish = (rates[i].close > rates[i].open);
         if(!isBullish) continue;

         double refLow = DBL_MAX;
         for(int k = i; k <= i + 2 && k < copied; k++)
            refLow = MathMin(refLow, rates[k].low);

         bool impulseFound = false;
         for(int j = i - 1; j >= 1 && j >= i - 3; j--)
         {
            if(rates[j].close < refLow)
            { impulseFound = true; break; }
         }

         if(impulseFound)
         {
            bool sameOB = (m_state.hasOB &&
                           m_state.obTime == rates[i].time &&
                           MathAbs(m_state.obHigh - rates[i].high) <= (_Point * 0.5) &&
                           MathAbs(m_state.obLow - rates[i].low) <= (_Point * 0.5));

            if(sameOB)
               return true;

            m_state.hasOB  = true;
            m_state.obHigh = rates[i].high;
            m_state.obLow  = rates[i].low;
            m_state.obTime = rates[i].time;
            PrintFormat("[SetupDetector] ✓ Bearish OB: [%.5f - %.5f] @ %s",
                        m_state.obLow, m_state.obHigh, TimeToString(m_state.obTime));
            return true;
         }
      }
   }

   m_state.rejectReason = "SETUP_REJECT | NO_OB | lookback=" + IntegerToString(m_obLookback);
   PrintFormat("[SetupDetector] %s", m_state.rejectReason);
   return false;
}

//+------------------------------------------------------------------+
//| CheckSweep — 15M liquidity sweep near OB zone                    |
//| Bullish: wick < obLow - proximity, close > obLow                 |
//| Bearish: wick > obHigh + proximity, close < obHigh               |
//+------------------------------------------------------------------+
bool CSetupDetector::CheckSweep(ENUM_TREND_DIR dir)
{
   if(!m_state.hasOB) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, m_ltfTF, 0, 20, rates);
   if(copied < 10)
   {
      m_state.rejectReason = "15M veri yetersiz (Sweep)";
      return false;
   }

   double proxPoints = m_sweepProximity * _Point;

   //--- Scan completed bars (1 onward)
   for(int i = 1; i < copied - 1; i++)
   {
      if(rates[i].time < m_state.obTime) break;  // OB'den önce sweep olamaz

      if(dir == TREND_LONG)
      {
         //--- Bullish sweep: wick approaches or pierces OB zone
         double obRange   = m_state.obHigh - m_state.obLow;
         double tolerance = obRange * 0.2;
         bool wickBelow = (rates[i].low < m_state.obLow + tolerance);
         bool closeBack = (rates[i].close > m_state.obLow - tolerance);

         if(wickBelow && closeBack)
         {
            m_state.hasSweep   = true;
            m_state.sweepPrice = rates[i].low;
            m_state.sweepTime  = rates[i].time;
            PrintFormat("[SetupDetector] ✓ Bullish Sweep: low=%.5f < OB_low=%.5f+tol=%.5f @ %s",
                        rates[i].low, m_state.obLow, tolerance, TimeToString(m_state.sweepTime));
            return true;
         }
      }
      else if(dir == TREND_SHORT)
      {
         //--- Bearish sweep: wick approaches or pierces OB zone
         double obRange   = m_state.obHigh - m_state.obLow;
         double tolerance = obRange * 0.2;
         bool wickAbove = (rates[i].high > m_state.obHigh - tolerance);
         bool closeBack = (rates[i].close < m_state.obHigh + tolerance);

         if(wickAbove && closeBack)
         {
            m_state.hasSweep   = true;
            m_state.sweepPrice = rates[i].high;
            m_state.sweepTime  = rates[i].time;
            PrintFormat("[SetupDetector] ✓ Bearish Sweep: high=%.5f > OB_high=%.5f-tol=%.5f @ %s",
                        rates[i].high, m_state.obHigh, tolerance, TimeToString(m_state.sweepTime));
            return true;
         }
      }
   }

   return false;  // no sweep found yet — keep checking
}

//+------------------------------------------------------------------+
//| CheckDisplacement — 15M strong candle after sweep                 |
//| Body > multiplier × avg body of last N bars                       |
//+------------------------------------------------------------------+
bool CSetupDetector::CheckDisplacement(ENUM_TREND_DIR dir)
{
   if(!m_state.hasSweep) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int needed = m_dispAvgBars + 10;
   int copied = CopyRates(m_symbol, m_ltfTF, 0, needed, rates);
   if(copied < needed)
   {
      m_state.rejectReason = "15M veri yetersiz (Displacement)";
      return false;
   }

   //--- Find the sweep bar index in current rates
   int sweepIdx = -1;
   for(int i = 1; i < copied; i++)
   {
      if(rates[i].time == m_state.sweepTime)
      { sweepIdx = i; break; }
   }
   if(sweepIdx < 0 || sweepIdx < 1) return false;  // sweep bar not in range

   //--- Calculate average body size of bars BEFORE the sweep
   double sumBody = 0;
   int count = 0;
   for(int i = sweepIdx + 1; i < sweepIdx + 1 + m_dispAvgBars && i < copied; i++)
   {
      sumBody += MathAbs(rates[i].close - rates[i].open);
      count++;
   }
   if(count == 0) return false;
   double avgBody = sumBody / count;
   if(avgBody <= 0) return false;

   //--- Check displacement candle(s) after sweep (more recent = lower index)
   //--- Check up to 5 bars after sweep
   int checkEnd = MathMax(sweepIdx - 5, 1);
   for(int i = sweepIdx - 1; i >= checkEnd; i--)
   {
      if(i < 1) break;
      double body = MathAbs(rates[i].close - rates[i].open);
      double ratio = body / avgBody;

      if(ratio >= m_dispMultiplier)
      {
         //--- Must be in the trend direction
         bool bullCandle = (rates[i].close > rates[i].open);
         bool bearCandle = (rates[i].close < rates[i].open);

         if((dir == TREND_LONG && bullCandle) || (dir == TREND_SHORT && bearCandle))
         {
            m_state.hasDisplacement = true;
            m_state.dispBodyRatio   = ratio;
            m_state.dispTime        = rates[i].time;
            PrintFormat("[SetupDetector] ✓ Displacement: ratio=%.1f (thr=%.1f) @ %s",
                        ratio, m_dispMultiplier, TimeToString(m_state.dispTime));
            return true;
         }
      }
   }

   return false;  // no displacement yet — reject reason set in Update()
}

//+------------------------------------------------------------------+
//| FindFVG — 15M Fair Value Gap detection                            |
//| ArraySetAsSeries=true: [i+1]=older, [i]=middle, [i-1]=newer      |
//| Bullish FVG: rates[i+1].high < rates[i-1].low                    |
//| Bearish FVG: rates[i+1].low  > rates[i-1].high                   |
//+------------------------------------------------------------------+
bool CSetupDetector::FindFVG(ENUM_TREND_DIR dir)
{
   if(!m_state.hasDisplacement) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, m_ltfTF, 0, 30, rates);
   if(copied < 5)
   {
      m_state.rejectReason = "15M veri yetersiz (FVG)";
      return false;
   }

   //--- Scan completed bars: i is the middle candle of the 3-candle pattern
   //--- i-1 = newer bar, i+1 = older bar (series indexing)
   for(int i = 2; i < copied - 1; i++)
   {
      //--- Only check bars at or after displacement time
      if(rates[i].time < m_state.dispTime) break;  // series: daha eski barlara geçme

      if(dir == TREND_LONG)
      {
         //--- Bullish FVG: gap below candle i
         //--- Older candle's high < Newer candle's low
         if(rates[i + 1].high < rates[i - 1].low)
         {
            m_state.hasFVG   = true;
            m_state.fvgLow   = rates[i + 1].high;   // bottom of gap = old candle high
            m_state.fvgHigh  = rates[i - 1].low;     // top of gap = new candle low
            m_state.fvgMid   = (m_state.fvgLow + m_state.fvgHigh) / 2.0;
            m_state.fvgTime  = rates[i].time;
            m_state.fvgBarAge = 0;
            m_state.fvgValid = true;
            PrintFormat("[SetupDetector] ✓ Bullish FVG: [%.5f - %.5f] mid=%.5f @ %s",
                        m_state.fvgLow, m_state.fvgHigh, m_state.fvgMid,
                        TimeToString(m_state.fvgTime));
            return true;
         }
      }
      else if(dir == TREND_SHORT)
      {
         //--- Bearish FVG: gap above candle i
         //--- Older candle's low > Newer candle's high
         if(rates[i + 1].low > rates[i - 1].high)
         {
            m_state.hasFVG   = true;
            m_state.fvgHigh  = rates[i + 1].low;     // top of gap = old candle low
            m_state.fvgLow   = rates[i - 1].high;    // bottom of gap = new candle high
            m_state.fvgMid   = (m_state.fvgLow + m_state.fvgHigh) / 2.0;
            m_state.fvgTime  = rates[i].time;
            m_state.fvgBarAge = 0;
            m_state.fvgValid = true;
            PrintFormat("[SetupDetector] ✓ Bearish FVG: [%.5f - %.5f] mid=%.5f @ %s",
                        m_state.fvgLow, m_state.fvgHigh, m_state.fvgMid,
                        TimeToString(m_state.fvgTime));
            return true;
         }
      }
   }

   return false;  // no FVG yet — reject reason set in Update()
}

//+------------------------------------------------------------------+
//| UpdateFVGAge — increment bar age, check validity, test price      |
//+------------------------------------------------------------------+
void CSetupDetector::UpdateFVGAge()
{
   if(!m_state.hasFVG || !m_state.fvgValid) return;

   m_state.fvgBarAge++;

   //--- Check if price has tested the FVG zone (current bar touches zone)
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(m_symbol, m_ltfTF, 0, 2, rates) >= 2)
   {
      double barLow  = rates[1].low;
      double barHigh = rates[1].high;

      //--- Price entered FVG zone = tested, age resets (remains valid)
      if(barLow <= m_state.fvgHigh && barHigh >= m_state.fvgLow)
      {
         // FVG tested — keep valid, reset age
         m_state.fvgBarAge = 0;
         return;
      }
   }

   //--- Check expiry: FVG max bars untested → full LTF pipeline reset
   if(m_state.fvgBarAge >= m_fvgMaxBars)
   {
      string expMsg = StringFormat("SETUP_REJECT | FVG_EXPIRED | age=%d max=%d", m_state.fvgBarAge, m_fvgMaxBars);
      PrintFormat("[SetupDetector] %s", expMsg);
      m_state.rejectReason = expMsg;
      ResetLTF();   // OB preserved, sweep/disp/FVG cleared
   }
}

//+------------------------------------------------------------------+
//| Update — main entry point                                         |
//| Called from OnTick(); receives trend direction from Module 1       |
//+------------------------------------------------------------------+
bool CSetupDetector::Update(ENUM_TREND_DIR trendDir, bool trendValid)
{
   m_state.lastUpdateTime = TimeCurrent();
   m_state.rejectReason   = "";

   //--- No valid trend → reset LTF only, preserve OB
   if(!trendValid || trendDir == TREND_NONE)
   {
      if(m_state.hasSweep || m_state.hasFVG)
      {
         PrintFormat("[SetupDetector] Trend lost → LTF reset (OB korundu)");
         ResetLTF();  // OB kalıyor!
      }
      m_state.rejectReason = "Geçerli trend yok";
      return true;
   }

   //--- Trend direction changed → reset everything
   if(m_state.setupDirection != TREND_NONE && m_state.setupDirection != trendDir)
   {
      PrintFormat("[SetupDetector] Trend direction changed %d → %d — full reset",
                  m_state.setupDirection, trendDir);
      ResetAll();
   }
   m_state.setupDirection = trendDir;

   //--- Step 1: 1H Order Block (only on new 1H bar)
   if(IsNewBar(m_obTF, m_lastOBBar))
   {
      if(!m_state.hasSweep)
      {
         datetime prevOBTime = m_state.obTime;
         double prevOBLow    = m_state.obLow;
         double prevOBHigh   = m_state.obHigh;

         if(FindOrderBlock(trendDir))
         {
            if(prevOBTime != 0 && m_state.obTime != prevOBTime)
            {
               ResetLTF();
               PrintFormat("[SetupDetector] OB refreshed: [%.5f - %.5f] @ %s -> [%.5f - %.5f] @ %s",
                           prevOBLow, prevOBHigh, TimeToString(prevOBTime),
                           m_state.obLow, m_state.obHigh, TimeToString(m_state.obTime));
            }
         }
      }
   }

   //--- Steps 2-4 operate on 15M timeframe
   bool newLTF = IsNewBar(m_ltfTF, m_lastLTFBar);

   if(!newLTF)
      return true;   // no new 15M bar, keep current state

   //--- FVG age tracking (must run every new 15M bar if FVG exists)
   if(m_state.hasFVG && m_state.fvgValid)
   {
      UpdateFVGAge();
      //--- If FVG was invalidated by age, LTF is already reset
      //--- We can still try to find new sweep below
   }

   //--- Step 2: Liquidity Sweep (need OB first)
   if(m_state.hasOB && !m_state.hasSweep)
   {
      CheckSweep(trendDir);
   }

   //--- Step 3: Displacement (need sweep first)
   if(m_state.hasSweep && !m_state.hasDisplacement)
   {
      CheckDisplacement(trendDir);
   }

   //--- Step 4: FVG (need displacement first)
   if(m_state.hasDisplacement && !m_state.hasFVG)
   {
      FindFVG(trendDir);
   }

   //--- Combined: all 4 must be active
   m_state.setupReady = (m_state.hasOB &&
                         m_state.hasSweep &&
                         m_state.hasDisplacement &&
                         m_state.hasFVG &&
                         m_state.fvgValid);

   if(m_state.setupReady)
   {
      PrintFormat("[SetupDetector] ★ SETUP READY: %s | OB=[%.5f-%.5f] FVG_mid=%.5f age=%d",
                  (trendDir == TREND_LONG ? "LONG" : "SHORT"),
                  m_state.obLow, m_state.obHigh, m_state.fvgMid, m_state.fvgBarAge);
   }
   else if(m_state.rejectReason == "")
   {
      string pipeline = StringFormat("Pipeline: OB=%s Sweep=%s Disp=%s FVG=%s",
                                     (m_state.hasOB ? "Y" : "N"),
                                     (m_state.hasSweep ? "Y" : "N"),
                                     (m_state.hasDisplacement ? "Y" : "N"),
                                     (m_state.hasFVG && m_state.fvgValid ? "Y" : "N"));

      //--- Specific reject reason for the first missing step
      if(!m_state.hasOB)
         m_state.rejectReason = "SETUP_REJECT | NO_OB | lookback=" + IntegerToString(m_obLookback);
      else if(!m_state.hasSweep)
         m_state.rejectReason = StringFormat("SETUP_REJECT | NO_SWEEP | ob_low=%.5f ob_high=%.5f", m_state.obLow, m_state.obHigh);
      else if(!m_state.hasDisplacement)
         m_state.rejectReason = StringFormat("SETUP_REJECT | NO_DISPLACEMENT | mult=%.1f", m_dispMultiplier);
      else if(!m_state.hasFVG || !m_state.fvgValid)
         m_state.rejectReason = "SETUP_REJECT | NO_FVG | checked_bars=30";

      m_state.rejectReason = m_state.rejectReason + " | " + pipeline;
      PrintFormat("[SetupDetector] %s", m_state.rejectReason);
   }

   return true;
}

#endif // SETUP_DETECTOR_MQH
