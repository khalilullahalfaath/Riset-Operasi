//+------------------------------------------------------------------+
//|          Golden_UGM_Adaptive_V24.mq5                             |
//|    BASE: V1.8 (Fractal Breakout)                                 |
//|    UPGRADE: ADAPTIVE CAPITAL ALLOCATION (Performance Based)      |
//|    LOGIC: Good Trend = Boost Risk | Bad Trend = Cut Risk         |
//+------------------------------------------------------------------+
#define VERSION "24.0_ADAPTIVE_CAPITAL"
#property version VERSION
#property strict

#include <Trade/Trade.mqh>

//--- 1. PARAMETER UTAMA
input group "Adaptive Money Management"
input double BaseRiskPercent = 2.0;       // Resiko Standar (2%)
input int    ReviewPeriod    = 30;        // Cek performa 30 hari ke belakang
input double MaxRiskBoost    = 2.0;       // Maksimal pelipatgandaan (Max Risk = 4%)
input double MinRiskCut      = 0.5;       // Minimal pengurangan (Min Risk = 1%)

input group "Strategy Settings (V1.8 Original)"
input ENUM_TIMEFRAMES Timeframe = PERIOD_H1;
input int    BarsN           = 5;         
input int    OrderDistPoints = 50;        
input int    ExpirationHours = 24;        

input group "Exits"
input int    TpPoints        = 500;       
input int    SlPoints        = 200;       
input int    TslTriggerPoints= 10;        
input int    TslPoints       = 10;        

input int    Magic           = 20252424;

//--- Global Variables
CTrade trade;
int totalBars;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(Magic);
    trade.SetTypeFilling(ORDER_FILLING_FOK); 
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { }

//+------------------------------------------------------------------+
//| Main Logic                                                       |
//+------------------------------------------------------------------+
void OnTick() {
    // 1. Trailing Stop
    ManageTrailing();

    // 2. Entry Logic (Fractal Breakout)
    int bars = iBars(_Symbol, Timeframe);
    if(totalBars != bars) {
        totalBars = bars;
        DeletePendingOrders(); 

        double high = FindHigh();
        double low  = FindLow();

        // Hitung "Adaptive Risk" sebelum entry
        double dynamicRisk = CalculateAdaptiveRisk();

        if(high > 0) ExecuteBuy(high, dynamicRisk);
        if(low > 0)  ExecuteSell(low, dynamicRisk);
    }
}

//+------------------------------------------------------------------+
//| THE BRAIN: ADAPTIVE CAPITAL CALCULATION                          |
//| (Memenuhi CO-6: Forecasting Strategy Performance)                |
//+------------------------------------------------------------------+
double CalculateAdaptiveRisk() {
    // 1. Tentukan rentang waktu evaluasi
    datetime endTime = TimeCurrent();
    datetime startTime = endTime - (ReviewPeriod * 24 * 3600); // Mundur X hari
    
    // 2. Minta Data History Deal
    HistorySelect(startTime, endTime);
    int deals = HistoryDealsTotal();
    
    double totalProfit = 0;
    
    // 3. Hitung Total Profit/Loss periode tersebut
    for(int i=0; i<deals; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == Magic) {
            totalProfit += HistoryDealGetDouble(ticket, DEAL_PROFIT);
            totalProfit += HistoryDealGetDouble(ticket, DEAL_SWAP);
            totalProfit += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
        }
    }
    
    // 4. Hitung Multiplier (Pengali)
    // Logika: 
    // Jika Profit > 0, kita lebih berani (Naikkan Risk).
    // Jika Profit < 0, kita defensif (Turunkan Risk).
    
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(balance == 0) return BaseRiskPercent;
    
    // Faktor Performa = (Profit / Balance) * 10
    // Contoh: Profit 5% ($500 dari $10000) -> Faktor +0.5
    // Contoh: Loss 5% (-$500 dari $10000) -> Faktor -0.5
    double performanceFactor = (totalProfit / balance) * 5.0; 
    
    double multiplier = 1.0 + performanceFactor;
    
    // 5. Kunci Batas Atas dan Bawah (Constraints)
    if(multiplier > MaxRiskBoost) multiplier = MaxRiskBoost; // Jangan terlalu serakah
    if(multiplier < MinRiskCut)   multiplier = MinRiskCut;   // Jangan terlalu takut (tapi aman)
    
    double finalRisk = BaseRiskPercent * multiplier;
    
    // Debug Print (Bisa dilihat di Journal saat backtest)
    // Print("Last ", ReviewPeriod, " Days Profit: $", DoubleToString(totalProfit, 2), 
    //       " | Multiplier: x", DoubleToString(multiplier, 2), 
    //       " | Risk: ", DoubleToString(finalRisk, 2), "%");
          
    return finalRisk;
}

