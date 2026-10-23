import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'engine.dart';
import 'main.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int i = 0;
  @override
  Widget build(BuildContext c) => Scaffold(
        body: IndexedStack(index: i, children: const [Home(), ChartsPage(), DemoPage(), LearnPage()]),
        bottomNavigationBar: NavigationBar(selectedIndex: i, onDestinationSelected: (v) => setState(() => i = v), destinations: const [
          NavigationDestination(icon: Icon(Icons.radar), label: 'Signals'),
          NavigationDestination(icon: Icon(Icons.candlestick_chart), label: 'Charts'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet), label: 'Demo'),
          NavigationDestination(icon: Icon(Icons.school), label: 'Seekho'),
        ]),
      );
}

// ---------- ALL LIVE CHARTS ----------
class ChartsPage extends StatefulWidget {
  const ChartsPage({super.key});
  @override
  State<ChartsPage> createState() => _ChartsState();
}

class _ChartsState extends State<ChartsPage> {
  String tf = '5m';
  Map<String, Result> rs = {};
  WebSocketChannel? ch;
  StreamSubscription? sub;

  @override
  void initState() { super.initState(); load(); }
  @override
  void dispose() { sub?.cancel(); ch?.sink.close(); super.dispose(); }

  Future<void> load() async {
    sub?.cancel(); ch?.sink.close();
    setState(() => rs = {});
    final cur = tf;
    await Future.wait([
      for (final p in pairs)
        fetch(p, cur).then<void>((cs) { if (mounted && cur == tf) setState(() => rs[p] = analyze(p, cur, cs)); }).catchError((_) {}),
    ]);
    if (!mounted || cur != tf) return;
    ch = WebSocketChannel.connect(Uri.parse('wss://data-stream.binance.vision/stream?streams=${pairs.map((p) => '${p.toLowerCase()}@kline_$cur').join('/')}'));
    sub = ch!.stream.listen((m) {
      final d = jsonDecode(m as String)['data'];
      final k = d['k'];
      final p = d['s'] as String;
      final r = rs[p];
      if (r == null || !mounted || cur != tf) return;
      final cd = Candle(k['t'] as int, double.parse(k['o']), double.parse(k['h']), double.parse(k['l']), double.parse(k['c']));
      final cs = List<Candle>.from(r.candles);
      if (cs.last.t == cd.t) { cs[cs.length - 1] = cd; } else { cs.add(cd); cs.removeAt(0); }
      setState(() => rs[p] = analyze(p, cur, cs));
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(
          title: const Text('Live Charts (sab coins)'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (final t in tfs)
                Padding(padding: const EdgeInsets.all(4), child: ChoiceChip(label: Text(t), selected: tf == t, onSelected: (_) { setState(() => tf = t); load(); })),
            ]),
          ),
        ),
        body: rs.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : GridView.count(crossAxisCount: 2, childAspectRatio: 0.9, padding: const EdgeInsets.all(8), children: [
                for (final r in rs.values)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(r.pair.replaceAll('USDT', ''), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        Text('${r.price}', style: const TextStyle(fontSize: 12)),
                        Text(r.ok ? '✅ ${r.signal}' : '⏳ WAIT', style: TextStyle(fontSize: 12, color: r.ok ? (r.dir > 0 ? Colors.greenAccent : Colors.redAccent) : Colors.grey)),
                        const SizedBox(height: 4),
                        Expanded(child: SizedBox(width: double.infinity, child: CustomPaint(painter: ChartPainter(r.candles)))),
                      ]),
                    ),
                  ),
              ]),
      );
}

// ---------- DEMO (PAPER) TRADING ----------
class Pos {
  final String pair, src;
  final int dir;
  final double entry, sl, tp, size;
  Pos(this.pair, this.dir, this.entry, this.sl, this.tp, this.size, this.src);
}

class Done {
  final Pos p;
  final double pnl;
  final String why;
  Done(this.p, this.pnl, this.why);
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});
  @override
  State<DemoPage> createState() => _DemoState();
}

class _DemoState extends State<DemoPage> {
  double bal = 1000, size = 100, slp = 1, tpp = 2;
  final px = <String, double>{};
  final open = <Pos>[];
  final done = <Done>[];
  bool auto = false;
  String pair = pairs[0];
  WebSocketChannel? ch;
  StreamSubscription? sub;
  Timer? tm;

