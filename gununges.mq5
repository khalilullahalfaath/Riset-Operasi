//+------------------------------------------------------------------+
//|             Golden_V1_Remastered_IceMountain.mq5                 |
//|    Based on User's V1.6 - Optimized for Profit Protection        |
//|        STRATEGY: Aggressive Climb -> Defensive Summit            |
//+------------------------------------------------------------------+
#define VERSION "1.7"
#property version VERSION
#property strict

#include <Trade/Trade.mqh>

//--- Input Parameters
input group "Money Management"
input double RiskPercent    = 2.0;       // Risk Percent (Normal)
input double FixedLots      = 0.1;       // Lot dasar
input double TargetMultiplier = 5.0;     // Target Level (5x Modal Awal)

input group "Ice Mountain Mode (After Target)"
input bool   UseDefensiveMode = true;    // Aktifkan Mode Bertahan setelah Target?
input double DefensiveRiskDivisor = 2.0; // Bagi Risiko dengan angka ini (2.0 = Setengah resiko)
input double ProfitLockPercent = 10.0;   // Toleransi Drawdown dari Puncak Profit (%)
                                         // Contoh: Jika saldo 5000, toleransi 10% = Stop di 4500.

input group "Strategy Settings"
input ENUM_TIMEFRAMES Timeframe = PERIOD_H1;
input int    BarsN          = 5;         // Fractal 5 Bar
input int    OrderDistPoints= 50;        // Jarak Entry 50 Point
input int    ExpirationHours= 24;        // Expired 1 hari

input group "Exits (Scalping)"
input int    TpPoints       = 500;       // TP 50 Pips
input int    SlPoints       = 200;       // SL 20 Pips
input int    TslTriggerPoints = 10;      // Start Trailing
input int    TslPoints      = 10;        // Step Trailing

input int    Magic          = 111222;

//--- Global Variables
CTrade trade;
ulong buyTicket = 0, sellTicket = 0;
int totalBars;
double initialBalance = 0; 
bool isSummitReached = false; // Penanda apakah kita sudah sampai puncak 5x
double highestBalance = 0;    // Mencatat saldo tertinggi yang pernah dicapai

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(Magic);
    trade.SetTypeFilling(ORDER_FILLING_FOK); 
    
    // 1. Simpan Saldo Awal
    initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    highestBalance = initialBalance; // Start point
    
    Print("--- EA STARTED (ICE MOUNTAIN VERSION) ---");
    Print("Initial Balance: ", DoubleToString(initialBalance, 2));
    Print("Summit Target (", TargetMultiplier, "x): ", DoubleToString(initialBalance * TargetMultiplier, 2));
    
    RecoverOrders();
    
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    
}

//+------------------------------------------------------------------+
//| Main Logic                                                       |
//+------------------------------------------------------------------+
void OnTick() {
    // --- 1. MONITOR SALDO & MODE BERTAHAN ---
    // Jika fungsi ini mengembalikan true, artinya kita kena Stop Loss Equity (Tali Pengaman Putus)
    if(ManageMoneyFlow()) return; 

    // 2. Manage Trailing Stop
    ManageTrailing();

    // 3. Entry Logic
    int bars = iBars(_Symbol, Timeframe);
    if(totalBars != bars) {
        totalBars = bars;
        
        DeletePendingOrders(); 

        double high = FindHigh();
        double low  = FindLow();

        // Hanya entry jika kita belum "mati" (Hard Stop belum kena)
        if(high > 0) ExecuteBuy(high);
        if(low > 0)  ExecuteSell(low);
    }
}

