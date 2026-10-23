import 'dart:math';

class Candle {
  final int t;
  final double o, h, l, c;
  Candle(this.t, this.o, this.h, this.l, this.c);
}

class BT {
  final int trades;
  final double wr, avg;
  BT(this.trades, this.wr, this.avg);
}

class Result {
  final String pair, tf;
  final double score;
  final Map<String, int> votes;
  final Map<String, BT> bt;
  final List<Candle> candles;
  final double atr;
  Result(this.pair, this.tf, this.score, this.votes, this.bt, this.candles, this.atr);
  String get signal => score >= 40 ? 'BUY' : (score <= -40 ? 'SELL' : 'WAIT');
  double get price => candles.last.c;
  int get dir => score > 0 ? 1 : -1;
  int get agree => votes.values.where((v) => v != 0 && v == dir).length;
  double get sl => price - dir * 1.5 * atr;
  double get tp => price + dir * 3 * atr;
  List<String> get why {
    final w = <String>[];
    if (signal == 'WAIT') w.add('Score 40% se kam, strategies agree nahi');
    if (agree < 3) w.add('Kam az kam 3 strategies agree honi chahiye (abhi $agree)');
    if (conf < 52) w.add('Backtest win-rate ${conf.toStringAsFixed(0)}% (52% se kam)');
    if (atr / price < 0.0004) w.add('Market bohot slow hai (volatility kam)');
    return w;
  }
  bool get ok => why.isEmpty;
  double get conf {
    final a = votes.entries.where((e) => e.value != 0 && (e.value > 0) == (score > 0)).toList();
    if (a.isEmpty) return 0;
    return a.map((e) => bt[e.key]!.wr).reduce((x, y) => x + y) / a.length;
  }
}

List<double> ema(List<double> v, int p) {
  final k = 2 / (p + 1);
  final r = <double>[];
  for (var i = 0; i < v.length; i++) {
    r.add(i == 0 ? v[0] : v[i] * k + r[i - 1] * (1 - k));
  }
  return r;
}

List<double> rsiA(List<double> c, [int p = 14]) {
  final r = List<double>.filled(c.length, 50);
  double g = 0, l = 0;
  for (var i = 1; i < c.length; i++) {
    final d = c[i] - c[i - 1];
    final u = d > 0 ? d : 0.0, w = d < 0 ? -d : 0.0;
    if (i <= p) {
      g += u; l += w;
      if (i == p) { g /= p; l /= p; r[i] = l == 0 ? 100 : 100 - 100 / (1 + g / l); }
    } else {
      g = (g * (p - 1) + u) / p; l = (l * (p - 1) + w) / p;
      r[i] = l == 0 ? 100 : 100 - 100 / (1 + g / l);
    }
  }
  return r;
}

List<List<double>> bbA(List<double> c) {
  final u = List<double>.filled(c.length, double.infinity), l = List<double>.filled(c.length, -double.infinity);
  for (var i = 19; i < c.length; i++) {
    final w = c.sublist(i - 19, i + 1);
    final m = w.reduce((a, b) => a + b) / 20;
    final s = sqrt(w.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / 20);
    u[i] = m + 2 * s; l[i] = m - 2 * s;
  }
  return [u, l];
}

List<double> stochA(List<Candle> cs) {
  final r = List<double>.filled(cs.length, 50);
  for (var i = 13; i < cs.length; i++) {
    double hh = -1e18, ll = 1e18;
    for (var j = i - 13; j <= i; j++) { hh = max(hh, cs[j].h); ll = min(ll, cs[j].l); }
    r[i] = hh == ll ? 50 : (cs[i].c - ll) / (hh - ll) * 100;
  }
  return r;
}

List<double> cciA(List<Candle> cs) {
  final tp = cs.map((e) => (e.h + e.l + e.c) / 3).toList();
  final r = List<double>.filled(cs.length, 0);
  for (var i = 19; i < cs.length; i++) {
    final w = tp.sublist(i - 19, i + 1);
    final m = w.reduce((a, b) => a + b) / 20;
    final md = w.map((x) => (x - m).abs()).reduce((a, b) => a + b) / 20;
    r[i] = md == 0 ? 0 : (tp[i] - m) / (0.015 * md);
  }
  return r;
}

List<List<double>> adxA(List<Candle> cs) {
  final n = cs.length;
  final adx = List<double>.filled(n, 0), pd = List<double>.filled(n, 0), md = List<double>.filled(n, 0);
  double tr = 0, p = 0, m = 0;
  for (var i = 1; i < n; i++) {
    final a = cs[i], b = cs[i - 1];
    final t = max(a.h - a.l, max((a.h - b.c).abs(), (a.l - b.c).abs()));
    final up = a.h - b.h, dn = b.l - a.l;
    tr = tr - tr / 14 + t;
    p = p - p / 14 + ((up > dn && up > 0) ? up : 0.0);
    m = m - m / 14 + ((dn > up && dn > 0) ? dn : 0.0);
    if (tr == 0) continue;
    pd[i] = 100 * p / tr; md[i] = 100 * m / tr;
    final s = pd[i] + md[i];
    final dx = s == 0 ? 0.0 : 100 * (pd[i] - md[i]).abs() / s;
    adx[i] = adx[i - 1] + (dx - adx[i - 1]) / 14;
  }
  return [adx, pd, md];
}

