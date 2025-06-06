#include <Trade\Trade.mqh>
CTrade trade;

input ENUM_TIMEFRAMES tf = PERIOD_M5;
input int utc_offset = 0;

#define COLOR_TOKYO     clrGold
#define COLOR_LONDON    clrLime
#define COLOR_PREMARKET clrMediumOrchid
#define COLOR_NYAM      clrIndianRed
#define COLOR_NYPM      clrDarkOrange

struct RangoSesion {
   int h_ini, m_ini, h_fin, m_fin;
   string nombre;
   color col;
};

struct DatosSesion {
   double high, low;
   datetime ini, fin;
   string nombre;
   color col;
};

RangoSesion sesiones[] = {
   {18, 45, 23, 59, "Tokyo",     COLOR_TOKYO},
   { 2,  0,  5,  0, "London",    COLOR_LONDON},
   { 7,  0,  9, 30, "PreMarket", COLOR_PREMARKET},
   { 9, 30, 12,  0, "NYAM",      COLOR_NYAM},
   {13,  0, 16,  0, "NYPM",      COLOR_NYPM}
};

string etiqueta_activa = "";

string EvaluarCalidadSweep(bool isHigh, const DatosSesion &nyam, const DatosSesion &ultima, MqlRates &rates[], int count, datetime sweepTime) {
   int atr_handle = iATR(_Symbol, tf, 14);
   double atr_buffer[];
   if(CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) <= 0) return "NULA";
   double atr = atr_buffer[0];
   MqlDateTime sweep_dt; TimeToStruct(sweepTime + utc_offset * 3600, sweep_dt);
   int toques = 0;
   int score = 0;
   double rango = ultima.high - ultima.low;
   if(rango <= 0) return "NULA";

   double penetracion = isHigh ? (nyam.high - ultima.high) : (ultima.low - nyam.low);
   if(penetracion / rango > 0.05) score++;

   double postSweepDist = isHigh ? MathAbs(SymbolInfoDouble(_Symbol, SYMBOL_BID) - nyam.high)
                                 : MathAbs(SymbolInfoDouble(_Symbol, SYMBOL_BID) - nyam.low);
   if(postSweepDist / rango > 0.1) score++;

   for(int i = 0; i < count; i++) {
      if(rates[i].time > sweepTime) {
         double body = MathAbs(rates[i].close - rates[i].open);
         double total = rates[i].high - rates[i].low;
         if(total > 0 && body / total > 0.5)
            score++;
         break;
      }
   }

   score++; // asumimos que fue el sweep final

   if(penetracion > atr * 0.3) score++; // ATR como filtro de fuerza

   for(int i = 0; i < count; i++) {
      if(isHigh && MathAbs(rates[i].high - ultima.high) < _Point * 10)
         toques++;
      else if(!isHigh && MathAbs(rates[i].low - ultima.low) < _Point * 10)
         toques++;
   }
   if(toques >= 3) score++; // Acumulación previa

   if(sweep_dt.hour == 9 && sweep_dt.min < 50) score++; // Sweep temprano en NYAM

   int max_score = 8;
   double porcentaje = (double)score / max_score * 100.0;
   PrintFormat("[CALIDAD SWEEP] Score: %d/%d (%.1f%%)", score, max_score, porcentaje);
   return DoubleToString(porcentaje, 1);
}

void DibujarSesion(const DatosSesion &ds) {
   MqlDateTime tm;
   TimeToStruct(ds.ini, tm);
   string base = ds.nombre + "_" + (string)tm.day + "_" + (string)tm.mon;

   string obj = "box_" + base, lbl = "lbl_" + base;
   ObjectDelete(0, obj);
   ObjectDelete(0, lbl);

   ObjectCreate(0, obj, OBJ_RECTANGLE, 0, ds.ini, ds.high, ds.fin, ds.low);
   ObjectSetInteger(0, obj, OBJPROP_COLOR, ds.col);
   ObjectSetInteger(0, obj, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, obj, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, obj, OBJPROP_FILL, false);
   ObjectSetInteger(0, obj, OBJPROP_BACK, true);

   ObjectCreate(0, lbl, OBJ_TEXT, 0, ds.ini, ds.high + (ds.high - ds.low) * 0.01);
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, ds.col);
   ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, lbl, OBJPROP_TEXT, ds.nombre);
}

