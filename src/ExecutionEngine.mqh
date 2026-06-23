//+------------------------------------------------------------------+
//|                                           ExecutionEngine.mqh    |
//|                         Trend Flowing EA — Module 6               |
//|                     News Filter + Execution Guard                  |
//+------------------------------------------------------------------+
#ifndef EXECUTION_ENGINE_MQH
#define EXECUTION_ENGINE_MQH

//+------------------------------------------------------------------+
//| ExecutionState struct                                              |
//+------------------------------------------------------------------+
struct ExecutionState
{
   bool           newsBlocking;      // haber engeli aktif mi?
   string         newsEventName;     // hangi haber?
   datetime       newsEventTime;     // haberin zamanı
   int            retryCount;        // son retry sayısı
   string         lastError;
   datetime       lastUpdateTime;
};

//+------------------------------------------------------------------+
//| CExecutionEngine                                                   |
//+------------------------------------------------------------------+
class CExecutionEngine
{
private:
   string          m_symbol;
   string          m_baseCurrency;
   string          m_quoteCurrency;
   ExecutionState  m_state;

   void            ExtractCurrencies();
   void            CheckNews();

public:
                   CExecutionEngine();
                  ~CExecutionEngine();
   bool            Init(string sym);
   void            Deinit() {}
   bool            Update();

   bool            IsNewsBlocking() const { return m_state.newsBlocking; }
   ExecutionState  GetState()       const { return m_state; }
};

//+------------------------------------------------------------------+
//| Constructor                                                       |
//+------------------------------------------------------------------+
CExecutionEngine::CExecutionEngine()
{
   ZeroMemory(m_state);
}

CExecutionEngine::~CExecutionEngine() {}

//+------------------------------------------------------------------+
//| Extract base and quote currencies from symbol                     |
//+------------------------------------------------------------------+
void CExecutionEngine::ExtractCurrencies()
{
   m_baseCurrency  = SymbolInfoString(m_symbol, SYMBOL_CURRENCY_BASE);
   m_quoteCurrency = SymbolInfoString(m_symbol, SYMBOL_CURRENCY_PROFIT);

   //--- Fallback: parse first 6 chars (e.g. EURUSD → EUR, USD)
   if(m_baseCurrency == "" && StringLen(m_symbol) >= 6)
   {
      m_baseCurrency  = StringSubstr(m_symbol, 0, 3);
      m_quoteCurrency = StringSubstr(m_symbol, 3, 3);
   }
}

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
bool CExecutionEngine::Init(string sym)
{
   m_symbol = sym;
   ExtractCurrencies();

   ZeroMemory(m_state);

   PrintFormat("[ExecutionEngine] OK: %s base=%s quote=%s",
               m_symbol, m_baseCurrency, m_quoteCurrency);
   return true;
}

//+------------------------------------------------------------------+
//| Check news — CalendarValueHistory for HIGH impact events          |
//| Blackout: [event_time - 30min, event_time + 15min]                |
//+------------------------------------------------------------------+
void CExecutionEngine::CheckNews()
{
   m_state.newsBlocking  = false;
   m_state.newsEventName = "";
   m_state.newsEventTime = 0;

   datetime now = TimeTradeServer();
   datetime from = now - 1800;   // 30 min before now
   datetime to   = now + 1800;   // 30 min after now

   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to);

   if(count <= 0) return;  // no data or error — silently pass

   for(int i = 0; i < count; i++)
   {
      //--- Get event details
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event))
         continue;

      //--- Only HIGH importance
      if(event.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;

      //--- Get country for currency check
      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country))
         continue;

      //--- Check if event currency matches our symbol
      string eventCurrency = country.currency;
      if(eventCurrency != m_baseCurrency && eventCurrency != m_quoteCurrency)
         continue;

      //--- Blackout window: [event_time - 30min, event_time + 15min]
      datetime eventTime = values[i].time;
      datetime blackoutStart = eventTime - 1800;  // 30 min before
      datetime blackoutEnd   = eventTime + 900;   // 15 min after

      if(now >= blackoutStart && now <= blackoutEnd)
      {
         m_state.newsBlocking  = true;
         m_state.newsEventName = event.name;
         m_state.newsEventTime = eventTime;

         int minutesUntil = (int)((eventTime - now) / 60);
         string timeStr = (minutesUntil > 0)
                           ? StringFormat("in %d min", minutesUntil)
                           : StringFormat("%d min ago", -minutesUntil);

         PrintFormat("[ExecutionEngine] NEWS_BLOCK | %s | %s %s | %s",
                     m_symbol, event.name, timeStr, eventCurrency);
         return;  // first blocking event is enough
      }
   }
}

//+------------------------------------------------------------------+
//| Update — called every tick                                        |
//+------------------------------------------------------------------+
bool CExecutionEngine::Update()
{
   m_state.lastUpdateTime = TimeCurrent();
   CheckNews();
   return true;
}

#endif // EXECUTION_ENGINE_MQH
