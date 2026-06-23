//+------------------------------------------------------------------+
//|                                                    Logger.mqh    |
//|                         Trend Flowing EA — Module 7               |
//|                           CSV Event Logger                         |
//+------------------------------------------------------------------+
#ifndef LOGGER_MQH
#define LOGGER_MQH

//+------------------------------------------------------------------+
//| CLogger                                                           |
//+------------------------------------------------------------------+
class CLogger
{
private:
   string          m_symbol;
   string          m_folder;
   int             m_fileHandle;
   int             m_lastDay;
   int             m_lastYear;

   bool            OpenFile();
   void            CloseFile();

public:
                   CLogger();
                  ~CLogger();
   bool            Init(string sym);
   void            Deinit();
   void            Log(string event, string detail, string result);
};

//+------------------------------------------------------------------+
//| Constructor / Destructor                                          |
//+------------------------------------------------------------------+
CLogger::CLogger()
   : m_fileHandle(INVALID_HANDLE), m_lastDay(-1), m_lastYear(-1)
{
}

CLogger::~CLogger() { Deinit(); }

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
bool CLogger::Init(string sym)
{
   m_symbol = sym;
   m_folder = "TrendFlowing";

   //--- Create folder if it doesn't exist
   FolderCreate(m_folder);

   if(!OpenFile())
   {
      PrintFormat("[Logger] WARNING: Initial file open failed — logging disabled until retry");
      return true;  // don't block EA startup
   }

   PrintFormat("[Logger] OK: %s folder=%s", m_symbol, m_folder);
   return true;
}

//+------------------------------------------------------------------+
//| Deinit — close file handle                                        |
//+------------------------------------------------------------------+
void CLogger::Deinit()
{
   CloseFile();
}

//+------------------------------------------------------------------+
//| Open/create daily CSV file                                        |
//+------------------------------------------------------------------+
bool CLogger::OpenFile()
{
   CloseFile();  // close previous if any

   MqlDateTime dt;
   TimeCurrent(dt);
   m_lastDay  = dt.day_of_year;
   m_lastYear = dt.year;

   string filename = StringFormat("%s/TF_%s_%04d%02d%02d.csv",
                                   m_folder, m_symbol,
                                   dt.year, dt.mon, dt.day);

   //--- Try to open existing file for append
   m_fileHandle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');

   if(m_fileHandle == INVALID_HANDLE)
   {
      PrintFormat("[Logger] FileOpen failed: %s err=%d", filename, GetLastError());
      return false;
   }

   //--- If file is empty (new), write header
   if(FileSize(m_fileHandle) == 0)
   {
      FileWrite(m_fileHandle, "Timestamp", "Symbol", "Event", "Detail", "Result");
   }

   //--- Seek to end for appending
   FileSeek(m_fileHandle, 0, SEEK_END);

   return true;
}

//+------------------------------------------------------------------+
//| Close file handle                                                  |
//+------------------------------------------------------------------+
void CLogger::CloseFile()
{
   if(m_fileHandle != INVALID_HANDLE)
   {
      FileClose(m_fileHandle);
      m_fileHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Log — write one event row to CSV                                  |
//+------------------------------------------------------------------+
void CLogger::Log(string event, string detail, string result)
{
   //--- Check for day change → new file
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day_of_year != m_lastDay || dt.year != m_lastYear)
   {
      OpenFile();  // opens new daily file
   }

   //--- If no valid handle, try to reopen
   if(m_fileHandle == INVALID_HANDLE)
   {
      if(!OpenFile()) return;  // silently skip if can't open
   }

   string timestamp = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);

   FileWrite(m_fileHandle, timestamp, m_symbol, event, detail, result);
   FileFlush(m_fileHandle);  // ensure data is written
}

#endif // LOGGER_MQH
