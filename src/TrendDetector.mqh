//+------------------------------------------------------------------+
//|                                               TrendDetector.mqh  |
//|                         Trend Flowing EA — Module 1               |
//|                         BOS/MSB + ADX + EMA Slope (4H)            |
//+------------------------------------------------------------------+
#ifndef TREND_DETECTOR_MQH
#define TREND_DETECTOR_MQH

//+------------------------------------------------------------------+
//| Enums & Structs                                                   |
//+------------------------------------------------------------------+
enum ENUM_TREND_DIR
{
   TREND_NONE  =  0,
   TREND_LONG  =  1,
   TREND_SHORT = -1
};

struct SwingPoint
{
   double   price;
   datetime time;
   int      barIndex;
};

struct TrendState
{
   ENUM_TREND_DIR direction;
   ENUM_TREND_DIR bosDirection;
   ENUM_TREND_DIR adxDirection;
   ENUM_TREND_DIR emaDirection;
   double         adxValue;
   double         diPlus;
   double         diMinus;
   double         emaValue;
   double         emaSlope;
   bool           isValid;
   datetime       lastUpdateTime;
   SwingPoint     swingHighs[3];
   SwingPoint     swingLows[3];
   int            shCount;
   int            slCount;
   string         rejectReason;
};

//+------------------------------------------------------------------+
//| CTrendDetector                                                    |
//+------------------------------------------------------------------+
class CTrendDetector
{
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_htfTF;
   int             m_adxPeriod;
   double          m_adxThreshold;
   double          m_adxLow;
   int             m_emaPeriod;
   int             m_swingLB;

   int             m_hADX;
   int             m_hEMA;

   MqlRates        m_rates[];
   int             m_copied;
   TrendState      m_state;
   datetime        m_lastBar;

   bool            IsNewHTFBar();
   bool            LoadBars(int n);
   bool            FindSwings();
   ENUM_TREND_DIR  CheckBOS();
   ENUM_TREND_DIR  CheckADX();
   ENUM_TREND_DIR  CheckEMA();

public:
                   CTrendDetector();
                  ~CTrendDetector();
   bool            Init(string sym, ENUM_TIMEFRAMES tf, int adxP, double adxTh, int emaP, int swingLB=5);
   void            Deinit();
   bool            Update();

   TrendState      GetState()     const { return m_state; }
   ENUM_TREND_DIR  GetDirection() const { return m_state.direction; }
   bool            IsValid()      const { return m_state.isValid; }
};

//+------------------------------------------------------------------+
//| Constructor / Destructor                                          |
//+------------------------------------------------------------------+
CTrendDetector::CTrendDetector()
  : m_hADX(INVALID_HANDLE), m_hEMA(INVALID_HANDLE),
    m_lastBar(0), m_copied(0), m_swingLB(5)
{
   ZeroMemory(m_state);
   m_state.direction = TREND_NONE;
   m_state.isValid   = false;
}

