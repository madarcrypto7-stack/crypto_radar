import 'dart:math' as math;
import 'indicators.dart';

/// Parametres de la strategie 3m : impulsion + croisement MACD.
class StratP {
  const StratP({
    this.impulse = 0.65,
    this.win = 5,
    this.fast = 12,
    this.slow = 26,
    this.sig = 9,
    this.slAtr = 1.5,
    this.tpR = 1.5,
    this.hold = 20,
  });
  final double impulse; // % : corps minimal de la bougie 3m (close/open - 1)
  final int win; // nombre de bougies pour attendre le croisement MACD apres l'impulsion
  final int fast;
  final int slow;
  final int sig;
  final double slAtr; // stop = slAtr x ATR(14) 3m
  final double tpR; // objectif = tpR x risque
  final int hold; // duree max (bougies) en backtest

  StratP copyWith({double? impulse, int? win, int? fast, int? slow, int? sig, double? slAtr, double? tpR, int? hold}) =>
      StratP(
        impulse: impulse ?? this.impulse,
        win: win ?? this.win,
        fast: fast ?? this.fast,
        slow: slow ?? this.slow,
        sig: sig ?? this.sig,
        slAtr: slAtr ?? this.slAtr,
        tpR: tpR ?? this.tpR,
        hold: hold ?? this.hold,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'impulse': impulse,
        'win': win,
        'fast': fast,
        'slow': slow,
        'sig': sig,
        'slAtr': slAtr,
        'tpR': tpR,
        'hold': hold,
      };

  factory StratP.fromJson(Map<String, dynamic> j) => StratP(
        impulse: (j['impulse'] as num?)?.toDouble() ?? 0.65,
        win: (j['win'] as num?)?.toInt() ?? 5,
        fast: (j['fast'] as num?)?.toInt() ?? 12,
        slow: (j['slow'] as num?)?.toInt() ?? 26,
        sig: (j['sig'] as num?)?.toInt() ?? 9,
        slAtr: (j['slAtr'] as num?)?.toDouble() ?? 1.5,
        tpR: (j['tpR'] as num?)?.toDouble() ?? 1.5,
        hold: (j['hold'] as num?)?.toInt() ?? 20,
      );

  String get label =>
      'impulsion $impulse % · fenetre $win · MACD $fast/$slow/$sig · SL ${slAtr}xATR · TP ${tpR}R · tenue $hold bougies';
}

/// Etat de la barriere BTC : closed / armed (impulsion en attente du MACD) / open.
class BarrierState {
  const BarrierState(this.state, this.dir, this.sinceMs, this.expiresMs, this.pct, this.note);
  const BarrierState.closed([String note = '']) : this('closed', 0, 0, 0, 0.0, note);
  final String state;
  final int dir; // +1 long, -1 short
  final int sinceMs;
  final int expiresMs;
  final double pct; // corps de la bougie d'impulsion (%)
  final String note;
}

/// Signal : bougie d'impulsion (index) suivie d'un croisement MACD dans le meme sens (index).
class Sig3m {
  Sig3m(this.dir, this.impulseIdx, this.crossIdx);
  final int dir;
  final int impulseIdx;
  final int crossIdx;
}

/// Parcourt des bougies CLOSES. Une impulsion = |close/open - 1| >= impulse. Elle est confirmee quand le DIF croise le DEA
/// dans son sens (au-dessus pour un long, en dessous pour un short) dans les [win] bougies qui suivent (impulsion incluse).
List<Sig3m> scanSignals(List<Candle> c, MacdLines m, StratP p, {int from = 0}) {
  final out = <Sig3m>[];
  final n = c.length;
  final start = math.max(math.max(from, 1), p.slow + p.sig);
  var lastCross = -1;
  for (var i = start; i < n; i++) {
    final o = c[i].o;
    if (o <= 0) continue;
    final ret = (c[i].c / o - 1) * 100;
    if (ret.abs() < p.impulse) continue;
    final dir = ret > 0 ? 1 : -1;
    final end = math.min(n - 1, i + p.win);
    for (var j = i; j <= end; j++) {
      final up = m.hist[j - 1] <= 0 && m.hist[j] > 0;
      final dn = m.hist[j - 1] >= 0 && m.hist[j] < 0;
      if ((dir == 1 && up) || (dir == -1 && dn)) {
        if (j > lastCross) {
          out.add(Sig3m(dir, i, j));
          lastCross = j;
        }
        break;
      }
    }
  }
  return out;
}

class SimOut {
  SimOut(this.r, this.exitIdx);
  final double r; // resultat en multiples du risque (frais inclus)
  final int exitIdx;
}