bool CalcularRangoSesion(const RangoSesion &s, const MqlRates &rates[], int cnt, DatosSesion &dst) {
   dst.high = -DBL_MAX;
   dst.low  =  DBL_MAX;
   dst.ini = dst.fin = 0;
   dst.nombre = s.nombre;
   dst.col    = s.col;

   int desde = s.h_ini * 60 + s.m_ini;
   int hasta = s.h_fin * 60 + s.m_fin;
   bool cruza = desde > hasta;

   MqlDateTime hoy;
   TimeToStruct(TimeCurrent() + utc_offset * 3600, hoy);

   for(int i = 0; i < cnt; i++) {
      datetime t = rates[i].time;
      MqlDateTime dt;
      TimeToStruct(t + utc_offset * 3600, dt);
      if(dt.day != hoy.day || dt.mon != hoy.mon || dt.year != hoy.year) continue;

      int minutos = dt.hour * 60 + dt.min;
      bool dentro = cruza ? (minutos >= desde || minutos < hasta)
                          : (minutos >= desde && minutos < hasta);
      if(!dentro) continue;

      dst.high = MathMax(dst.high, rates[i].high);
      dst.low  = MathMin(dst.low,  rates[i].low);
      if(dst.ini == 0 || t < dst.ini) dst.ini = t;
      if(t > dst.fin) dst.fin = t;
   }

   return (dst.ini > 0 && dst.fin > 0 && dst.high > dst.low);
}

int OnInit() {
   Print("[EA] Sweep con fuerza y porcentaje mostrado.");
   return INIT_SUCCEEDED;
}

