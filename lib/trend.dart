import 'indicators.dart';
import 'models.dart';

enum TokenTrend { bull, bear, neutral }

extension TokenTrendX on TokenTrend {
  String get label => switch (this) {
        TokenTrend.bull => 'HAUSSIERE',
        TokenTrend.bear => 'BAISSIERE',
        TokenTrend.neutral => 'INDECISE',
      };
}

class TrendResult {
  TrendResult(this.trend, this.bullPts, this.bearPts, this.lines);
  final TokenTrend trend;
  final int bullPts;
  final int bearPts;
  final List<String> lines;
  int get total => bullPts + bearPts;
}

/// Tendance du jeton : 5 criteres (EMA20/EMA50 1h, Supertrend 1h, prix vs EMA50 1h, EMA20/EMA50 4h, Supertrend 4h).
/// Haussiere si au moins 4 criteres sur 5 sont haussiers, baissiere si au moins 4 sont baissiers, sinon indecise.
/// Si le 4h est indisponible, les 3 criteres du 1h doivent tous concorder.
TrendResult analyzeTrend(List<Candle> h1, List<Candle> h4) {
  var bull = 0;
  var bear = 0;
  final lines = <String>[];

  void add(bool isBull, String text) {
    if (isBull) {
      bull++;
    } else {
      bear++;
    }
    lines.add('${isBull ? '↑ haussier' : '↓ baissier'} · $text');
  }

  if (h1.length >= 60) {
    final c = h1.map((x) => x.c).toList();
    final e20 = ema(c, 20).last;
    final e50 = ema(c, 50).last;
    add(e20 > e50, 'EMA20 ${e20 > e50 ? '>' : '<'} EMA50 (1h)');
    add(supertrend(h1).last == 1, 'Supertrend 1h');
    add(c.last > e50, 'Prix ${c.last > e50 ? 'au-dessus de' : 'sous'} EMA50 (1h)');
  }
  if (h4.length >= 60) {
    final c = h4.map((x) => x.c).toList();
    final e20 = ema(c, 20).last;
    final e50 = ema(c, 50).last;
    add(e20 > e50, 'EMA20 ${e20 > e50 ? '>' : '<'} EMA50 (4h)');
    add(supertrend(h4).last == 1, 'Supertrend 4h');
  }

  final total = bull + bear;
  var trend = TokenTrend.neutral;
  if (total > 0) {
    final need = total >= 5 ? 4 : total;
    if (bull >= need) {
      trend = TokenTrend.bull;
    } else if (bear >= need) {
      trend = TokenTrend.bear;
    }
  }
  return TrendResult(trend, bull, bear, lines);
}

class ReboundResult {
  ReboundResult(this.ok, this.lines);
  final bool ok;
  final List<String> lines;
}

/// Exception a la regle de tendance : fort rebond / retournement. Cinq conditions, toutes obligatoires :
/// 1. Surextension : prix >= 3 ATR de l'EMA50 1h (ou RSI 1h >= 75 pour un short / <= 25 pour un long).
/// 2. Reaction en direct : mouvement rapide dans le sens du rebond, au moins le nombre de mouvements de la sensibilite.
/// 3. Pulsation : au moins 75 % des mouvements (fleches du classement) vont dans le sens du rebond, <= 25 % de recul.
/// 4. MACD 15m : l'ecart DIF - DEA s'elargit dans le sens du rebond, en continu (au plus 1 recul sur 4 pas).
/// 5. Bougie 1h en cours dans le sens du rebond.
const double kPulseMin = 0.75;

ReboundResult detectRebound(
  List<Candle> h1,
  List<Candle> m15,
  TokenData t,
  bool wantLong,
  Sensitivity sens,
) {
  if (h1.length < 60 || t.price <= 0) {
    return ReboundResult(false, <String>['Donnees insuffisantes pour evaluer un rebond']);
  }
  final closes = h1.map((x) => x.c).toList();
  final e50 = ema(closes, 50).last;
  final a = atr(h1, 14).last;
  final r = rsi(closes).last;
  if (a <= 0) return ReboundResult(false, <String>['ATR indisponible']);

  // 1. Surextension
  final ext = (t.price - e50) / a;
  final extOk = wantLong ? (ext <= -3.0 || r <= 25) : (ext >= 3.0 || r >= 75);

  // 2. Reaction en direct
  final dirWanted = wantLong ? 'up' : 'down';
  final momOk = t.direction == dirWanted &&
      (t.speed == 'rapide' || t.speed == 'explosive') &&
      t.dirEvents >= sens.minEvents;

  // 3. Pulsation : part des mouvements dans le sens du rebond vs recul
  final up = t.upEvents;
  final down = t.downEvents;
  final total = up + down;
  final fav = wantLong ? up : down;
  final against = wantLong ? down : up;
  final share = total > 0 ? fav / total : 0.0;
  final pulseOk = total > 0 && share >= kPulseMin;

  // 4. MACD 15m : ecart DIF - DEA qui s'elargit dans le sens du rebond, en continu
  var macdOk = false;
  String macdLine;
  if (m15.length >= 60) {
    final hist = macdHist(m15.map((x) => x.c).toList());
    final n = hist.length;
    var good = 0;
    for (var i = n - 4; i < n; i++) {
      final d = hist[i] - hist[i - 1];
      if (wantLong ? d > 0 : d < 0) good++;
    }
    final net = hist[n - 1] - hist[n - 5];
    final lastStep = hist[n - 1] - hist[n - 2];
    macdOk = good >= 3 && (wantLong ? (net > 0 && lastStep > 0) : (net < 0 && lastStep < 0));
    macdLine = 'Ecart DIF-DEA (MACD 15m) : ${hist[n - 5].toStringAsExponential(2)} -> ${hist[n - 1].toStringAsExponential(2)}, '
        '$good/4 pas dans le sens du rebond (au plus 1 recul)';
  } else {
    macdLine = 'MACD 15m indisponible';
  }

  // 5. Bougie 1h en cours
  final last = h1.last;
  final candleOk = wantLong ? last.c > last.o : last.c < last.o;

  final lines = <String>[
    '${extOk ? '✔' : '✘'} Surextension : ecart a l EMA50 ${ext.toStringAsFixed(1)} ATR, RSI ${r.toStringAsFixed(0)} '
        '(${wantLong ? '<= -3 ATR ou RSI <= 25' : '>= 3 ATR ou RSI >= 75'})',
    '${momOk ? '✔' : '✘'} Reaction en direct : ${t.direction}, vitesse ${t.speed}, ${t.dirEvents} mouvements '
        '(il faut ${wantLong ? 'hausse' : 'baisse'} rapide et >= ${sens.minEvents} mouvements)',
    '${pulseOk ? '✔' : '✘'} Pulsation : $fav mouvements dans le sens du rebond vs $against de recul '
        '= ${(share * 100).toStringAsFixed(0)} % (minimum 75 %)',
    '${macdOk ? '✔' : '✘'} $macdLine',
    '${candleOk ? '✔' : '✘'} Bougie 1h en cours ${wantLong ? 'haussiere' : 'baissiere'}',
  ];
  return ReboundResult(extOk && momOk && pulseOk && macdOk && candleOk, lines);
}
