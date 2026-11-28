import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'format.dart';
import 'models.dart';

class TradePlan {
  TradePlan({
    required this.symbol,
    required this.long,
    required this.entry,
    required this.sl,
    required this.tp1,
    required this.tp2,
    required this.leverage,
    required this.notional,
    required this.riskUsd,
  });
  final String symbol;
  final bool long;
  final double entry;
  final double sl;
  final double tp1;
  final double tp2;
  final double leverage;
  final double notional;
  final double riskUsd;

  // Contexte enregistre dans le journal
  String source = 'bureaux';
  double score = 0;
  String btcFlux = '';
  String tokenTrend = '';
  String flags = '';
}

class PaperTrade {
  PaperTrade({
    required this.id,
    required this.symbol,
    required this.long,
    required this.futures,
    required this.entry,
    required this.notional,
    required this.leverage,
    required this.sl,
    required this.tp1,
    required this.tp2,
    required this.openedAt,
  }) {
    slInit = sl;
  }

  final int id;
  final String symbol;
  final bool long;
  final bool futures;
  final double entry;
  final double notional;
  final double leverage;
  double sl;
  double slInit = 0;
  String source = '';
  double score = 0;
  String btcFlux = '';
  String tokenTrend = '';
  String flags = '';
  double mfePct = 0; // excursion favorable maximale (% du prix d'entree)
  double maePct = 0; // excursion defavorable maximale (negative)
  String appVersion = '';
  final double tp1;
  final double tp2;
  final int openedAt;

  double remaining = 1.0;
  double realized = 0;
  bool tp1Hit = false;
  String status = 'open'; // open, tp, sl, be, manual
  int? closedAt;
  double? exit;

  double get margin => notional / leverage;
  double unrealized(double p) => notional * remaining * (p / entry - 1) * (long ? 1 : -1);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'symbol': symbol,
        'long': long,
        'futures': futures,
        'entry': entry,
        'notional': notional,
        'leverage': leverage,
        'sl': sl,
        'slInit': slInit,
        'source': source,
        'score': score,
        'btcFlux': btcFlux,
        'tokenTrend': tokenTrend,
        'flags': flags,
        'mfePct': mfePct,
        'maePct': maePct,
        'appVersion': appVersion,
        'tp1': tp1,
        'tp2': tp2,
        'openedAt': openedAt,
        'remaining': remaining,
        'realized': realized,
        'tp1Hit': tp1Hit,
        'status': status,
        'closedAt': closedAt,
        'exit': exit,
      };

  factory PaperTrade.fromJson(Map<String, dynamic> j) {
    final t = PaperTrade(
      id: (j['id'] as num).toInt(),
      symbol: j['symbol'] as String,
      long: j['long'] as bool,
      futures: j['futures'] as bool,
      entry: toD(j['entry']),
      notional: toD(j['notional']),
      leverage: toD(j['leverage']),
      sl: toD(j['sl']),
      tp1: toD(j['tp1']),
      tp2: toD(j['tp2']),
      openedAt: (j['openedAt'] as num).toInt(),
    );
    t.slInit = j['slInit'] == null ? toD(j['sl']) : toD(j['slInit']);
    t.source = (j['source'] as String?) ?? '';
    t.score = toD(j['score']);
    t.btcFlux = (j['btcFlux'] as String?) ?? '';
    t.tokenTrend = (j['tokenTrend'] as String?) ?? '';
    t.flags = (j['flags'] as String?) ?? '';
    t.mfePct = toD(j['mfePct']);
    t.maePct = toD(j['maePct']);
    t.appVersion = (j['appVersion'] as String?) ?? '';
    t.remaining = toD(j['remaining']);
    t.realized = toD(j['realized']);
    t.tp1Hit = j['tp1Hit'] as bool;
    t.status = j['status'] as String;
    t.closedAt = j['closedAt'] == null ? null : (j['closedAt'] as num).toInt();
    t.exit = j['exit'] == null ? null : toD(j['exit']);
    return t;
  }
}

class Simulator {
  Simulator(this._priceOf, this._onChange, this._notify);

  final double? Function(String) _priceOf;
  final VoidCallback _onChange;
  final void Function(String, String) _notify;
  static const int maxOpen = 20;
  static const int burstMax = 3; // ouvertures automatiques max ...
  static const int burstWindowMin = 10; // ... par fenetre de 10 minutes
  static const int lossStreak = 3; // pertes consecutives declenchant une pause
  static const int pauseMin = 30; // duree de la pause (minutes)
  double maxExposure = 1.0; // exposition totale max (x capital)
  int cooldownMs = 3600000; // delai avant de racheter un jeton apres sa sortie (SL, TP, BE)
  String lastRefusal = '';

  static const double startBalance = 10000;
  double balance = startBalance;
  final List<PaperTrade> open = [];
  final List<PaperTrade> history = [];
  int _id = 1;
  String lastAutoMsg = '';

