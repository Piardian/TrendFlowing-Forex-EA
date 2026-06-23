//+------------------------------------------------------------------+
//|                                                TrendFlowing.mq5  |
//|                         Trend Flowing Expert Advisor               |
//|                         SMC/ICT — Liquidity Sweep + FVG            |
//+------------------------------------------------------------------+
#property copyright "TrendFlowing EA"
#property version   "1.31"
#property description "Module 1-7 — v1.31 Time Exit Off"
#property strict

//+------------------------------------------------------------------+
//| Includes                                                          |
//+------------------------------------------------------------------+
#include "TrendDetector.mqh"
#include "SetupDetector.mqh"
#include "EntryEngine.mqh"
#include "RiskManager.mqh"
#include "TradeManager.mqh"
#include "ExecutionEngine.mqh"
#include "Logger.mqh"

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
//--- Trend Detection (Module 1)
input int    inp_ADX_Period           = 14;       // ADX Period
input double inp_ADX_Threshold        = 20.0;     // ADX Trend Threshold
input int    inp_EMA_Period           = 50;       // EMA Period
input int    inp_Swing_Lookback       = 3;        // Swing Lookback Bars

//--- Setup Detection (Module 2)
input int    inp_OB_Lookback          = 20;       // 1H OB Lookback Bars
input double inp_Disp_Multiplier      = 1.5;      // Displacement Body Multiplier
input int    inp_Disp_AvgBars         = 5;        // Displacement Avg Body Bars
input int    inp_FVG_MaxBars          = 16;       // FVG Max Validity (bars)
input int    inp_Sweep_Proximity      = 100;      // Sweep Proximity (points)

//--- Entry Engine (Module 3)
input double inp_Risk_Percent         = 1.0;      // Risk per trade (%)
input int    inp_SL_Buffer            = 5;        // SL buffer (points)
input double inp_SL_ATR_Min_Mult      = 1.0;      // SL min ATR multiplier
input double inp_SL_ATR_Max_Mult      = 4.0;      // SL max ATR multiplier
input double inp_TP1_RR               = 1.5;      // TP1 Risk/Reward
input int    inp_Max_Open_Trades      = 3;        // Max concurrent trades
input bool   inp_Use_Session_Filter   = false;    // Session filter enabled
input int    inp_London_Start         = 7;        // London session start (GMT)
input int    inp_London_End           = 13;       // London session end (GMT)
input int    inp_NY_Start             = 13;       // NY session start (GMT)
input int    inp_NY_End               = 20;       // NY session end (GMT)

//--- Risk Management (Module 4)
input double inp_Max_Daily_Loss_Pct   = 3.0;      // Max daily loss (%)
input double inp_Max_DD_Pct           = 10.0;     // Max drawdown (%)

//--- Trade Management (Module 5)
input double inp_BE_RR                = 1.5;      // Breakeven trigger (R)
input double inp_Trailing_ATR_Mult    = 2.0;      // Trailing ATR multiplier
input bool   inp_Use_Time_Exit        = false;    // NY close time exit

//--- Symbol-Specific: Forex
input int    inp_Forex_MaxSpread      = 20;       // Forex Max Spread (points)
input int    inp_Forex_ATR_Min        = 50;       // Forex ATR Min
input int    inp_Forex_ATR_Max        = 300;      // Forex ATR Max

//--- Symbol-Specific: Gold
input int    inp_Gold_MaxSpread       = 300;      // Gold Max Spread (points)
input int    inp_Gold_ATR_Min         = 800;      // Gold ATR Min
input int    inp_Gold_ATR_Max         = 5000;     // Gold ATR Max

//--- Symbol-Specific: Crypto
input int    inp_Crypto_MaxSpread     = 500;      // Crypto Max Spread (points)
input int    inp_Crypto_ATR_Min       = 5000;     // Crypto ATR Min
input int    inp_Crypto_ATR_Max       = 50000;    // Crypto ATR Max

//--- Symbol-Specific: Indices
input int    inp_Index_MaxSpread      = 150;      // Index Max Spread (points)
input int    inp_Index_ATR_Min        = 300;      // Index ATR Min
input int    inp_Index_ATR_Max        = 3000;     // Index ATR Max

//--- General
input long   inp_Magic_Number         = 20250316; // Magic Number