/// Simule un trade ouvert a la cloture de la bougie [entryIdx] : stop = slAtr x ATR, objectif = tpR x risque,
/// sortie a l'echeance [hold]. Si stop et objectif sont touches dans la meme bougie, le stop est retenu (prudence).
SimOut? simTrade(List<Candle> c, List<double> atrV, int entryIdx, int dir, StratP p, double feeRate) {
  if (entryIdx >= c.length - 1) return null;
  final entry = c[entryIdx].c;
  final risk = atrV[entryIdx] * p.slAtr;
  if (risk <= 0 || entry <= 0) return null;
  final sl = dir == 1 ? entry - risk : entry + risk;
  final tp = dir == 1 ? entry + risk * p.tpR : entry - risk * p.tpR;
  final last = math.min(c.length - 1, entryIdx + p.hold);
  double? r;
  var exit = last;
  for (var k = entryIdx + 1; k <= last; k++) {
    final hitSl = dir == 1 ? c[k].l <= sl : c[k].h >= sl;
    final hitTp = dir == 1 ? c[k].h >= tp : c[k].l <= tp;
    if (hitSl) {
      r = -1.0;
      exit = k;
      break;
    }
    if (hitTp) {
      r = p.tpR;
      exit = k;
      break;
    }
  }
  r ??= (dir == 1 ? c[last].c - entry : entry - c[last].c) / risk;
  r -= feeRate * 2 * entry / risk;
  return SimOut(r, exit);
}

/// Echelles des barrieres de flux BTC.
const List<String> kBarrierTfs = <String>['3m', '15m', '1h'];

int tfMinutes(String tf) => switch (tf) {
      '3m' => 3,
      '15m' => 15,
      _ => 60,
    };

/// Barriere de flux BTC d'une echelle : activation, parametres de la strategie et duree d'ouverture.
class BarrierCfg {
  BarrierCfg({required this.tf, required this.enabled, required this.p, required this.durMin});
  final String tf;
  bool enabled;
  StratP p;
  int durMin;

  String get title => switch (tf) {
        '3m' => 'Barriere 3m (court terme)',
        '15m' => 'Barriere 15m (tendance longue)',
        _ => 'Barriere 1h (tendance longue)',
      };
  int get minDur => switch (tf) {
        '3m' => 15,
        '15m' => 120,
        _ => 720,
      };
  int get maxDur => switch (tf) {
        '3m' => 90,
        '15m' => 720,
        _ => 1440,
      };
  int get durStep => switch (tf) {
        '3m' => 15,
        '15m' => 60,
        _ => 120,
      };
  double get impMin => switch (tf) {
        '3m' => 0.1,
        '15m' => 0.3,
        _ => 1.0,
      };
  double get impMax => switch (tf) {
        '3m' => 1.5,
        '15m' => 3.0,
        _ => 8.0,
      };
  double get impStep => switch (tf) {
        '3m' => 0.05,
        '15m' => 0.1,
        _ => 0.25,
      };
  int get impDiv => ((impMax - impMin) / impStep).round();
  int get durDiv => (maxDur - minDur) ~/ durStep;

  Map<String, dynamic> toJson() => <String, dynamic>{'enabled': enabled, 'p': p.toJson(), 'dur': durMin};

  static BarrierCfg fromJson(String tf, Map<String, dynamic> j) {
    final d = defaultBarrierCfg(tf);
    d.enabled = (j['enabled'] as bool?) ?? false;
    final pj = j['p'];
    if (pj is Map<String, dynamic>) d.p = StratP.fromJson(pj);
    final dur = (j['dur'] as num?)?.toInt();
    if (dur != null) d.durMin = dur < d.minDur ? d.minDur : (dur > d.maxDur ? d.maxDur : dur);
    return d;
  }
}

BarrierCfg defaultBarrierCfg(String tf) => switch (tf) {
      '3m' => BarrierCfg(
          tf: '3m',
          enabled: false,
          p: const StratP(impulse: 0.65, win: 5, slAtr: 1.5, tpR: 1.5, hold: 20),
          durMin: 45,
        ),
      '15m' => BarrierCfg(
          tf: '15m',
          enabled: false,
          p: const StratP(impulse: 1.2, win: 4, slAtr: 1.5, tpR: 2.0, hold: 24),
          durMin: 360,
        ),
      _ => BarrierCfg(
          tf: '1h',
          enabled: false,
          p: const StratP(impulse: 3.0, win: 3, slAtr: 2.0, tpR: 2.0, hold: 24),
          durMin: 1080,
        ),
    };

String fmtDur(int min) => min >= 60 ? '${(min / 60).toStringAsFixed(min % 60 == 0 ? 0 : 1)} h' : '$min min';