  @override
  void initState() {
    super.initState();
    ch = WebSocketChannel.connect(Uri.parse('wss://data-stream.binance.vision/stream?streams=${pairs.map((p) => '${p.toLowerCase()}@miniTicker').join('/')}'));
    sub = ch!.stream.listen((m) {
      final d = jsonDecode(m as String)['data'];
      px[d['s'] as String] = double.parse(d['c']);
      for (final p in List<Pos>.from(open)) {
        final x = px[p.pair];
        if (x == null) continue;
        final sl = p.dir > 0 ? x <= p.sl : x >= p.sl;
        final tp = p.dir > 0 ? x >= p.tp : x <= p.tp;
        if (sl || tp) close(p, tp ? 'Target hit' : 'Stop-loss hit');
      }
      if (mounted) setState(() {});
    }, onError: (_) {});
    tm = Timer.periodic(const Duration(seconds: 20), (_) { if (auto) takeBest(true); });
  }

  @override
  void dispose() { tm?.cancel(); sub?.cancel(); ch?.sink.close(); super.dispose(); }

  double upnl(Pos p) => p.dir * ((px[p.pair] ?? p.entry) - p.entry) / p.entry * p.size;

  void close(Pos p, String why) {
    final pnl = upnl(p) - p.size * 0.002; // 0.1% fee har side
    bal += pnl;
    open.remove(p);
    done.insert(0, Done(p, pnl, why));
  }

  void openTrade(String pr, int dir, double sl, double tp, double sz, String src) {
    final x = px[pr];
    if (x == null || open.length >= 3) return;
    sz = min(sz, bal);
    if (sz <= 1) return;
    open.add(Pos(pr, dir, x, sl, tp, sz, src));
  }

