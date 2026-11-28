import 'dart:async';
import 'dart:math' as math;
import 'binance_service.dart';
import 'indicators.dart';
import 'models.dart';
import 'strategy3m.dart';

class Stats {
  int n = 0;
  int wins = 0;
  double sumR = 0;
  double gw = 0;
  double gl = 0;
  void add(double r) {
    n++;
    sumR += r;
    if (r > 0) {
      wins++;
      gw += r;
    } else {
      gl += -r;
    }
  }

  double get exp => n > 0 ? sumR / n : 0;
  double get winRate => n > 0 ? wins / n * 100 : 0;
  double get pf => gl > 0 ? gw / gl : (gw > 0 ? 99.0 : 0.0);
}

class TrT {
  TrT(this.t, this.r);
  final int t;
  final double r;
}

class OptRow {
  OptRow(this.p, this.train, this.test);
  final StratP p;
  final Stats train;
  final Stats test;
  double get score => train.n >= 25 ? train.exp * math.sqrt(train.n.toDouble()) : -1e9;
  bool get robust => test.n >= 10 && test.exp > 0 && train.exp > 0;
}

class OptReport {
  OptReport(this.name, this.tf, this.barrier, this.rows, this.combos);
  final String name;
  final String tf;
  final bool barrier; // true = strategie barriere BTC, false = strategie independante par jeton
  final List<OptRow> rows;
  final int combos;
}

/// Donnees d'un jeton : bougies 3m closes + indicateurs pre-calcules.
class _Tok {
  _Tok(this.sym, this.c);
  final String sym;
  final List<Candle> c;
  late final List<double> atrV = atr(c, 14);
  late final List<double> closes = c.map((x) => x.c).toList();
  final Map<String, MacdLines> _m = <String, MacdLines>{};
  MacdLines macd(int f, int s, int g) =>
      _m.putIfAbsent('$f/$s/$g', () => macdLines(closes, fast: f, slow: s, sig: g));
  late final Map<int, int> idx = <int, int>{for (var i = 0; i < c.length; i++) c[i].t: i};

  /// Mouvement sur 5 bougies (15 min), en %.
  late final List<double> ret5 = List<double>.generate(
    c.length,
    (i) => i >= 5 && c[i - 5].c > 0 ? (c[i].c / c[i - 5].c - 1) * 100 : 0.0,
  );

  /// Volume recent (5 bougies) rapporte au volume des 30 bougies precedentes.
  late final List<double> volRatio = () {
    final pre = List<double>.filled(c.length + 1, 0.0);
    for (var i = 0; i < c.length; i++) {
      pre[i + 1] = pre[i] + c[i].qv;
    }
    return List<double>.generate(c.length, (i) {
      if (i < 36) return 1.0;
      final a = (pre[i + 1] - pre[i - 4]) / 5;
      final b = (pre[i - 4] - pre[i - 34]) / 30;
      return b > 0 ? a / b : 1.0;
    });
  }();
}