void OnTick() {
   static string sweepDominante = "";
   static double scoreDominante = -1;
   static datetime tiempoDominante = 0;
static datetime inicioUltimaNYAM = 0;
   string calidad = "";
   MqlRates rates[];
   if(CopyRates(_Symbol, tf, 0, 288, rates) <= 0) return;

   DatosSesion sesiones_previas[5];
   DatosSesion nyam = {0};
   int count = 0;

   MqlDateTime ahora;
   TimeToStruct(TimeCurrent() + utc_offset * 3600, ahora);

   datetime nyam_ini = 0;

   for(int i = 0; i < ArraySize(sesiones); i++) {
      DatosSesion ds;
      if(!CalcularRangoSesion(sesiones[i], rates, 288, ds)) continue;

      DibujarSesion(ds);

      if(sesiones[i].nombre == "NYAM") {
   nyam = ds;
   nyam_ini = ds.ini;
   datetime claveUTC = nyam_ini;
   if(claveUTC != inicioUltimaNYAM) {
      sweepDominante = "";
      scoreDominante = -1;
      inicioUltimaNYAM = claveUTC;
   }
      } else {
         sesiones_previas[count++] = ds;
      }
   }

   if(nyam.ini == 0 || nyam_ini == 0) return;

   int minutos = ahora.hour * 60 + ahora.min;
   if(minutos < 570 || minutos >= 720) return;

   DatosSesion ultima = {0};
   for(int i = 0; i < count; i++) {
      if(sesiones_previas[i].fin < nyam_ini)
         if(ultima.fin == 0 || sesiones_previas[i].fin > ultima.fin)
            ultima = sesiones_previas[i];
   }

   if(ultima.ini == 0) return;

   double offsetY = (nyam.high - nyam.low) * 0.01;
   datetime centro_x = (nyam.ini + nyam.fin) / 2;

   bool sweepHigh = nyam.high > ultima.high + _Point;
   bool sweepLow  = nyam.low  < ultima.low  - _Point;

   datetime sweepHighTime = 0, sweepLowTime = 0;

   for(int i = 0; i < ArraySize(rates); i++) {
      datetime t = rates[i].time;
      if(t >= nyam.ini && t <= nyam.fin) {
         if(sweepHigh && rates[i].high > ultima.high)
            sweepHighTime = t;
         if(sweepLow && rates[i].low < ultima.low)
            sweepLowTime = t;
      }
   }

   string texto = "";
   double y = 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double rango = ultima.high - ultima.low;
   if(rango <= 0) return;

   
      double fuerza = (bid - nyam.low) / rango;
      bool fuerte = fuerza > 0.2;
      string tipo = fuerte ? "Reversion" : "Continuacion";
      calidad = EvaluarCalidadSweep(false, nyam, ultima, rates, ArraySize(rates), sweepLowTime);
      // Detectar y evaluar ambos sweeps con prioridad lógica
   double calidadHighVal = -1, calidadLowVal = -1;
   string calidadHighTxt = "", calidadLowTxt = "";
   double fuerzaHigh = 0.0, fuerzaLow = 0.0;
   string tipoHigh = "", tipoLow = "";
   double penetracionHigh = 0.0, penetracionLow = 0.0;
   datetime mejorTiempo = 0;
double reaccionHighReal = 0.0, reaccionLowReal = 0.0;

   if(sweepHigh) {
   PrintFormat("[SWEEP HIGH DETECTADO] Evaluando sweep high... Sesión: %s | Hora: %s", ultima.nombre, TimeToString(sweepHighTime, TIME_DATE | TIME_MINUTES));
      fuerzaHigh = (nyam.high - bid) / rango;
      tipoHigh = fuerzaHigh > 0.2 ? "R" : "C";
      calidadHighTxt = EvaluarCalidadSweep(true, nyam, ultima, rates, ArraySize(rates), sweepHighTime);
      calidadHighVal = StringToDouble(calidadHighTxt);
      penetracionHigh = nyam.high - ultima.high;
double lowPostSweep = nyam.low;
for(int i = 0; i < ArraySize(rates); i++) {
   if(rates[i].time > sweepHighTime)
      lowPostSweep = MathMin(lowPostSweep, rates[i].low);
}
reaccionHighReal = nyam.high - lowPostSweep;
   }

   if(sweepLow) {
   PrintFormat("[SWEEP LOW DETECTADO] Evaluando sweep low... Sesión: %s | Hora: %s", ultima.nombre, TimeToString(sweepLowTime, TIME_DATE | TIME_MINUTES));
      fuerzaLow = (bid - nyam.low) / rango;
      tipoLow = fuerzaLow > 0.2 ? "R" : "C";
      calidadLowTxt = EvaluarCalidadSweep(false, nyam, ultima, rates, ArraySize(rates), sweepLowTime);
      calidadLowVal = StringToDouble(calidadLowTxt);
      penetracionLow = ultima.low - nyam.low;
double highPostSweep = nyam.high;
for(int i = 0; i < ArraySize(rates); i++) {
   if(rates[i].time > sweepLowTime)
      highPostSweep = MathMax(highPostSweep, rates[i].high);
}
reaccionLowReal = highPostSweep - nyam.low;
   }

   double totalScoreHigh = calidadHighVal + (reaccionHighReal / rango) * 100.0;
bool mostrarHigh = totalScoreHigh >= 60 && (!sweepLow || totalScoreHigh >= (calidadLowVal + (reaccionLowReal / rango) * 100.0));
   double totalScoreLow = calidadLowVal + (reaccionLowReal / rango) * 100.0;
bool mostrarLow  = totalScoreLow >= 60 && (!sweepHigh || totalScoreLow > totalScoreHigh);

   if(mostrarHigh && (sweepDominante == "" || totalScoreHigh > scoreDominante)) {
   PrintFormat("[REACCION HIGH] %.1f puntos (%.1f%% del rango)", reaccionHighReal, (reaccionHighReal / rango) * 100.0);
   PrintFormat("[SELECCION FINAL] Mostrando HIGH | Sesión: %s | Calidad: %.1f%% | Tipo: %s", ultima.nombre, calidadHighVal, tipoHigh);
   PrintFormat("[SWEEP MOSTRADO] HIGH | Tipo: %s | Calidad: %.1f%% | Hora: %s", tipoHigh, calidadHighVal, TimeToString(sweepHighTime, TIME_DATE | TIME_MINUTES));
      texto = StringFormat("SH %s %s (%.1f%%)", ultima.nombre, tipoHigh, totalScoreHigh);
      y = nyam.high + offsetY * 3;
      calidad = DoubleToString(totalScoreHigh, 1);
      mejorTiempo = sweepHighTime;
   sweepDominante = "HIGH";
   scoreDominante = totalScoreHigh;
   tiempoDominante = sweepHighTime;
   }
   else if(mostrarLow && (sweepDominante == "" || totalScoreLow > scoreDominante)) {
   PrintFormat("[REACCION LOW] %.1f puntos (%.1f%% del rango)", reaccionLowReal, (reaccionLowReal / rango) * 100.0);
   PrintFormat("[SELECCION FINAL] Mostrando LOW | Sesión: %s | Calidad: %.1f%% | Tipo: %s", ultima.nombre, calidadLowVal, tipoLow);
   PrintFormat("[SWEEP MOSTRADO] LOW | Tipo: %s | Calidad: %.1f%% | Hora: %s", tipoLow, calidadLowVal, TimeToString(sweepLowTime, TIME_DATE | TIME_MINUTES));
      texto = StringFormat("SL %s %s (%.1f%%)", ultima.nombre, tipoLow, totalScoreLow);
      y = nyam.low - offsetY * 3;
      calidad = DoubleToString(totalScoreLow, 1);
      mejorTiempo = sweepLowTime;
   sweepDominante = "LOW";
   scoreDominante = totalScoreLow;
   tiempoDominante = sweepLowTime;
   }
   
if(texto != "") {
      string nombre = "sweep_etiqueta";
      if(ObjectFind(0, nombre) >= 0) {
         string texto_actual = ObjectGetString(0, nombre, OBJPROP_TEXT);
         if(texto_actual != texto)
            ObjectDelete(0, nombre);
      }

      if(ObjectFind(0, nombre) < 0)
         ObjectCreate(0, nombre, OBJ_TEXT, 0, centro_x, y);

      ObjectSetInteger(0, nombre, OBJPROP_TIME, centro_x);
      ObjectSetDouble(0, nombre, OBJPROP_PRICE, y);
      double val = StringToDouble(calidad);
      color colTexto = val >= 75.0 ? clrRed : val >= 50.0 ? clrYellow : clrDodgerBlue;
      ObjectSetInteger(0, nombre, OBJPROP_COLOR, colTexto);
      ObjectSetInteger(0, nombre, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, nombre, OBJPROP_TEXT, texto);

      etiqueta_activa = nombre;
   }
}

void OnDeinit(const int reason) {
   if(etiqueta_activa != "")
      ObjectDelete(0, etiqueta_activa);
}
