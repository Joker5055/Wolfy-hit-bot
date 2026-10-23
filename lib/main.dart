import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'engine.dart';
import 'pages.dart';

void main() => runApp(const WolfApp());

const pairs = ['BTCUSDT', 'ETHUSDT', 'BNBUSDT', 'SOLUSDT', 'XRPUSDT', 'DOGEUSDT', 'ADAUSDT'];
const tfs = ['1m', '5m', '15m'];
List<Result> latest = [];

Future<List<Candle>> fetch(String s, String tf) async {
  for (final host in ['https://data-api.binance.vision', 'https://api.binance.com']) {
    try {
      final r = await http.get(Uri.parse('$host/api/v3/klines?symbol=$s&interval=$tf&limit=400')).timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        final d = jsonDecode(r.body) as List;
        return d.map((e) => Candle(e[0] as int, double.parse(e[1]), double.parse(e[2]), double.parse(e[3]), double.parse(e[4]))).toList();
      }
    } catch (_) {}
  }
  throw Exception('no data');
}

class WolfApp extends StatelessWidget {
  const WolfApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Wolfies Hit Bot',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(scaffoldBackgroundColor: const Color(0xFF0B0F14)),
        home: const Shell(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Result> res = [];
  bool loading = false;
  int sel = 0;
  String updated = '-';
  double cap = 100;
  Timer? t;
  WebSocketChannel? ch;
  StreamSubscription? sub;

  @override
  void initState() {
    super.initState();
    scan();
    t = Timer.periodic(const Duration(seconds: 60), (_) => scan());
  }

  @override
  void dispose() { t?.cancel(); sub?.cancel(); ch?.sink.close(); super.dispose(); }

  Future<void> scan() async {
    if (loading) return;
    setState(() => loading = true);
    final key = res.isEmpty ? null : '${res[sel].pair}${res[sel].tf}';
    final out = <Result>[];
    await Future.wait([
      for (final p in pairs)
        for (final tf in tfs)
          fetch(p, tf).then<void>((cs) { out.add(analyze(p, tf, cs)); }).catchError((_) {}),
    ]);
    out.sort((x, y) => y.score.abs().compareTo(x.score.abs()));
    latest = out;
    if (!mounted) return;
    final n = DateTime.now();
    setState(() {
      res = out;
      sel = key == null ? 0 : max(0, out.indexWhere((r) => '${r.pair}${r.tf}' == key));
      loading = false;
      updated = '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}:${n.second.toString().padLeft(2, '0')}';
    });
    live();
  }

  void live() {
    sub?.cancel();
    ch?.sink.close();
    if (res.isEmpty) return;
    final r = res[sel];
    final i = sel;
    ch = WebSocketChannel.connect(Uri.parse('wss://data-stream.binance.vision/ws/${r.pair.toLowerCase()}@kline_${r.tf}'));
    sub = ch!.stream.listen((m) {
      if (!mounted || i >= res.length || i != sel) return;
      final k = jsonDecode(m as String)['k'];
      final cd = Candle(k['t'] as int, double.parse(k['o']), double.parse(k['h']), double.parse(k['l']), double.parse(k['c']));
      final cs = List<Candle>.from(res[i].candles);
      if (cs.last.t == cd.t) { cs[cs.length - 1] = cd; } else { cs.add(cd); cs.removeAt(0); }
      setState(() => res[i] = analyze(r.pair, r.tf, cs));
    }, onError: (_) {});
  }

  Color col(String s) => s == 'BUY' ? Colors.greenAccent : (s == 'SELL' ? Colors.redAccent : Colors.grey);

  @override
  Widget build(BuildContext context) {
    final top = res.isEmpty ? null : res[sel];
    return Scaffold(
      appBar: AppBar(title: const Text('Wolfies Hit Bot'), actions: [IconButton(onPressed: scan, icon: const Icon(Icons.refresh))]),
      body: top == null
          ? Center(child: loading ? const CircularProgressIndicator() : const Text('Data nahi mila. Internet check karein.'))
          : ListView(padding: const EdgeInsets.all(12), children: [
              if (loading) const LinearProgressIndicator(),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(sel == 0 ? 'BEST OPPORTUNITY' : 'SELECTED', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      const Spacer(),
                      const Icon(Icons.circle, color: Colors.greenAccent, size: 8),
                      const Text(' LIVE', style: TextStyle(fontSize: 12, color: Colors.greenAccent)),
                    ]),
                    Text('${top.pair} • ${top.tf}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    Text('${top.signal} | Score ${top.score.toStringAsFixed(0)}% | ${top.price}',
                        style: TextStyle(fontSize: 16, color: col(top.signal), fontWeight: FontWeight.w600)),
                    Text('Backtest confidence: ${top.conf.toStringAsFixed(0)}% (agreeing strategies ka avg win-rate)',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 8),
                    SizedBox(height: 180, width: double.infinity, child: CustomPaint(painter: ChartPainter(top.candles))),
                    const SizedBox(height: 4),
                    const Text('Blue=EMA9, Orange=EMA21', style: TextStyle(fontSize: 10, color: Colors.grey)),
                    const Divider(),
                    SizedBox(width: 170, child: TextField(decoration: const InputDecoration(labelText: 'Capital (USDT)', isDense: true), keyboardType: TextInputType.number, onChanged: (s) => setState(() => cap = double.tryParse(s) ?? cap))),
                    const SizedBox(height: 6),
                    Text(top.ok ? (top.dir > 0 ? '✅ TRADE LO: BUY (LONG)' : '✅ TRADE LO: SELL (SHORT)') : '⛔ ABHI TRADE MAT LO',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: top.ok ? col(top.signal) : Colors.orangeAccent)),
                    if (!top.ok) for (final w in top.why) Text('• $w', style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
                    if (top.ok) ...[
                      Text('Entry: ${top.price.toStringAsFixed(4)}'),
                      Text('Stop-loss: ${top.sl.toStringAsFixed(4)}', style: const TextStyle(color: Colors.redAccent)),
                      Text('Target: ${top.tp.toStringAsFixed(4)} (RR 1:2)', style: const TextStyle(color: Colors.greenAccent)),
                      Text('Exit: SL ya Target jo pehle lage. 6 candles (${top.tf}) me kuch na ho to band kar do.'),
                      Text('1% risk par size: ${min(cap, cap * 0.01 * top.price / (top.price - top.sl).abs()).toStringAsFixed(2)} USDT'),
                    ],
                    const Divider(),
                    const Text('Strategy | signal | backtest win-rate | trades', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    for (final e in top.votes.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(children: [
                          Text(e.value > 0 ? '▲ ' : (e.value < 0 ? '▼ ' : '• '),
                              style: TextStyle(color: e.value > 0 ? Colors.greenAccent : (e.value < 0 ? Colors.redAccent : Colors.grey))),
                          Expanded(child: Text(e.key)),
                          Text('${top.bt[e.key]!.wr.toStringAsFixed(0)}% · ${top.bt[e.key]!.trades}',
                              style: TextStyle(color: top.bt[e.key]!.wr >= 52 ? Colors.greenAccent : Colors.orangeAccent)),
                        ]),
                      ),
                  ]),
                ),
              ),
              Text('Scan: $updated (auto 60s) • chart live WebSocket se', style: const TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 6),
              for (var i = 0; i < res.length; i++)
                ListTile(
                  dense: true,
                  selected: i == sel,
                  onTap: () { setState(() => sel = i); live(); },
                  title: Text('${res[i].pair}  ${res[i].tf}'),
                  trailing: Text('${res[i].signal} ${res[i].score.toStringAsFixed(0)}%',
                      style: TextStyle(color: col(res[i].signal), fontWeight: FontWeight.bold)),
                ),
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Rules: ek trade me max 1% risk, din me 3% loss ya 3 loss ke baad band, SL kabhi mat hatao. Spot me SELL sirf exit hai, short futures me hota hai. Backtest purane data ka hai (next candle result), future ki guarantee nahi. Fees/slippage shamil nahi. Pehle demo/testnet par test karein.',
                    style: TextStyle(color: Colors.grey, fontSize: 11)),
              ),
            ]),
    );
  }
}