List<int> superT(List<Candle> cs) {
  final n = cs.length;
  final d = List<int>.filled(n, 1);
  double atr = 0, fu = 0, fl = 0;
  for (var i = 1; i < n; i++) {
    final a = cs[i], b = cs[i - 1];
    final t = max(a.h - a.l, max((a.h - b.c).abs(), (a.l - b.c).abs()));
    atr = i <= 10 ? atr + t / 10 : (atr * 9 + t) / 10;
    final mid = (a.h + a.l) / 2;
    final bu = mid + 3 * atr, bl = mid - 3 * atr;
    final pfu = fu, pfl = fl;
    fu = (i == 1 || bu < pfu || b.c > pfu) ? bu : pfu;
    fl = (i == 1 || bl > pfl || b.c < pfl) ? bl : pfl;
    d[i] = d[i - 1] == 1 ? (a.c < fl ? -1 : 1) : (a.c > fu ? 1 : -1);
  }
  return d;
}

class Ind {
  late List<Candle> cs;
  late List<double> c, e9, e21, e50, rs, h, up, lo, k, cci, adx, pd, md;
  late List<int> st;
  Ind(List<Candle> x) {
    cs = x;
    c = x.map((e) => e.c).toList();
    e9 = ema(c, 9); e21 = ema(c, 21); e50 = ema(c, 50); rs = rsiA(c);
    final e12 = ema(c, 12), e26 = ema(c, 26);
    final m = List.generate(c.length, (i) => e12[i] - e26[i]);
    final s = ema(m, 9);
    h = List.generate(c.length, (i) => m[i] - s[i]);
    final b = bbA(c); up = b[0]; lo = b[1];
    k = stochA(x); cci = cciA(x);
    final a = adxA(x); adx = a[0]; pd = a[1]; md = a[2];
    st = superT(x);
  }
}

Map<String, int> sigAt(Ind x, int i) {
  final c = x.c, cs = x.cs;
  double hh = -1e18, ll = 1e18;
  for (var j = i - 20; j < i; j++) { hh = max(hh, cs[j].h); ll = min(ll, cs[j].l); }
  final a = cs[i - 1], b = cs[i];
  final bull = a.c < a.o && b.c > b.o && b.c >= a.o && b.o <= a.c;
  final bear = a.c > a.o && b.c < b.o && b.o >= a.c && b.c <= a.o;
  return {
    'EMA Cross 9/21': x.e9[i] > x.e21[i] ? 1 : -1,
    'RSI + Bollinger': (x.rs[i] < 35 && c[i] < x.lo[i]) ? 1 : ((x.rs[i] > 65 && c[i] > x.up[i]) ? -1 : 0),
    'MACD + Trend': (x.h[i] > 0 && x.h[i] > x.h[i - 1] && c[i] > x.e50[i]) ? 1 : ((x.h[i] < 0 && x.h[i] < x.h[i - 1] && c[i] < x.e50[i]) ? -1 : 0),
    'Supertrend': x.st[i],
    'ADX Trend': x.adx[i] > 25 ? (x.pd[i] > x.md[i] ? 1 : -1) : 0,
    'Stoch + CCI': (x.k[i] < 20 && x.cci[i] < -100) ? 1 : ((x.k[i] > 80 && x.cci[i] > 100) ? -1 : 0),
    'Breakout 20': c[i] > hh ? 1 : (c[i] < ll ? -1 : 0),
    'Engulfing': bull ? 1 : (bear ? -1 : 0),
  };
}

Map<String, BT> backtest(Ind x) {
  final n = x.c.length;
  final tr = <String, int>{}, w = <String, int>{}, s = <String, double>{};
  for (var i = 60; i < n - 1; i++) {
    sigAt(x, i).forEach((k, v) {
      if (v == 0) return;
      final r = (x.c[i + 1] - x.c[i]) / x.c[i] * v;
      tr[k] = (tr[k] ?? 0) + 1;
      if (r > 0) w[k] = (w[k] ?? 0) + 1;
      s[k] = (s[k] ?? 0) + r;
    });
  }
  final out = <String, BT>{};
  for (final k in sigAt(x, n - 1).keys) {
    final t = tr[k] ?? 0;
    out[k] = BT(t, t == 0 ? 0 : (w[k] ?? 0) / t * 100, t == 0 ? 0 : (s[k] ?? 0) / t * 100);
  }
  return out;
}

Result analyze(String pair, String tf, List<Candle> cs) {
  final x = Ind(cs);
  final bt = backtest(x);
  final v = sigAt(x, cs.length - 1);
  final act = v.keys.where((k) => bt[k]!.trades >= 8 && bt[k]!.wr >= 52).toList();
  final use = act.isEmpty ? v.keys.toList() : act;
  var s = 0;
  for (final k in use) { s += v[k]!; }
  final sc = (100 * s / min(use.length, 4)).clamp(-100.0, 100.0).toDouble();
  return Result(pair, tf, sc, v, bt, cs, atrLast(cs));
}

double atrLast(List<Candle> cs) {
  double a = 0;
  final n = cs.length;
  for (var i = n - 14; i < n; i++) {
    final x = cs[i], b = cs[i - 1];
    a += max(x.h - x.l, max((x.h - b.c).abs(), (x.l - b.c).abs()));
  }
  return a / 14;
}