//+------------------------------------------------------------------+
//| Symbol Group Classification                                       |
//+------------------------------------------------------------------+
enum ENUM_SYMBOL_GROUP
{
   SG_FOREX   = 0,
   SG_GOLD    = 1,
   SG_CRYPTO  = 2,
   SG_INDEX   = 3
};

ENUM_SYMBOL_GROUP g_symbolGroup;
int    g_maxSpread;
int    g_atrMin;
int    g_atrMax;

//+------------------------------------------------------------------+
//| Module Instances                                                  |
//+------------------------------------------------------------------+
CTrendDetector     g_trend;
CSetupDetector     g_setup;
CEntryEngine       g_entry;
CRiskManager       g_risk;
CTradeManager      g_tradeMgr;
CExecutionEngine   g_exec;
CLogger            g_logger;

//--- Logging state trackers (global for Strategy Tester reset)
bool   g_prevSetupReady  = false;
bool   g_prevEntryFired  = false;
bool   g_prevTP1Hit      = false;
bool   g_prevBE          = false;
bool   g_prevDailyLimit  = false;
bool   g_prevMaxDD       = false;
double g_prevTrailSL     = 0;
string g_prevEntryReject = "";

//+------------------------------------------------------------------+
//| DetectSymbolGroup — auto-classify chart symbol                    |
//+------------------------------------------------------------------+
ENUM_SYMBOL_GROUP DetectSymbolGroup(string sym)
{
   string upper = sym;
   StringToUpper(upper);

   if(StringFind(upper, "XAU") >= 0 || StringFind(upper, "GOLD") >= 0)
      return SG_GOLD;

   if(StringFind(upper, "BTC") >= 0 || StringFind(upper, "ETH") >= 0 ||
      StringFind(upper, "LTC") >= 0 || StringFind(upper, "XRP") >= 0)
      return SG_CRYPTO;

   if(StringFind(upper, "US30")  >= 0 || StringFind(upper, "NAS")  >= 0 ||
      StringFind(upper, "GER")  >= 0 || StringFind(upper, "SPX")  >= 0 ||
      StringFind(upper, "DAX")  >= 0 || StringFind(upper, "DJ")   >= 0 ||
      StringFind(upper, "USTEC") >= 0)
      return SG_INDEX;

   return SG_FOREX;
}