class ChartPainter extends CustomPainter {
  final List<Candle> all;
  ChartPainter(this.all);
  void line(Canvas cv, List<double> v, double Function(double) y, double w, Color c) {
    final p = Paint()..color = c..strokeWidth = 1.2..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final o = Offset(i * w + w / 2, y(v[i]));
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    cv.drawPath(path, p);
  }

  @override
  void paint(Canvas canvas, Size s) {
    final cs = all.sublist(all.length - 60);
    final cl = all.map((e) => e.c).toList();
    final e9 = ema(cl, 9).sublist(cl.length - 60), e21 = ema(cl, 21).sublist(cl.length - 60);
    final hi = cs.map((e) => e.h).reduce(max), lo = cs.map((e) => e.l).reduce(min);
    double y(double v) => s.height - (v - lo) / (hi - lo == 0 ? 1 : hi - lo) * s.height;
    final w = s.width / cs.length;
    for (var i = 0; i < cs.length; i++) {
      final e = cs[i];
      final p = Paint()..color = e.c >= e.o ? Colors.greenAccent : Colors.redAccent..strokeWidth = 1;
      final x = i * w + w / 2;
      canvas.drawLine(Offset(x, y(e.h)), Offset(x, y(e.l)), p);
      canvas.drawRect(Rect.fromLTRB(x - w * 0.35, y(max(e.o, e.c)), x + w * 0.35, y(min(e.o, e.c)) + 0.5), p);
    }
    line(canvas, e9, y, w, Colors.lightBlueAccent);
    line(canvas, e21, y, w, Colors.orangeAccent);
  }

  @override
  bool shouldRepaint(covariant ChartPainter old) => true;
}
