//+------------------------------------------------------------------+
//|                                               RiskManager.mqh    |
//|                         Trend Flowing EA — Module 4               |
//|              Daily Loss Limit + Max Drawdown Protection           |
//+------------------------------------------------------------------+
#ifndef RISK_MANAGER_MQH
#define RISK_MANAGER_MQH

//+------------------------------------------------------------------+
//| RiskState struct                                                   |
//+------------------------------------------------------------------+
struct RiskState
{
   double   dailyStartBalance;  // günün başındaki bakiye
   double   dailyPnL;           // bugünkü realized + floating P/L
   double   dailyLossLimit;     // bakiye × maxDailyLossPct
   bool     dailyLimitHit;      // günlük limit doldu mu?

   double   peakBalance;        // EA başladığından beri max bakiye
   double   currentDrawdown;    // peak'ten düşüş (%)
   bool     maxDDHit;           // max DD aşıldı mı?

   bool     tradingAllowed;     // false ise hiçbir modül emir gönderemez
   string   haltReason;         // neden durduruldu?
   datetime lastUpdateTime;
   datetime dailyResetTime;     // son gün sıfırlama zamanı
};

//+------------------------------------------------------------------+
//| CRiskManager                                                      |
//+------------------------------------------------------------------+
class CRiskManager
{
private:
   double          m_maxDailyLossPct;
   double          m_maxDDPct;
   RiskState       m_state;
   int             m_lastDay;     // son işlem günü (day of year)
   int             m_lastYear;    // son işlem yılı

   void            CheckDailyReset();
   void            UpdateDailyPnL();
   void            UpdateDrawdown();

public:
                   CRiskManager();
                  ~CRiskManager();
   bool            Init(double maxDailyLossPct, double maxDDPct);
   void            Deinit() {}
   bool            Update();

   bool            IsTradingAllowed() const { return m_state.tradingAllowed; }
   RiskState       GetState()         const { return m_state; }
};

//+------------------------------------------------------------------+
//| Constructor                                                       |
//+------------------------------------------------------------------+
CRiskManager::CRiskManager()
   : m_maxDailyLossPct(3.0), m_maxDDPct(10.0), m_lastDay(-1), m_lastYear(-1)
{
   ZeroMemory(m_state);
   m_state.tradingAllowed = true;
}

CRiskManager::~CRiskManager() {}

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
bool CRiskManager::Init(double maxDailyLossPct, double maxDDPct)
{
   m_maxDailyLossPct = MathMax(maxDailyLossPct, 0.5);
   m_maxDDPct        = MathMax(maxDDPct, 1.0);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);

   m_state.dailyStartBalance = bal;
   m_state.dailyPnL          = 0;
   m_state.dailyLossLimit    = bal * m_maxDailyLossPct / 100.0;
   m_state.dailyLimitHit     = false;

   m_state.peakBalance       = bal;
   m_state.currentDrawdown   = 0;
   m_state.maxDDHit          = false;

   m_state.tradingAllowed    = true;
   m_state.haltReason        = "";
   m_state.lastUpdateTime    = TimeCurrent();
   m_state.dailyResetTime    = TimeCurrent();

   MqlDateTime dt;
   TimeCurrent(dt);
   m_lastDay  = dt.day_of_year;
   m_lastYear = dt.year;

   PrintFormat("[RiskManager] OK: DailyMax=%.1f%% ($%.2f) MaxDD=%.1f%% StartBal=%.2f",
               m_maxDailyLossPct, m_state.dailyLossLimit, m_maxDDPct, bal);
   return true;
}

//+------------------------------------------------------------------+
//| Check if day changed → reset daily counters                       |
//+------------------------------------------------------------------+
void CRiskManager::CheckDailyReset()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int today = dt.day_of_year;

   if(today == m_lastDay && dt.year == m_lastYear) return;

   //--- New day
   m_lastDay  = today;
   m_lastYear = dt.year;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);

   m_state.dailyStartBalance = bal;
   m_state.dailyPnL          = 0;
   m_state.dailyLossLimit    = bal * m_maxDailyLossPct / 100.0;
   m_state.dailyLimitHit     = false;
   m_state.dailyResetTime    = TimeCurrent();

   //--- Restore trading if only daily limit was hit (not max DD)
   if(!m_state.maxDDHit)
   {
      m_state.tradingAllowed = true;
      m_state.haltReason     = "";
   }

   PrintFormat("[RiskManager] Yeni gün — DailyStart=%.2f Limit=$%.2f DD=%.1f%%",
               bal, m_state.dailyLossLimit, m_state.currentDrawdown);
}

//+------------------------------------------------------------------+
//| Calculate daily P/L (realized + floating)                         |
//+------------------------------------------------------------------+
void CRiskManager::UpdateDailyPnL()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   m_state.dailyPnL = equity - m_state.dailyStartBalance;

   if(m_state.dailyLimitHit) return;  // limit kontrolü atla ama P/L güncellendi

   //--- Check daily loss limit
   if(m_state.dailyPnL <= -m_state.dailyLossLimit)
   {
      m_state.dailyLimitHit  = true;
      m_state.tradingAllowed = false;
      m_state.haltReason     = StringFormat("Günlük kayıp limiti: $%.2f / -$%.2f",
                                             m_state.dailyPnL, m_state.dailyLossLimit);
      PrintFormat("[RiskManager] ✗ HALT: %s", m_state.haltReason);
      Alert("[TrendFlowing] ", m_state.haltReason);
   }
}

//+------------------------------------------------------------------+
//| Update peak balance and drawdown                                   |
//+------------------------------------------------------------------+
void CRiskManager::UpdateDrawdown()
{
   if(m_state.maxDDHit) return;  // permanently halted

   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- Update peak (based on closed-trade balance)
   if(bal > m_state.peakBalance)
      m_state.peakBalance = bal;

   //--- Drawdown from peak (using equity for floating losses)
   if(m_state.peakBalance > 0)
      m_state.currentDrawdown = (m_state.peakBalance - equity) / m_state.peakBalance * 100.0;
   else
      m_state.currentDrawdown = 0;

   //--- Check max DD threshold
   if(m_state.currentDrawdown >= m_maxDDPct)
   {
      m_state.maxDDHit       = true;
      m_state.tradingAllowed = false;
      m_state.haltReason     = StringFormat("Max Drawdown: %.1f%% >= %.1f%%",
                                             m_state.currentDrawdown, m_maxDDPct);
      PrintFormat("[RiskManager] ✗ HALT: %s — EA restart gerekli", m_state.haltReason);
      Alert("[TrendFlowing] ", m_state.haltReason, " — EA restart gerekli!");
   }
}

//+------------------------------------------------------------------+
//| Update — called every tick from OnTick()                          |
//+------------------------------------------------------------------+
bool CRiskManager::Update()
{
   m_state.lastUpdateTime = TimeCurrent();

   //--- Day change check
   CheckDailyReset();

   //--- Daily P/L
   UpdateDailyPnL();

   //--- Max drawdown
   UpdateDrawdown();

   return true;
}

#endif // RISK_MANAGER_MQH