/// Boucle fermee de la barriere : dans chaque sens, il faut deux justifications, dans N'IMPORTE QUEL ordre :
///  - une bougie d'impulsion dans le sens (corps >= seuil : +x % pour un long, -x % pour un short) ;
///  - le croisement du MACD dans le sens (DIF au-dessus de DEA pour un long, en dessous pour un short).
/// Impulsion d'abord : le croisement doit suivre dans les [win] bougies.
/// Croisement d'abord : il reste valable tant que la disposition DIF/DEA tient (limite 8 x win, au moins 40 bougies),
/// et la barriere s'ouvre a la premiere bougie d'impulsion qui le suit.
/// Apres l'ouverture dans un sens, la surveillance s'inverse immediatement : on attend les justifications du sens oppose
/// (evenements posterieurs a l'ouverture). La boucle est stricte : long, puis short, puis long... ; la barriere n'autorise
/// les trades que pendant sa duree d'ouverture, mais l'etat de la boucle (sens a surveiller) persiste.
class LoopMachine {
  LoopMachine(this.p, this.durCandles, this.tfMs);
  final StratP p;
  final int durCandles;
  final int tfMs;
  int dir = 0; // dernier sens confirme (etat de la boucle) ; 0 = aucun encore
  int openT = 0; // debut (ms) de la bougie qui a ouvert la barriere
  bool cancelled = false; // annulee par une barriere plus recente de sens oppose (la boucle continue)
  final List<int> _crossT = <int>[-1, -1]; // index 0 = short, 1 = long : debut de la bougie du croisement valide
  final List<int> _impT = <int>[-1, -1]; // idem pour la derniere impulsion

  static int _k(int t) => t == 1 ? 1 : 0;
  /// Barriere ouverte aux trades : dans les [durCandles] bougies qui suivent la derniere ouverture.
  bool activeAt(int nowT) => dir != 0 && !cancelled && _age(openT, nowT) < durCandles;
  bool hasCross(int t) => _crossT[_k(t)] >= 0;
  bool hasImp(int t) => _impT[_k(t)] >= 0;
  int _age(int t0, int t1) => (t1 - t0) ~/ tfMs;

  /// Traite la bougie close [i]. Retourne un signal si la barriere s'ouvre (ou s'inverse) a cette bougie.
  Sig3m? step(List<Candle> c, MacdLines m, int i) {
    if (i < 1 || i < p.slow + p.sig) return null;
    final now = c[i].t;
    final crossMax = math.max(40, 8 * p.win);
    final up = m.hist[i - 1] <= 0 && m.hist[i] > 0;
    final dn = m.hist[i - 1] >= 0 && m.hist[i] < 0;
    for (final t in const <int>[1, -1]) {
      final k = _k(t);
      if (m.hist[i] * t <= 0) _crossT[k] = -1;
      if ((t == 1 && up) || (t == -1 && dn)) _crossT[k] = now;
      if (_crossT[k] >= 0 && _age(_crossT[k], now) > crossMax) _crossT[k] = -1;
      if (_impT[k] >= 0 && _age(_impT[k], now) > p.win) _impT[k] = -1;
    }
    final o = c[i].o;
    final ret = o > 0 ? (c[i].c / o - 1) * 100 : 0.0;
    final watch = dir == 0 ? const <int>[1, -1] : <int>[-dir];
    for (final t in watch) {
      final k = _k(t);
      final crossNow = (t == 1 && up) || (t == -1 && dn);
      var open = false;
      if (ret * t >= p.impulse) {
        if (_crossT[k] >= 0) {
          open = true; // croisement d'abord, puis impulsion
        } else {
          _impT[k] = now; // impulsion memorisee, en attente du croisement
        }
      }
      if (!open && crossNow && _impT[k] >= 0) open = true; // impulsion d'abord, puis croisement
      if (open) {
        final impAge = _impT[k] >= 0 ? _age(_impT[k], now) : 0;
        dir = t;
        openT = now;
        cancelled = false;
        _crossT[0] = -1;
        _crossT[1] = -1;
        _impT[0] = -1;
        _impT[1] = -1;
        return Sig3m(t, math.max(0, i - impAge), i);
      }
    }
    return null;
  }
}

/// Toutes les ouvertures / inversions de la boucle sur une serie de bougies closes (utilise par le backtest).
List<Sig3m> loopSignals(List<Candle> c, MacdLines m, StratP p, int durCandles, int tfMs) {
  final mach = LoopMachine(p, durCandles, tfMs);
  final out = <Sig3m>[];
  for (var i = 1; i < c.length; i++) {
    final s = mach.step(c, m, i);
    if (s != null) out.add(s);
  }
  return out;
}

/// Texte d'etat : ce que la boucle attend pour chaque sens surveille.
String loopWatchNote(LoopMachine mc, StratP p) {
  final ts = mc.dir == 0 ? const <int>[1, -1] : <int>[-mc.dir];
  return ts
      .map((t) =>
          '${t == 1 ? '↑ LONG' : '↓ SHORT'} : bougie ${t == 1 ? '+' : '-'}${p.impulse.toStringAsFixed(2)} % ${mc.hasImp(t) ? '✔' : '✘'} · MACD ${mc.hasCross(t) ? '✔' : '✘'}')
      .join('  |  ');
}