Future<List<Candle>> _loadRange(BinanceService api, String sym, String tf, int startMs, int endMs) async {
  final out = <Candle>[];
  var cur = startMs;
  while (cur < endMs) {
    final k = await api.klinesFrom(sym, tf, cur, 1000);
    if (k.isEmpty) break;
    out.addAll(k);
    final lastT = k.last.t;
    if (lastT < cur) break;
    cur = lastT + tfMinutes(tf) * 60000;
    if (k.length < 1000) break;
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  // la derniere bougie est en formation : on la retire
  return out.length > 1 ? out.sublist(0, out.length - 1) : out;
}

List<TrT> _simToken(List<_Tok> toks, List<List<Sig3m>> sigs, StratP p, double fee) {
  final out = <TrT>[];
  for (var t = 0; t < toks.length; t++) {
    final tk = toks[t];
    var busy = -1;
    for (final s in sigs[t]) {
      final e = s.crossIdx;
      if (e <= busy) continue;
      final r = simTrade(tk.c, tk.atrV, e, s.dir, p, fee);
      if (r == null) continue;
      busy = r.exitIdx;
      out.add(TrT(tk.c[e].t, r.r));
    }
  }
  return out;
}

List<TrT> _simBarrier(_Tok btc, List<_Tok> toks, List<Sig3m> btcSigs, StratP p, double fee, int barrierMin, int topK,
    String tf, double minMove, int scanEvery) {
  final out = <TrT>[];
  final busyUntilT = <String, int>{};
  final tfMin = tfMinutes(tf);
  final winCandles = math.max(1, barrierMin ~/ tfMin);
  for (var si = 0; si < btcSigs.length; si++) {
    final s = btcSigs[si];
    // la barriere dure au plus winCandles bougies, ou jusqu'a l'inversion suivante de la boucle
    var lastStep = winCandles;
    if (si + 1 < btcSigs.length) lastStep = math.min(winCandles, btcSigs[si + 1].crossIdx - s.crossIdx);
    final t0 = btc.c[s.crossIdx].t;
    for (var step = 0; step <= lastStep; step += scanEvery) {
      final tScan = t0 + step * tfMin * 60000;
      final cands = <MapEntry<_Tok, double>>[];
      for (final tk in toks) {
        final i = tk.idx[tScan];
        if (i == null || i < 40) continue;
        if ((busyUntilT[tk.sym] ?? 0) >= tScan) continue;
        final mv = tk.ret5[i];
        if (mv.abs() < minMove || (mv > 0 ? 1 : -1) != s.dir) continue;
        cands.add(MapEntry<_Tok, double>(tk, mv.abs() * tk.volRatio[i].clamp(0.2, 10.0).toDouble()));
      }
      cands.sort((a, b) => b.value.compareTo(a.value));
      for (final e in cands.take(topK)) {
        final tk = e.key;
        final i = tk.idx[tScan]!;
        final r = simTrade(tk.c, tk.atrV, i, s.dir, p, fee);
        if (r == null) continue;
        busyUntilT[tk.sym] = tk.c[r.exitIdx].t;
        out.add(TrT(tScan, r.r));
      }
    }
  }
  return out;
}

OptRow _row(StratP p, List<TrT> trades, int splitMs) {
  final tr = Stats();
  final te = Stats();
  for (final t in trades) {
    if (t.t <= splitMs) {
      tr.add(t.r);
    } else {
      te.add(t.r);
    }
  }
  return OptRow(p, tr, te);
}

List<double> _impGrid(String tf, bool barrier) {
  if (tf == '3m') return barrier ? const <double>[0.15, 0.25, 0.4, 0.65] : const <double>[0.4, 0.65, 0.9, 1.2];
  if (tf == '15m') return const <double>[0.6, 0.9, 1.2, 1.6];
  return const <double>[1.5, 2.0, 3.0, 4.0];
}

List<int> _winGrid(String tf, bool barrier) {
  if (tf == '3m') return barrier ? const <int>[2, 3, 5] : const <int>[2, 3, 5, 8];
  if (tf == '15m') return const <int>[2, 3, 4];
  return const <int>[2, 3];
}

List<int> _holdGrid(String tf) {
  if (tf == '3m') return const <int>[20, 40];
  if (tf == '15m') return const <int>[16, 48];
  return const <int>[12, 24];
}

/// Optimisation etendue : grille de parametres, validation hors echantillon (70 % apprentissage / 30 % test).
/// 3m : barriere BTC + strategie independante par jeton ; 15m et 1h : barriere BTC (trades de longue duree).
Future<List<OptReport>> runOptimization({
  required Market market,
  required String tf,
  required int days,
  required List<String> symbols,
  required int barrierMin,
  required int topK,
  required void Function(String) onProgress,
}) async {
  final api = BinanceService(market);
  final end = DateTime.now().millisecondsSinceEpoch;
  final start = end - days * 86400000;
  final fee = market.fee;
  final minMove = tf == '3m' ? 0.3 : (tf == '15m' ? 0.6 : 1.5);
  final scanEvery = tf == '3m' ? 5 : 2;

  onProgress('Chargement BTCUSDT ($tf)...');
  final btcC = await _loadRange(api, 'BTCUSDT', tf, start, end);
  if (btcC.length < 200) throw Exception('Historique BTC insuffisant (${btcC.length} bougies $tf)');
  final btc = _Tok('BTCUSDT', btcC);
  final toks = <_Tok>[];
  for (var i = 0; i < symbols.length; i++) {
    onProgress('Chargement ${symbols[i]} (${i + 1}/${symbols.length})...');
    try {
      final c = await _loadRange(api, symbols[i], tf, start, end);
      if (c.length >= 200) toks.add(_Tok(symbols[i], c));
    } catch (_) {}
  }
  if (toks.isEmpty) throw Exception('Aucun jeton exploitable');
  final split = start + ((end - start) * 0.7).round();

  const macdG = <List<int>>[
    <int>[12, 26, 9],
    <int>[6, 13, 5],
  ];
  const slG = <double>[1.0, 1.5, 2.5];
  const tpG = <double>[1.0, 1.5, 2.0, 3.0];
  final holdG = _holdGrid(tf);
  final reports = <OptReport>[];

  List<OptRow> top(List<OptRow> rows) {
    final l = rows.where((r) => r.score > -1e8).toList()..sort((a, b) => b.score.compareTo(a.score));
    return l.take(8).toList();
  }

  // ---- A : strategie independante par jeton (3m uniquement)
  if (tf == '3m') {
    final impA = _impGrid(tf, false);
    final winA = _winGrid(tf, false);
    final totalA = impA.length * winA.length * macdG.length * slG.length * tpG.length * holdG.length;
    final rowsA = <OptRow>[];
    var done = 0;
    for (final imp in impA) {
      for (final w in winA) {
        for (final mg in macdG) {
          final base = StratP(impulse: imp, win: w, fast: mg[0], slow: mg[1], sig: mg[2]);
          final sigs = <List<Sig3m>>[
            for (final tk in toks) loopSignals(tk.c, tk.macd(mg[0], mg[1], mg[2]), base, 20, tfMinutes(tf) * 60000),
          ];
          for (final sl in slG) {
            for (final tp in tpG) {
              for (final h in holdG) {
                final p = base.copyWith(slAtr: sl, tpR: tp, hold: h);
                rowsA.add(_row(p, _simToken(toks, sigs, p, fee), split));
                done++;
              }
            }
          }
          onProgress('Strategie par jeton : $done/$totalA');
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    reports.add(OptReport('Strategie independante par jeton (${toks.length} jetons, $days j)', tf, false, top(rowsA), totalA));
  }

  // ---- B : barriere BTC + jetons les plus actifs
  final impB = _impGrid(tf, true);
  final winB = _winGrid(tf, true);
  final totalB = impB.length * winB.length * macdG.length * slG.length * tpG.length * holdG.length;
  final rowsB = <OptRow>[];
  var doneB = 0;
  for (final imp in impB) {
    for (final w in winB) {
      for (final mg in macdG) {
        final base = StratP(impulse: imp, win: w, fast: mg[0], slow: mg[1], sig: mg[2]);
        final bs = loopSignals(btc.c, btc.macd(mg[0], mg[1], mg[2]), base, math.max(1, barrierMin ~/ tfMinutes(tf)), tfMinutes(tf) * 60000);
        for (final sl in slG) {
          for (final tp in tpG) {
            for (final h in holdG) {
              final p = base.copyWith(slAtr: sl, tpR: tp, hold: h);
              rowsB.add(_row(p, _simBarrier(btc, toks, bs, p, fee, barrierMin, topK, tf, minMove, scanEvery), split));
              doneB++;
            }
          }
        }
        onProgress('Barriere BTC $tf : $doneB/$totalB');
        await Future<void>.delayed(Duration.zero);
      }
    }
  }
  reports.add(OptReport('Barriere BTC $tf + $topK jetons les plus actifs ($days j)', tf, true, top(rowsB), totalB));
  return reports;
}