  void takeBest(bool silent) {
    final good = latest.where((r) => r.ok && !open.any((p) => p.pair == r.pair)).take(1);
    for (final r in good) {
      openTrade(r.pair, r.dir, r.sl, r.tp, bal * 0.01 * r.price / (r.price - r.sl).abs(), 'Signal ${r.tf}');
    }
    if (good.isEmpty && !silent) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Abhi koi pakka signal nahi. Wait karein.')));
    }
    if (mounted) setState(() {});
  }

  void manual(int dir) {
    final x = px[pair];
    if (x == null) return;
    openTrade(pair, dir, x * (1 - dir * slp / 100), x * (1 + dir * tpp / 100), size, 'Manual');
    setState(() {});
  }

  Widget num(String l, double v, void Function(double) f) => Expanded(
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: TextField(decoration: InputDecoration(labelText: l, isDense: true), keyboardType: TextInputType.number, controller: TextEditingController(text: v.toString()), onChanged: (s) => f(double.tryParse(s) ?? v)),
        ),
      );

  @override
  Widget build(BuildContext c) {
    final up = open.fold<double>(0, (a, p) => a + upnl(p));
    final wins = done.where((d) => d.pnl > 0).length;
    final tot = done.fold<double>(0, (a, d) => a + d.pnl);
    Color pc(double v) => v >= 0 ? Colors.greenAccent : Colors.redAccent;
    return Scaffold(
      appBar: AppBar(title: const Text('Demo Trading (nakli paisa)'), actions: [
        IconButton(onPressed: () => setState(() { bal = 1000; open.clear(); done.clear(); }), icon: const Icon(Icons.restart_alt)),
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Balance: ${bal.toStringAsFixed(2)} USDT', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text('Equity: ${(bal + up).toStringAsFixed(2)}  |  Open PnL: ${up.toStringAsFixed(2)}', style: TextStyle(color: pc(up))),
              Text('Trades: ${done.length}  |  Win-rate: ${done.isEmpty ? '-' : '${(wins / done.length * 100).toStringAsFixed(0)}%'}  |  Total PnL: ${tot.toStringAsFixed(2)}', style: TextStyle(color: pc(tot))),
              const Text('Fees (0.1% har side) shamil hain. Max 3 open trades.', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
          ),
        ),
        SwitchListTile(
          title: const Text('Auto Demo Bot'),
          subtitle: const Text('Jab app "TRADE LO" signal de, khud demo trade khole (1% risk)'),
          value: auto,
          onChanged: (v) => setState(() => auto = v),
        ),
        FilledButton(onPressed: () => takeBest(false), child: const Text('Best signal se demo trade lo')),
        const Divider(),
        const Text('Manual trade', style: TextStyle(fontWeight: FontWeight.bold)),
        DropdownButton<String>(value: pair, isExpanded: true, items: [for (final p in pairs) DropdownMenuItem(value: p, child: Text('$p   ${px[p] ?? '...'}'))], onChanged: (v) => setState(() => pair = v!)),
        Row(children: [num('Amount USDT', size, (v) => size = v), num('SL %', slp, (v) => slp = v), num('Target %', tpp, (v) => tpp = v)]),
        Row(children: [
          Expanded(child: FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.green), onPressed: () => manual(1), child: const Text('BUY (Long)'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => manual(-1), child: const Text('SELL (Short)'))),
        ]),
        const Divider(),
        Text('Open trades (${open.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
        for (final p in open)
          ListTile(
            dense: true,
            title: Text('${p.dir > 0 ? 'BUY' : 'SELL'} ${p.pair} • ${p.size.toStringAsFixed(1)} USDT • ${p.src}'),
            subtitle: Text('Entry ${p.entry}  SL ${p.sl.toStringAsFixed(4)}  TP ${p.tp.toStringAsFixed(4)}'),
            trailing: TextButton(onPressed: () => setState(() => close(p, 'Manual close')), child: Text('${upnl(p).toStringAsFixed(2)}\nClose', textAlign: TextAlign.center, style: TextStyle(color: pc(upnl(p))))),
          ),
        const Divider(),
        const Text('History', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final d in done.take(30))
          ListTile(dense: true, title: Text('${d.p.dir > 0 ? 'BUY' : 'SELL'} ${d.p.pair} • ${d.why}'), subtitle: Text(d.p.src), trailing: Text(d.pnl.toStringAsFixed(2), style: TextStyle(color: pc(d.pnl), fontWeight: FontWeight.bold))),
        const Text('Demo data app band hone par reset ho jata hai.', style: TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
    );
  }
}

// ---------- LEARN ----------
const lessons = {
  'Crypto aur USDT kya hai?': 'Crypto digital paisa hai (BTC, ETH). USDT ek coin hai jiski value lagbhag 1 dollar rehti hai. Trading me hum coins ko USDT ke against kharidte/bechte hain, jaise BTCUSDT.',
  'Spot vs Futures': 'Spot me aap asli coin kharidte hain, loss sirf aapke paise tak. Futures me leverage hota hai, loss tezi se aur liquidation ho sakti hai. Noob ke liye sirf Spot ya Demo.',
  'BUY/Long aur SELL/Short': 'BUY (Long): price badhne par profit. SELL (Short): price girne par profit, ye futures me hota hai. Spot me SELL ka matlab apna coin bechna hai.',
  'Stop-loss (SL)': 'Pehle se tay kiya hua exit price jahan loss limit me hi trade band ho jaye. SL ke bina trade kabhi mat lo.',
  'Target (Take-profit)': 'Wo price jahan profit lekar nikalna hai. Hamara plan risk:reward 1:2 rakhta hai, yani 1 rupya risk par 2 rupaye ka target.',
  'Candle kaise padhein?': 'Har candle ek time (1m, 5m...) ki kahani hai. Green = price badha, Red = price gira. Patli line (wick) high/low batati hai.',
  'EMA': 'Moving average. EMA9 (blue) EMA21 (orange) ke upar ho to trend upar, neeche ho to trend neeche.',
  'RSI': '0-100 ka meter. 30 se neeche = bohot gira (bounce ho sakta), 70 se upar = bohot chadha (girne ka chance).',
  'MACD, Bollinger, Stoch, CCI': 'Ye momentum aur overbought/oversold batate hain. Akele par bharosa nahi, isliye app 8 strategies ka confluence (agreement) dekhta hai.',
  'ADX aur Supertrend': 'ADX batata hai trend kitna majboot hai (25 se upar = strong). Supertrend trend ki direction aur reversal dikhata hai.',
  'Backtest kya hai?': 'Purane data par strategy chala kar dekhna ki kitni baar sahi nikli. Ye guarantee nahi, sirf andaza hai.',
  '1% risk rule': 'Ek trade me capital ka max 1% khone ka risk lo. 100 USDT me 1 USDT. Isse 20-30 lagatar loss ke baad bhi account bacha rehta hai.',
  'Kab trade NAHI karni?': 'Jab app "MAT LO" dikhaye, jab bade news (Fed, CPI) aa rahe hon, jab aap emotional ya loss recover karna chahte ho, ya jab SL na laga ho.',
  'Pehle kya karein?': '1) Demo me kam az kam 2-4 hafte chalayein. 2) Win-rate aur total PnL dekhein. 3) Phir bhi real me sirf itna lagayein jo khone ka darr na ho. Profit ki guarantee koi nahi deta.',
};

class LearnPage extends StatelessWidget {
  const LearnPage({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Seekho (Beginner Guide)')),
        body: ListView(children: [
          for (final e in lessons.entries) ExpansionTile(title: Text(e.key), children: [Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Text(e.value))]),
        ]),
      );
}