//+------------------------------------------------------------------+
//| Execution & Lot Size                                             |
//+------------------------------------------------------------------+
double CalcLots(double slDist, double riskPct) {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskMoney = equity * (riskPct / 100.0);
    
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    if(tickVal == 0) tickVal = 1.0;
    
    double lot = riskMoney / ((slDist/_Point) * tickVal);
    
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;
    
    // Margin Safety Check
    double marginReq = 0;
    if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginReq)) {
        if(marginReq > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
            lot = AccountInfoDouble(ACCOUNT_FREEMARGIN) / marginReq * lot * 0.95;
            lot = MathFloor(lot / step) * step;
        }
    }
    
    double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    if(lot < min) lot = min; // Minimal lot
    
    return lot;
}

void ExecuteBuy(double entryLevel, double risk) {
    double entry = NormalizeDouble(entryLevel + OrderDistPoints * _Point, _Digits);
    double sl    = NormalizeDouble(entry - SlPoints * _Point, _Digits);
    double tp    = NormalizeDouble(entry + TpPoints * _Point, _Digits);
    
    double lot = CalcLots(MathAbs(entry-sl), risk);
    if(lot > 0) trade.BuyStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, TimeCurrent()+ExpirationHours*3600);
}

void ExecuteSell(double entryLevel, double risk) {
    double entry = NormalizeDouble(entryLevel - OrderDistPoints * _Point, _Digits);
    double sl    = NormalizeDouble(entry + SlPoints * _Point, _Digits);
    double tp    = NormalizeDouble(entry - TpPoints * _Point, _Digits);
    
    double lot = CalcLots(MathAbs(entry-sl), risk);
    if(lot > 0) trade.SellStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, TimeCurrent()+ExpirationHours*3600);
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double FindHigh() {
    for(int i=0; i<100; i++) if(i>BarsN && iHighest(_Symbol,Timeframe,MODE_HIGH,BarsN*2+1,i-BarsN)==i) return iHigh(_Symbol,Timeframe,i);
    return 0;
}
double FindLow() {
    for(int i=0; i<100; i++) if(i>BarsN && iLowest(_Symbol,Timeframe,MODE_LOW,BarsN*2+1,i-BarsN)==i) return iLow(_Symbol,Timeframe,i);
    return 0;
}
void DeletePendingOrders() {
    for(int i=OrdersTotal()-1; i>=0; i--) if(OrderGetInteger(ORDER_MAGIC)==Magic) trade.OrderDelete(OrderGetTicket(i));
}
void ManageTrailing() {
    double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(PositionGetTicket(i)>0 && PositionGetInteger(POSITION_MAGIC)==Magic) {
            double sl=PositionGetDouble(POSITION_SL), cur=PositionGetDouble(POSITION_PRICE_CURRENT), open=PositionGetDouble(POSITION_PRICE_OPEN);
            if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) {
                if(cur > open + TslTriggerPoints*pt) {
                     double nsl = cur - TslPoints*pt;
                     if(nsl > sl) trade.PositionModify(PositionGetTicket(i), nsl, PositionGetDouble(POSITION_TP));
                }
            } else {
                if(cur < open - TslTriggerPoints*pt) {
                     double nsl = cur + TslPoints*pt;
                     if(nsl < sl || sl==0) trade.PositionModify(PositionGetTicket(i), nsl, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}