void ApplySymbolGroupParams(ENUM_SYMBOL_GROUP grp)
{
   switch(grp)
   {
      case SG_GOLD:   g_maxSpread = inp_Gold_MaxSpread;   g_atrMin = inp_Gold_ATR_Min;   g_atrMax = inp_Gold_ATR_Max;   break;
      case SG_CRYPTO: g_maxSpread = inp_Crypto_MaxSpread; g_atrMin = inp_Crypto_ATR_Min; g_atrMax = inp_Crypto_ATR_Max; break;
      case SG_INDEX:  g_maxSpread = inp_Index_MaxSpread;  g_atrMin = inp_Index_ATR_Min;  g_atrMax = inp_Index_ATR_Max;  break;
      default:        g_maxSpread = inp_Forex_MaxSpread;  g_atrMin = inp_Forex_ATR_Min;  g_atrMax = inp_Forex_ATR_Max;  break;
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Detect symbol group
   g_symbolGroup = DetectSymbolGroup(_Symbol);
   ApplySymbolGroupParams(g_symbolGroup);

   string grpNames[] = {"FOREX", "GOLD", "CRYPTO", "INDEX"};
   PrintFormat("[TrendFlowing] Symbol: %s | Group: %s | MaxSpread=%d ATR=[%d,%d]",
               _Symbol, grpNames[(int)g_symbolGroup], g_maxSpread, g_atrMin, g_atrMax);

   //--- Initialize Module 1
   if(!g_trend.Init(_Symbol, PERIOD_H4, inp_ADX_Period, inp_ADX_Threshold, inp_EMA_Period, inp_Swing_Lookback))
   {
      Print("[TrendFlowing] CRITICAL: TrendDetector init failed!");
      return INIT_FAILED;
   }

   //--- Initialize Module 2
   if(!g_setup.Init(_Symbol, PERIOD_H1, PERIOD_M15,
                    inp_OB_Lookback, inp_Disp_Multiplier, inp_Disp_AvgBars,
                    inp_FVG_MaxBars, inp_Sweep_Proximity))
   {
      Print("[TrendFlowing] CRITICAL: SetupDetector init failed!");
      return INIT_FAILED;
   }

   //--- Initialize Module 3
   if(!g_entry.Init(_Symbol, inp_Magic_Number, PERIOD_M15,
                    inp_Risk_Percent, inp_SL_Buffer,
                    inp_SL_ATR_Min_Mult, inp_SL_ATR_Max_Mult,
                    inp_TP1_RR, inp_Max_Open_Trades, inp_FVG_MaxBars,
                    inp_Use_Session_Filter,
                    inp_London_Start, inp_London_End,
                    inp_NY_Start, inp_NY_End))
   {
      Print("[TrendFlowing] CRITICAL: EntryEngine init failed!");
      return INIT_FAILED;
   }

   //--- Initialize Module 4
   if(!g_risk.Init(inp_Max_Daily_Loss_Pct, inp_Max_DD_Pct))
   {
      Print("[TrendFlowing] CRITICAL: RiskManager init failed!");
      return INIT_FAILED;
   }

   //--- Initialize Module 5
   if(!g_tradeMgr.Init(_Symbol, inp_Magic_Number, PERIOD_M15,
                       inp_Trailing_ATR_Mult, inp_BE_RR, inp_Use_Time_Exit))
   {
      Print("[TrendFlowing] CRITICAL: TradeManager init failed!");
      return INIT_FAILED;
   }

   //--- Initialize Module 6
   if(!g_exec.Init(_Symbol))
   {
      Print("[TrendFlowing] CRITICAL: ExecutionEngine init failed!");
      return INIT_FAILED;
   }

   //--- Initialize Module 7
   g_logger.Init(_Symbol);

   Print("[TrendFlowing] v1.31 Time Exit Off - All Modules Ready");
   g_logger.Log("EA_START", "v1.31 Time Exit Off - All modules initialized", "OK");

   //--- Reset logging state trackers
   g_prevSetupReady = false;
   g_prevEntryFired = false;
   g_prevTP1Hit     = false;
   g_prevBE         = false;
   g_prevDailyLimit = false;
   g_prevMaxDD      = false;
   g_prevTrailSL    = 0;
   g_prevEntryReject = "";

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_logger.Log("EA_STOP", StringFormat("Reason: %d", reason), "OK");
   g_trend.Deinit();
   g_setup.Deinit();
   g_entry.Deinit();
   g_risk.Deinit();
   g_tradeMgr.Deinit();
   g_exec.Deinit();
   g_logger.Deinit();
   Comment("");
   Print("[TrendFlowing] Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Module 1: Trend Detection
   if(!g_trend.Update())
   {
      Comment("TrendDetector: Data Error");
      return;
   }

   TrendState ts = g_trend.GetState();

   //--- Module 2: Setup Detection
   g_setup.Update(ts.direction, ts.isValid);
   SetupState ss = g_setup.GetState();

   //--- Module 4: Risk Manager (BEFORE entry)
   g_risk.Update();
   RiskState rs = g_risk.GetState();

   //--- Module 6: Execution Engine (news filter)
   g_exec.Update();
   ExecutionState xs = g_exec.GetState();

   //--- Log setup events
   if(ss.setupReady && !g_prevSetupReady)
      g_logger.Log("SETUP_READY", StringFormat("FVG mid=%.5f", ss.fvgMid), "OK");
   if(!ss.setupReady && g_prevSetupReady && ss.rejectReason != "")
      g_logger.Log("SETUP_REJECT", ss.rejectReason, "REJECT");
   g_prevSetupReady = ss.setupReady;

   //--- Log trend reject (periodic — only when trend is invalid)
   if(!ts.isValid && ts.rejectReason != "")
   {
      static string lastTrendReject = "";
      if(ts.rejectReason != lastTrendReject)
      {
         g_logger.Log("TREND_REJECT", ts.rejectReason, "REJECT");
         lastTrendReject = ts.rejectReason;
      }
   }

   //--- Module 3: Entry Engine (gated by risk + news)
   EntryState es = g_entry.GetState();
   bool prevPending = es.orderPending;
   bool prevFired   = es.entryFired;

   bool allowNewEntry = (rs.tradingAllowed && !xs.newsBlocking);

   if(xs.newsBlocking)
   {
      if(!g_prevEntryFired && ss.setupReady)
         g_logger.Log("NEWS_BLOCK", xs.newsEventName, "SKIP");
   }

   g_entry.Update(ss, AccountInfoDouble(ACCOUNT_BALANCE), g_maxSpread, allowNewEntry);
   es = g_entry.GetState();

   //--- Log entry events
   if(es.orderPending && !prevPending)
      g_logger.Log("ENTRY_SENT", StringFormat("ticket=%d entry=%.5f SL=%.5f TP1=%.5f lot=%.2f",
                   es.orderTicket, es.entryPrice, es.stopLoss, es.takeProfit1, es.lotSize), "OK");
   if(es.entryFired && !prevFired)
      g_logger.Log("ENTRY_FILLED", StringFormat("ticket=%d", es.orderTicket), "OK");
   if(!es.orderPending && prevPending && !es.entryFired)
      g_logger.Log("ENTRY_CANCEL", "Bar limit or external", "CANCEL");
   if(!es.orderPending && !es.entryFired && es.rejectReason != "" && ss.setupReady)
   {
      if(es.rejectReason != g_prevEntryReject)
         g_logger.Log("ENTRY_REJECT", es.rejectReason, "REJECT");
      g_prevEntryReject = es.rejectReason;
   }
   else
   {
      g_prevEntryReject = "";
   }
   g_prevEntryFired = es.entryFired;

   bool consumeSetup = false;
   string consumeReason = "";

   if(prevPending && !es.orderPending && !es.entryFired)
   {
      consumeSetup = true;
      consumeReason = "SETUP_CONSUMED | ORDER_CANCELLED";
   }
   else if(prevFired && !es.entryFired)
   {
      consumeSetup = true;
      consumeReason = "SETUP_CONSUMED | POSITION_CLOSED";
   }
   else if(!es.orderPending && !es.entryFired && es.rejectReason != "" && ss.setupReady)
   {
      bool structuralReject =
         (StringFind(es.rejectReason, "MISSED_LIMIT") >= 0 ||
          StringFind(es.rejectReason, "INVALID_SL_DISTANCE") >= 0 ||
          StringFind(es.rejectReason, "OrderSend failed") >= 0);

      if(structuralReject)
      {
         consumeSetup = true;
         consumeReason = "SETUP_CONSUMED | " + es.rejectReason;
      }
   }

   if(consumeSetup && g_setup.ConsumeSetup(consumeReason))
   {
      ss = g_setup.GetState();
      g_prevSetupReady = ss.setupReady;
      g_logger.Log("SETUP_RESET", consumeReason, "RESET");
   }

   //--- Module 5: Trade Manager (always runs — manages open positions)
   g_tradeMgr.Update(es);
   TradeState trs = g_tradeMgr.GetState();

   //--- Log trade management events
   if(trs.tp1Hit && !g_prevTP1Hit)
      g_logger.Log("TP1_HIT", StringFormat("SL=%.5f", trs.currentSL), "OK");
   g_prevTP1Hit = trs.tp1Hit;

   if(trs.beActive && !g_prevBE)
      g_logger.Log("BE_ACTIVE", StringFormat("SL=%.5f", trs.currentSL), "OK");
   g_prevBE = trs.beActive;

   //--- Log trailing SL moves
   if(trs.hasPosition && trs.tp1Hit &&
      trs.currentSL != g_prevTrailSL && g_prevTrailSL != 0)
   {
      g_logger.Log("TRAIL_MOVE",
                   StringFormat("SL=%.5f ATR=%.5f", trs.currentSL, trs.trailingATR), "OK");
   }
   g_prevTrailSL = trs.currentSL;

   if(rs.dailyLimitHit && !g_prevDailyLimit)
      g_logger.Log("DAILY_LIMIT", rs.haltReason, "HALT");
   g_prevDailyLimit = rs.dailyLimitHit;

   if(rs.maxDDHit && !g_prevMaxDD)
      g_logger.Log("MAX_DD", rs.haltReason, "HALT");
   g_prevMaxDD = rs.maxDDHit;

   //--- Display on chart
   string dirStr = "NONE";
   if(ts.direction == TREND_LONG)  dirStr = "▲ LONG";
   if(ts.direction == TREND_SHORT) dirStr = "▼ SHORT";

   string setupStr = "WAITING";
   if(ss.setupReady) setupStr = "★ READY";

   string entryStr = "IDLE";
   if(es.orderPending) entryStr = "PENDING";
   if(es.entryFired)   entryStr = "★ FILLED";

   string riskStr = rs.tradingAllowed ? "ALLOWED" : "HALTED";

   string tradeStr = "NO POS";
   if(trs.hasPosition)
   {
      if(trs.tp1Hit)
         tradeStr = "TRAILING";
      else if(trs.beActive)
         tradeStr = "BE";
      else
         tradeStr = "ACTIVE";
   }

   string newsStr = xs.newsBlocking
      ? StringFormat("BLOCKED (%s)", xs.newsEventName)
      : "CLEAR";

   string info = StringFormat(
      "=== TREND FLOWING v1.29 ===\n"
      "Symbol: %s | Group: %s\n"
      "────────────────────────────────\n"
      "TREND: %s  (valid=%s)\n"
      "BOS: %s | ADX: %.1f (+DI=%.1f -DI=%.1f) → %s\n"
      "EMA: %.5f slope=%.6f → %s\n"
      "────────────────────────────────\n"
      "SETUP: %s  dir=%s\n"
      "OB:   %s  [%.5f - %.5f]\n"
      "Sweep: %s  price=%.5f\n"
      "Disp:  %s  ratio=%.1f\n"
      "FVG:   %s  [%.5f - %.5f] mid=%.5f  age=%d/%d\n"
      "────────────────────────────────\n"
      "ENTRY: %s | lot=%.2f\n"
      "  SL=%.5f | TP1=%.5f | bars=%d/%d\n"
      "────────────────────────────────\n"
      "TRADE: %s | BE=%s | TP1=%s\n"
      "  SL=%.5f | ATR_trail=%.5f\n"
      "────────────────────────────────\n"
      "RISK: %s | Daily: $%.2f / -$%.2f\n"
      "  DD: %.1f%% / %.1f%% | Peak: $%.2f\n"
      "────────────────────────────────\n"
      "NEWS: %s\n"
      "────────────────────────────────\n"
      "Update: %s\n"
      "%s",
      _Symbol,
      EnumToString(g_symbolGroup),
      dirStr,
      (ts.isValid ? "YES" : "NO"),
      (ts.bosDirection == TREND_LONG ? "BULL" : (ts.bosDirection == TREND_SHORT ? "BEAR" : "NONE")),
      ts.adxValue, ts.diPlus, ts.diMinus,
      (ts.adxDirection == TREND_LONG ? "BULL" : (ts.adxDirection == TREND_SHORT ? "BEAR" : "WAIT")),
      ts.emaValue, ts.emaSlope,
      (ts.emaDirection == TREND_LONG ? "UP" : (ts.emaDirection == TREND_SHORT ? "DN" : "FLAT")),
      setupStr,
      (ss.setupDirection == TREND_LONG ? "LONG" : (ss.setupDirection == TREND_SHORT ? "SHORT" : "NONE")),
      (ss.hasOB ? "✓" : "✗"),
      ss.obLow, ss.obHigh,
      (ss.hasSweep ? "✓" : "✗"),
      ss.sweepPrice,
      (ss.hasDisplacement ? "✓" : "✗"),
      ss.dispBodyRatio,
      (ss.hasFVG && ss.fvgValid ? "✓" : "✗"),
      ss.fvgLow, ss.fvgHigh, ss.fvgMid,
      ss.fvgBarAge, inp_FVG_MaxBars,
      entryStr,
      es.lotSize,
      es.stopLoss, es.takeProfit1,
      es.barsSinceEntry, inp_FVG_MaxBars,
      tradeStr,
      (trs.beActive ? "YES" : "NO"),
      (trs.tp1Hit ? "HIT" : "WAIT"),
      trs.currentSL, trs.trailingATR,
      riskStr,
      rs.dailyPnL, rs.dailyLossLimit,
      rs.currentDrawdown, inp_Max_DD_Pct, rs.peakBalance,
      newsStr,
      TimeToString(ts.lastUpdateTime, TIME_DATE | TIME_MINUTES),
      (rs.haltReason != "" ? "RISK: " + rs.haltReason :
       (xs.newsBlocking ? "NEWS: " + xs.newsEventName :
        (es.rejectReason != "" ? "Entry: " + es.rejectReason :
         (ss.rejectReason != "" ? "Setup: " + ss.rejectReason : 
          (ts.rejectReason != "" ? "Trend: " + ts.rejectReason : "")))))
   );

   Comment(info);
}
//+------------------------------------------------------------------+