  double equity() {
    double e = balance;
    for (final t in open) {
      final p = _priceOf(t.symbol);
      if (p != null) e += t.unrealized(p);
    }
    return e;
  }

  String encode() => jsonEncode(<String, dynamic>{
        'balance': balance,
        'id': _id,
        'open': open.map((t) => t.toJson()).toList(),
        'history': history.map((t) => t.toJson()).toList(),
      });

  void load(String? s) {
    if (s == null) return;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      balance = toD(j['balance']);
      _id = (j['id'] as num).toInt();
      open
        ..clear()
        ..addAll((j['open'] as List<dynamic>)
            .map((e) => PaperTrade.fromJson(Map<String, dynamic>.from(e as Map))));
      history
        ..clear()
        ..addAll((j['history'] as List<dynamic>)
            .map((e) => PaperTrade.fromJson(Map<String, dynamic>.from(e as Map))));
    } catch (_) {}
  }

  void reset() {
    balance = startBalance;
    open.clear();
    history.clear();
    _onChange();
  }

  TradePlan buildPlan({
    required String symbol,
    required bool long,
    required double entry,
    required double slPct,
    required Market market,
    required double riskPct,
    double tpR = 1.5,
  }) {
    final slFrac = slPct / 100;
    final dir = long ? 1.0 : -1.0;
    final sl = entry * (1 - dir * slFrac);
    final tp1 = entry * (1 + dir * slFrac * tpR);
    final tp2 = entry * (1 + dir * slFrac * tpR * 2);
    final risk = balance * riskPct / 100;
    var notional = risk / slFrac;
    double lev = 1.0;
    if (market == Market.futures) {
      lev = math.max(1.0, math.min(10.0, (1 / (2 * slFrac)).floorToDouble()));
      notional = math.min(notional, balance * 0.25 * lev);
    } else {
      notional = math.min(notional, balance * 0.25);
    }
    return TradePlan(
      symbol: symbol,
      long: long,
      entry: entry,
      sl: sl,
      tp1: tp1,
      tp2: tp2,
      leverage: lev,
      notional: notional,
      riskUsd: notional * slFrac,
    );
  }

  /// Temps restant (ms) avant de pouvoir racheter ce jeton apres sa derniere sortie, 0 si libre.
  int cooldownLeftMs(String symbol) {
    if (cooldownMs <= 0) return 0;
    if (open.any((t) => t.symbol == symbol)) return 0;
    for (final t in history) {
      if (t.symbol == symbol) {
        final left = cooldownMs - (DateTime.now().millisecondsSinceEpoch - (t.closedAt ?? 0));
        return left > 0 ? left : 0;
      }
    }
    return 0;
  }

  double openNotional() {
    double e = 0;
    for (final t in open) {
      e += t.notional * t.remaining;
    }
    return e;
  }

  /// Raison pour laquelle le trading automatique doit attendre (rafale d'ouvertures ou serie de pertes), sinon null.
  String? autoBlockReason() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var streak = 0;
    for (final t in history) {
      if (t.realized < 0) {
        streak++;
      } else {
        break;
      }
    }
    if (streak >= lossStreak && history.isNotEmpty) {
      final lastClose = history.first.closedAt ?? 0;
      final remain = pauseMin * 60000 - (now - lastClose);
      if (remain > 0) {
        return 'pause apres $streak pertes consecutives (${(remain / 60000).ceil()} min restantes)';
      }
    }
    var recent = 0;
    for (final t in <PaperTrade>[...open, ...history]) {
      if (now - t.openedAt < burstWindowMin * 60000) recent++;
    }
    if (recent >= burstMax) return 'trop d ouvertures en $burstWindowMin min (max $burstMax)';
    return null;
  }

  PaperTrade? openPlan(TradePlan p, Market m, {String source = 'bureaux'}) {
    lastRefusal = '';
    if (open.length >= maxOpen) {
      lastRefusal = 'limite de $maxOpen positions atteinte';
      return null;
    }
    if (open.any((t) => t.symbol == p.symbol)) {
      lastRefusal = 'position deja ouverte sur ce jeton';
      return null;
    }
    if (!p.long && m == Market.spot) {
      lastRefusal = 'short impossible en SPOT';
      return null;
    }
    // Pas de rachat immediat apres une sortie (sauf envoi manuel depuis les bureaux)
    if (source != 'bureaux') {
      final left = cooldownLeftMs(p.symbol);
      if (left > 0) {
        lastRefusal = 'rachat bloque : encore ${(left / 60000).ceil()} min apres la derniere sortie';
        return null;
      }
    }
    final exposure = openNotional() + p.notional;
    final cap = equity() * maxExposure;
    if (exposure > cap) {
      lastRefusal = 'exposition totale ${exposure.toStringAsFixed(0)} USDT > plafond ${cap.toStringAsFixed(0)} USDT';
      return null;
    }
    final t = PaperTrade(
      id: _id++,
      symbol: p.symbol,
      long: p.long,
      futures: m == Market.futures,
      entry: p.entry,
      notional: p.notional,
      leverage: p.leverage,
      sl: p.sl,
      tp1: p.tp1,
      tp2: p.tp2,
      openedAt: DateTime.now().millisecondsSinceEpoch,
    );
    t.source = source;
    t.score = p.score;
    t.btcFlux = p.btcFlux;
    t.tokenTrend = p.tokenTrend;
    t.flags = p.flags;
    t.appVersion = kBuild;
    final fee = p.notional * m.fee;
    t.realized -= fee;
    balance -= fee;
    open.add(t);
    _notify(
      '📈 Paper trade ouvert · ${p.symbol}',
      '${p.long ? 'LONG' : 'SHORT'} x${p.leverage.toStringAsFixed(0)} ${m.label} · entrée ${fmtPrice(p.entry)} · '
      'SL ${fmtPrice(p.sl)} · TP1 ${fmtPrice(p.tp1)} · TP2 ${fmtPrice(p.tp2)}',
    );
    _onChange();
    return t;
  }

  /// Ouverture automatique sur alerte. Le flux BTC est un contexte, pas un veto :
  /// contre le flux BTC, le trade n'est permis que si le jeton montre sa propre force relative
  /// (kRelStrength % de mieux ou de moins bien que BTC sur 24 h), avec un risque reduit de moitie.
  void autoOpen(TokenData tk, bool up, Trend trend, Market m, double riskPct, {double rel = 0}) {
    if (!up && m == Market.spot) {
      lastAutoMsg = '${tk.base} : short impossible en SPOT';
      return;
    }
    final against = (up && trend == Trend.bear) || (!up && trend == Trend.bull);
    var risk = riskPct;
    if (against) {
      final own = up ? rel >= kRelStrength : rel <= -kRelStrength;
      if (!own) {
        lastAutoMsg = '${tk.base} : ${up ? 'long' : 'short'} refuse (BTC ${up ? 'baissier' : 'haussier'}, '
            'force relative insuffisante : ${rel.toStringAsFixed(1)} % vs BTC)';
        return;
      }
      risk = riskPct * 0.5;
    }
    final slPct = clampD(tk.rangePct * 0.2, 0.6, 6.0);
    final plan = buildPlan(
      symbol: tk.symbol,
      long: up,
      entry: tk.price,
      slPct: slPct,
      market: m,
      riskPct: risk,
    );
    final t = openPlan(plan, m);
    final tag = against ? ' (contre flux BTC, risque /2)' : '';
    lastAutoMsg = t == null ? '${tk.base} : position non ouverte (limite)' : '${tk.base} : paper trade ouvert$tag';
  }

  double _fee(PaperTrade t) => t.futures ? Market.futures.fee : Market.spot.fee;

  void _realize(PaperTrade t, double frac, double price) {
    final pnl = t.notional * frac * (price / t.entry - 1) * (t.long ? 1 : -1) -
        t.notional * frac * _fee(t);
    t.realized += pnl;
    balance += pnl;
  }

  void _close(PaperTrade t, double price, String status) {
    _realize(t, t.remaining, price);
    t.remaining = 0;
    t.exit = price;
    t.status = status;
    t.closedAt = DateTime.now().millisecondsSinceEpoch;
    open.remove(t);
    history.insert(0, t);
    if (history.length > 500) history.removeLast();
    final label = switch (status) {
      'tp' => 'TP2 atteint',
      'sl' => 'Stop loss touché',
      'be' => 'Break-even (TP1 pris)',
      _ => 'Fermé manuellement',
    };
    _notify(
      '${t.realized >= 0 ? '✅' : '❌'} Paper trade fermé · ${t.symbol}',
      '$label · PnL ${fmtUsd(t.realized)} USDT · sortie ${fmtPrice(price)}',
    );
    _onChange();
  }

  void closeManual(PaperTrade t) {
    final p = _priceOf(t.symbol);
    if (p == null) return;
    _close(t, p, 'manual');
  }

  void onPrices() {
    for (final t in List<PaperTrade>.from(open)) {
      final p = _priceOf(t.symbol);
      if (p == null || p <= 0) continue;
      final move = (p / t.entry - 1) * 100 * (t.long ? 1 : -1);
      if (move > t.mfePct) t.mfePct = move;
      if (move < t.maePct) t.maePct = move;
      final hitSl = t.long ? p <= t.sl : p >= t.sl;
      if (hitSl) {
        _close(t, t.sl, t.tp1Hit ? 'be' : 'sl');
        continue;
      }
      if (!t.tp1Hit && (t.long ? p >= t.tp1 : p <= t.tp1)) {
        _realize(t, 0.5, t.tp1);
        t.remaining = 0.5;
        t.tp1Hit = true;
        t.sl = t.entry;
        _onChange();
      }
      if (t.tp1Hit && (t.long ? p >= t.tp2 : p <= t.tp2)) {
        _close(t, t.tp2, 'tp');
      }
    }
  }
}