//+------------------------------------------------------------------+
//| Logic "Ice Mountain" & Profit Guardian                           |
//+------------------------------------------------------------------+
bool ManageMoneyFlow() {
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double currentEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // Update Saldo Tertinggi (High Water Mark)
    if(currentBalance > highestBalance) {
        highestBalance = currentBalance;
    }

    double targetAmount = initialBalance * TargetMultiplier;

    // --- FASE 1: CEK APAKAH SUDAH SAMPAI PUNCAK? ---
    if(!isSummitReached && currentBalance >= targetAmount) {
        isSummitReached = true;
        Print("🏔️ SUMMIT REACHED! (5x Target). Entering Defensive Mode.");
        Print("Risk will be divided by: ", DefensiveRiskDivisor);
        Print("Profit Locking Active.");
    }

    // --- FASE 2: MODE BERTAHAN (JIKA SUDAH PERNAH SAMPAI PUNCAK) ---
    if(isSummitReached && UseDefensiveMode) {
        
        // Hitung batas aman (Safety Net)
        // Jika Saldo Tertinggi $5000 dan Lock 10%, maka batas stop adalah $4500.
        // Batas ini NAIK TERUS mengikuti saldo tertinggi (Trailing Equity Stop).
        double safetyNetLevel = highestBalance * (1.0 - (ProfitLockPercent / 100.0));
        
        // Cek Bahaya: Jika Equity turun menembus Safety Net
        if(currentEquity < safetyNetLevel) {
            Print("================================================");
            Print("⚠️ WEATHER ALERT: SLIPPING DOWN THE MOUNTAIN!");
            Print("Safety Net Triggered at Equity: ", DoubleToString(currentEquity, 2));
            Print("Highest Balance Was: ", DoubleToString(highestBalance, 2));
            Print("Secured Profit: ", DoubleToString(currentEquity - initialBalance, 2));
            Print("CLOSING ALL TRADES & STOPPING.");
            Print("================================================");
            
            // Tutup Semua Posisi Segera
            CloseAllPositions();
            DeletePendingOrders();
            
            // Hapus EA (Stop Total)
            ExpertRemove();
            return true;
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Logika Entry                                                     |
//+------------------------------------------------------------------+
void ExecuteBuy(double entryLevel) {
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double entry = NormalizeDouble(entryLevel + OrderDistPoints * _Point, _Digits);

    if(ask > entry) return; 

    double sl = NormalizeDouble(entry - SlPoints * _Point, _Digits);
    double tp = NormalizeDouble(entry + TpPoints * _Point, _Digits);
    
    double lot = CalcLots(MathAbs(entry - sl));
    datetime exp = TimeCurrent() + ExpirationHours * 3600;
    
    trade.BuyStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, exp);
}

void ExecuteSell(double entryLevel) {
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double entry = NormalizeDouble(entryLevel - OrderDistPoints * _Point, _Digits);

    if(bid < entry) return;

    double sl = NormalizeDouble(entry + SlPoints * _Point, _Digits);
    double tp = NormalizeDouble(entry - TpPoints * _Point, _Digits);
    
    double lot = CalcLots(MathAbs(entry - sl));
    datetime exp = TimeCurrent() + ExpirationHours * 3600;
    
    trade.SellStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, exp);
}

//+------------------------------------------------------------------+
//| Helper Functions (Updated CalcLots)                              |
//+------------------------------------------------------------------+
double FindHigh() {
    for(int i = 0; i < 100; i++) {
        if(i > BarsN && iHighest(_Symbol, Timeframe, MODE_HIGH, BarsN*2+1, i-BarsN) == i) {
            return iHigh(_Symbol, Timeframe, i);
        }
    }
    return 0;
}

double FindLow() {
    for(int i = 0; i < 100; i++) {
        if(i > BarsN && iLowest(_Symbol, Timeframe, MODE_LOW, BarsN*2+1, i-BarsN) == i) {
            return iLow(_Symbol, Timeframe, i);
        }
    }
    return 0;
}

double CalcLots(double slDist) {
    // Tentukan Risk Berdasarkan Mode
    double effectiveRisk = RiskPercent;
    
    // JIKA sudah sampai puncak, Bagi Resiko (Contoh: 2% jadi 1%)
    if(isSummitReached && UseDefensiveMode) {
        effectiveRisk = RiskPercent / DefensiveRiskDivisor;
    }

    if(effectiveRisk <= 0) return FixedLots;
    
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskMoney = balance * (effectiveRisk / 100.0);
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    if(tickVal == 0) tickVal = 1.0;
    
    double points = slDist / _Point;
    double lot = riskMoney / (points * tickVal);
    
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;
    
    double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    
    if(lot < min) lot = min;
    if(lot > max) lot = max;
    
    return lot;
}

void ManageTrailing() {
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetInteger(POSITION_MAGIC) != Magic) continue;

        double currentSL = PositionGetDouble(POSITION_SL);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
        long type = PositionGetInteger(POSITION_TYPE);

        if(type == POSITION_TYPE_BUY) {
            if(currentPrice > openPrice + TslTriggerPoints * point) {
                double newSL = currentPrice - TslPoints * point;
                if(newSL > currentSL && newSL > openPrice) {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
        else if(type == POSITION_TYPE_SELL) {
            if(currentPrice < openPrice - TslTriggerPoints * point) {
                double newSL = currentPrice + TslPoints * point;
                if((newSL < currentSL || currentSL == 0) && newSL < openPrice) {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}

void DeletePendingOrders() {
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if(OrderGetInteger(ORDER_MAGIC) == Magic) trade.OrderDelete(ticket);
    }
}

void CloseAllPositions() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetInteger(POSITION_MAGIC) == Magic) trade.PositionClose(ticket);
    }
}

void RecoverOrders() {
}