CTrendDetector::~CTrendDetector() { Deinit(); }

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
bool CTrendDetector::Init(string sym, ENUM_TIMEFRAMES tf,
                          int adxP, double adxTh, int emaP, int swingLB)
{
   m_symbol     = sym;
   m_htfTF      = tf;
   m_adxPeriod  = adxP;
   m_adxThreshold = adxTh;
   m_adxLow     = adxTh - 2.0;
   m_emaPeriod  = emaP;
   m_swingLB    = swingLB;

   m_hADX = iADX(m_symbol, m_htfTF, m_adxPeriod);
   if(m_hADX == INVALID_HANDLE)
   {
      PrintFormat("[TrendDetector] ADX handle failed: %d", GetLastError());
      return false;
   }

   m_hEMA = iMA(m_symbol, m_htfTF, m_emaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(m_hEMA == INVALID_HANDLE)
   {
      PrintFormat("[TrendDetector] EMA handle failed: %d", GetLastError());
      return false;
   }

   ZeroMemory(m_state);
   m_state.direction = TREND_NONE;
   m_state.isValid   = false;
   m_lastBar = 0;
   m_swingLB = (m_swingLB < 2) ? 2 : m_swingLB;  // minimum 2

   PrintFormat("[TrendDetector] OK: %s %s ADX(%d) thr=%.1f EMA(%d) SwingLB=%d",
               m_symbol, EnumToString(m_htfTF), m_adxPeriod, m_adxThreshold, m_emaPeriod, m_swingLB);
   return true;
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void CTrendDetector::Deinit()
{
   if(m_hADX != INVALID_HANDLE) { IndicatorRelease(m_hADX); m_hADX = INVALID_HANDLE; }
   if(m_hEMA != INVALID_HANDLE) { IndicatorRelease(m_hEMA); m_hEMA = INVALID_HANDLE; }
}

//+------------------------------------------------------------------+
//| New 4H bar check — HTF decision only updates on bar close        |
//+------------------------------------------------------------------+
bool CTrendDetector::IsNewHTFBar()
{
   datetime t[];
   if(CopyTime(m_symbol, m_htfTF, 0, 1, t) != 1) return false;
   if(t[0] == m_lastBar) return false;
   m_lastBar = t[0];
   return true;
}

//+------------------------------------------------------------------+
//| Load N bars of HTF data                                           |
//+------------------------------------------------------------------+
bool CTrendDetector::LoadBars(int n)
{
   ArraySetAsSeries(m_rates, true);
   m_copied = CopyRates(m_symbol, m_htfTF, 0, n, m_rates);
   return (m_copied >= n);
}

//+------------------------------------------------------------------+
//| Fractal-based swing high/low detection                            |
//| Scans from bar lb+1 onward (skip current bar 0)                  |
//+------------------------------------------------------------------+
bool CTrendDetector::FindSwings()
{
   m_state.shCount = 0;
   m_state.slCount = 0;

   int lb = m_swingLB;

   for(int i = lb + 1; i < m_copied - lb && (m_state.shCount < 3 || m_state.slCount < 3); i++)
   {
      //--- Swing High
      if(m_state.shCount < 3)
      {
         bool ok = true;
         for(int j = 1; j <= lb; j++)
         {
            if(m_rates[i].high <= m_rates[i - j].high ||
               m_rates[i].high <= m_rates[i + j].high)
            { ok = false; break; }
         }
         if(ok)
         {
            int idx = m_state.shCount;
            m_state.swingHighs[idx].price    = m_rates[i].high;
            m_state.swingHighs[idx].time     = m_rates[i].time;
            m_state.swingHighs[idx].barIndex = i;
            m_state.shCount++;
         }
      }

      //--- Swing Low (skip if this bar is already a swing high — BUG #3 fix)
      bool barIsSH = (m_state.shCount > 0 && m_state.swingHighs[m_state.shCount - 1].barIndex == i);
      if(m_state.slCount < 3 && !barIsSH)
      {
         bool ok = true;
         for(int j = 1; j <= lb; j++)
         {
            if(m_rates[i].low >= m_rates[i - j].low ||
               m_rates[i].low >= m_rates[i + j].low)
            { ok = false; break; }
         }
         if(ok)
         {
            int idx = m_state.slCount;
            m_state.swingLows[idx].price    = m_rates[i].low;
            m_state.swingLows[idx].time     = m_rates[i].time;
            m_state.swingLows[idx].barIndex = i;
            m_state.slCount++;
         }
      }
   }

   if(m_state.shCount < 2 || m_state.slCount < 2)
   {
      m_state.rejectReason = StringFormat("TREND_REJECT | SWING_INSUFFICIENT | SH=%d SL=%d",
                                          m_state.shCount, m_state.slCount);
      PrintFormat("[TrendDetector] %s", m_state.rejectReason);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| BOS — Break of Structure                                          |
//| Check if any completed bar AFTER the most recent swing point      |
//| closed beyond it  (close > swingHigh = bullish BOS, etc.)         |
//+------------------------------------------------------------------+
ENUM_TREND_DIR CTrendDetector::CheckBOS()
{
   if(m_state.shCount < 2 || m_state.slCount < 2) return TREND_NONE;

   datetime bullTime = 0, bearTime = 0;

   // İkinci en güncel swing high'ı kullan (ilki onay penceresinde kilitli)
   double shPrice = m_state.swingHighs[1].price;
   int    shIdx   = m_state.swingHighs[1].barIndex;
   for(int i = 1; i < shIdx; i++)
   {
      if(m_rates[i].close > shPrice)
      { bullTime = m_rates[i].time; break; }
   }

   // İkinci en güncel swing low'u kullan
   double slPrice = m_state.swingLows[1].price;
   int    slIdx   = m_state.swingLows[1].barIndex;
   for(int i = 1; i < slIdx; i++)
   {
      if(m_rates[i].close < slPrice)
      { bearTime = m_rates[i].time; break; }
   }

   if(bullTime == 0 && bearTime == 0)
   {
      if(m_state.rejectReason == "")
         m_state.rejectReason = "TREND_REJECT | BOS=NONE";
      return TREND_NONE;
   }
   if(bullTime > 0  && bearTime == 0) return TREND_LONG;
   if(bearTime > 0  && bullTime == 0) return TREND_SHORT;
   return (bullTime > bearTime) ? TREND_LONG : TREND_SHORT;
}

//+------------------------------------------------------------------+
//| ADX filter — strength + direction via +DI / -DI                   |
//| ADX > threshold   → trend confirmed, direction from DI            |
//| ADX < threshold-2 → no trade                                      |
//| In between        → wait                                          |
//+------------------------------------------------------------------+
ENUM_TREND_DIR CTrendDetector::CheckADX()
{
   double adx[], dip[], dim[];
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(dip, true);
   ArraySetAsSeries(dim, true);

   if(CopyBuffer(m_hADX, 0, 0, 3, adx) < 3) return TREND_NONE;
   if(CopyBuffer(m_hADX, 1, 0, 3, dip) < 3) return TREND_NONE;
   if(CopyBuffer(m_hADX, 2, 0, 3, dim) < 3) return TREND_NONE;

   // Use bar 1 (last completed)
   m_state.adxValue = adx[1];
   m_state.diPlus   = dip[1];
   m_state.diMinus  = dim[1];

   if(m_state.adxValue < m_adxLow)
   {
      m_state.rejectReason = StringFormat("TREND_REJECT | ADX_LOW | value=%.1f thr=%.1f", m_state.adxValue, m_adxLow);
      PrintFormat("[TrendDetector] %s", m_state.rejectReason);
      return TREND_NONE;
   }

   if(m_state.adxValue < m_adxThreshold)
   {
      // BUG #2 fix: preserve previous direction, only mark invalid
      m_state.rejectReason = StringFormat("ADX=%.1f bekleme aralığında [%.1f-%.1f]",
                                          m_state.adxValue, m_adxLow, m_adxThreshold);
      // direction is NOT cleared — previous decision survives
      return TREND_NONE;
   }

   // ADX > threshold → direction from DI
   if(m_state.diPlus > m_state.diMinus) return TREND_LONG;
   if(m_state.diMinus > m_state.diPlus) return TREND_SHORT;
   return TREND_NONE;
}

//+------------------------------------------------------------------+
//| EMA 50 Slope — last 3 completed bars                              |
//| Monotonically rising  → LONG                                      |
//| Monotonically falling → SHORT                                     |
//| Otherwise             → flat → no trade                           |
//+------------------------------------------------------------------+
ENUM_TREND_DIR CTrendDetector::CheckEMA()
{
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(m_hEMA, 0, 0, 5, ema) < 5) return TREND_NONE;

   // Completed bars: 1, 2  (1 = most recent completed)
   m_state.emaValue = ema[1];
   m_state.emaSlope = ema[1] - ema[2];   // single-bar slope

   bool rising  = (ema[1] > ema[2]);   // sadece 2 bar
   bool falling = (ema[1] < ema[2]);

   if(rising)  return TREND_LONG;
   if(falling) return TREND_SHORT;

   m_state.rejectReason = StringFormat("EMA yatay: %.5f → %.5f", ema[2], ema[1]);
   return TREND_NONE;
}

//+------------------------------------------------------------------+
//| Update — main entry point, called every tick                      |
//| Only recalculates on new 4H bar close                             |
//+------------------------------------------------------------------+
bool CTrendDetector::Update()
{
   if(!IsNewHTFBar())
      return true;   // no update needed, keep current state

   m_state.rejectReason = "";
   m_state.lastUpdateTime = TimeCurrent();

   //--- Load 60 bars of 4H data (enough for 3 swing points + buffer)
   if(!LoadBars(60))
   {
      m_state.rejectReason = "4H veri yetersiz";
      m_state.direction = TREND_NONE;
      m_state.isValid   = false;
      return false;
   }

   //--- Step 1: Swing Points
   if(!FindSwings())
   {
      m_state.direction = TREND_NONE;
      m_state.isValid   = false;
      return true;   // not an error, just insufficient structure
   }

   //--- Step 2: BOS
   ENUM_TREND_DIR bos = CheckBOS();
   m_state.bosDirection = bos;

   //--- Step 3: ADX
   ENUM_TREND_DIR adx = CheckADX();
   m_state.adxDirection = adx;

   //--- ADX bekleme aralığındaysa (18-20): önceki kararı koru, early return
   bool adxWaiting = (m_state.adxValue >= m_adxLow && 
                      m_state.adxValue < m_adxThreshold);
   if(adxWaiting)
   {
      m_state.isValid = false;
      // direction değiştirilmez — önceki yön korunur
      PrintFormat("[TrendDetector] ADX bekleme: %.1f — önceki yön korundu (%d)", 
                  m_state.adxValue, m_state.direction);
      return true;
   }

   //--- Step 4: EMA Slope
   ENUM_TREND_DIR ema = CheckEMA();
   m_state.emaDirection = ema;

   //--- Combined decision: all three must agree
   if(bos != TREND_NONE && bos == adx && bos == ema)
   {
      m_state.direction = bos;
      m_state.isValid   = true;
      m_state.rejectReason = "";
      PrintFormat("[TrendDetector] ✓ TREND %s | BOS=%s ADX=%.1f(+DI=%.1f -DI=%.1f) EMA_slope=%.5f",
                  (bos == TREND_LONG ? "LONG" : "SHORT"),
                  (bos == TREND_LONG ? "BULL" : "BEAR"),
                  m_state.adxValue, m_state.diPlus, m_state.diMinus, m_state.emaSlope);
   }
   else
   {
      m_state.direction = TREND_NONE;
      m_state.isValid   = false;
      if(m_state.rejectReason == "")
         m_state.rejectReason = StringFormat("TREND_REJECT | MISMATCH | BOS=%d ADX=%d EMA=%d", bos, adx, ema);
      PrintFormat("[TrendDetector] %s", m_state.rejectReason);
   }

   return true;
}

#endif // TREND_DETECTOR_MQH
