import 'dart:math' as math;
import 'indicators.dart';

/// Echelles de temps du tableau de bord du flux BTC.
const List<String> kBtcTfs = <String>['15m', '30m', '1h', '2h', '4h', '8h', '12h'];

/// Poids de chaque echelle dans l'indice composite (somme = 1) : les echelles longues pesent davantage.
const Map<String, double> kBtcTfWeights = <String, double>{
  '15m': 0.05,
  '30m': 0.08,
  '1h': 0.15,
  '2h': 0.17,
  '4h': 0.22,
  '8h': 0.18,
  '12h': 0.15,
};

double _c(double v) => v < -1 ? -1.0 : (v > 1 ? 1.0 : v);

/// Score de tendance d'une echelle de temps, de -100 (baissier fort) a +100 (haussier fort).
/// Methode multi-facteurs normalisee par la volatilite (ATR), pour comparer toutes les echelles entre elles :
///  - 30 % ecart EMA7 - EMA25 (en ATR, sature a +-2)
///  - 20 % position du prix par rapport a l'EMA25 (en ATR, sature a +-3)
///  - 20 % histogramme MACD (DIF - DEA) normalise par l'ATR
///  - 15 % RSI(14) centre sur 50
///  - 15 % direction du Supertrend (10, 3)
class TfScore {
  TfScore(this.tf, this.score, this.emaPart, this.pricePart, this.macdPart, this.rsiPart, this.stUp, this.rsi,
      {this.valid = true});
  factory TfScore.empty(String tf) => TfScore(tf, 0, 0, 0, 0, 0, true, 50, valid: false);

  final String tf;
  final double score;
  final double emaPart;
  final double pricePart;
  final double macdPart;
  final double rsiPart;
  final bool stUp;
  final double rsi;
  final bool valid;
}

TfScore scoreTimeframe(String tf, List<Candle> k, double? livePrice) {
  if (k.length < 60) return TfScore.empty(tf);
  var c = k;
  if (livePrice != null && livePrice > 0) {
    final l = k.last;
    c = <Candle>[
      ...k.sublist(0, k.length - 1),
      Candle(l.t, l.o, math.max(l.h, livePrice), math.min(l.l, livePrice), livePrice, l.v, l.qv),
    ];
  }
  final closes = c.map((x) => x.c).toList();
  final e7 = ema(closes, 7).last;
  final e25 = ema(closes, 25).last;
  final a = atr(c, 14).last;
  if (a <= 0) return TfScore.empty(tf);
  final px = closes.last;
  final emaPart = _c((e7 - e25) / a / 2);
  final pricePart = _c((px - e25) / a / 3);
  final macdPart = _c(macdHist(closes).last / a * 5);
  final r = rsi(closes).last;
  final rsiPart = _c((r - 50) / 25);
  final stUp = supertrend(c).last == 1;
  final s = 100 * (0.30 * emaPart + 0.20 * pricePart + 0.20 * macdPart + 0.15 * rsiPart + 0.15 * (stUp ? 1.0 : -1.0));
  return TfScore(tf, s, emaPart, pricePart, macdPart, rsiPart, stUp, r);
}

/// Indice composite du flux BTC + lecture du regime (alignement des echelles, rebond ou correction).
class BtcFluxIndex {
  BtcFluxIndex(this.byTf, this.index, this.bull, this.bear, this.neutral, this.shortAvg, this.longAvg, this.regime);
  final Map<String, TfScore> byTf;
  final double index; // -100 .. +100
  final int bull; // echelles avec score >= +15
  final int bear; // echelles avec score <= -15
  final int neutral;
  final double shortAvg; // moyenne 15m / 30m / 1h
  final double longAvg; // moyenne 4h / 8h / 12h
  final String regime;
}

BtcFluxIndex buildFluxIndex(Map<String, TfScore> m) {
  double idx = 0;
  double wsum = 0;
  var bull = 0;
  var bear = 0;
  var neutral = 0;
  for (final tf in kBtcTfs) {
    final s = m[tf];
    if (s == null || !s.valid) continue;
    final w = kBtcTfWeights[tf] ?? 0;
    idx += w * s.score;
    wsum += w;
    if (s.score >= 15) {
      bull++;
    } else if (s.score <= -15) {
      bear++;
    } else {
      neutral++;
    }
  }
  idx = wsum > 0 ? idx / wsum : 0;

  double avg(List<String> tfs) {
    var sum = 0.0;
    var n = 0;
    for (final tf in tfs) {
      final s = m[tf];
      if (s != null && s.valid) {
        sum += s.score;
        n++;
      }
    }
    return n > 0 ? sum / n : 0;
  }

  final sAvg = avg(<String>['15m', '30m', '1h']);
  final lAvg = avg(<String>['4h', '8h', '12h']);
  String regime;
  if (wsum == 0) {
    regime = 'Donnees en cours de chargement';
  } else if (sAvg >= 20 && lAvg <= -20) {
    regime = 'REBOND court terme dans une tendance baissiere';
  } else if (sAvg <= -20 && lAvg >= 20) {
    regime = 'CORRECTION court terme dans une tendance haussiere';
  } else if (bull >= 6) {
    regime = 'HAUSSIER aligne sur toutes les echelles';
  } else if (bear >= 6) {
    regime = 'BAISSIER aligne sur toutes les echelles';
  } else if (idx >= 15) {
    regime = 'Biais haussier';
  } else if (idx <= -15) {
    regime = 'Biais baissier';
  } else {
    regime = 'Neutre / indecis';
  }
  return BtcFluxIndex(m, idx, bull, bear, neutral, sAvg, lAvg, regime);
}

/// Alignement global : part du poids des echelles qui vont dans le sens dominant (score >= 15 dans ce sens).
class FluxAlign {
  FluxAlign(this.pct, this.dir);
  final double pct; // 0 .. 100
  final int dir; // +1 haussier, -1 baissier
}

FluxAlign fluxAlignment(BtcFluxIndex ix) {
  final dir = ix.index >= 0 ? 1 : -1;
  var aligned = 0.0;
  var total = 0.0;
  for (final tf in kBtcTfs) {
    final s = ix.byTf[tf];
    if (s == null || !s.valid) continue;
    final w = kBtcTfWeights[tf] ?? 0;
    total += w;
    if (s.score * dir >= 15) aligned += w;
  }
  return FluxAlign(total > 0 ? aligned / total * 100 : 0, dir);
}
