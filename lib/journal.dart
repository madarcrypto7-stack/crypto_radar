import 'models.dart';
import 'simulator.dart';

class JournalStats {
  int closed = 0;
  int open = 0;
  int wins = 0;
  double totalPnl = 0;
  double grossWin = 0;
  double grossLoss = 0;
  double best = 0;
  double worst = 0;
  double sumR = 0;

  double get winRate => closed > 0 ? wins / closed * 100 : 0;
  double get profitFactor => grossLoss > 0 ? grossWin / grossLoss : (grossWin > 0 ? 99.0 : 0.0);
  double get avgWin => wins > 0 ? grossWin / wins : 0;
  double get avgLoss => (closed - wins) > 0 ? grossLoss / (closed - wins) : 0;
  double get avgR => closed > 0 ? sumR / closed : 0;
}

double riskUsd(PaperTrade t) {
  if (t.entry <= 0) return 0;
  return t.notional * (t.entry - t.slInit).abs() / t.entry;
}

JournalStats journalStats(Simulator sim) {
  final s = JournalStats();
  s.open = sim.open.length;
  for (final t in sim.history) {
    s.closed++;
    final p = t.realized;
    s.totalPnl += p;
    if (p > 0) {
      s.wins++;
      s.grossWin += p;
    } else {
      s.grossLoss += -p;
    }
    if (s.closed == 1 || p > s.best) s.best = p;
    if (s.closed == 1 || p < s.worst) s.worst = p;
    final r = riskUsd(t);
    if (r > 0) s.sumR += p / r;
  }
  return s;
}

String _csv(Object? v) {
  final s = v == null ? '' : '$v';
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String _iso(int? ms) =>
    ms == null ? '' : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

String _result(String status) => switch (status) {
      'tp' => 'TP2',
      'sl' => 'STOP_LOSS',
      'be' => 'BREAK_EVEN',
      'manual' => 'MANUEL',
      _ => 'OUVERT',
    };

/// Journal de trading complet (positions ouvertes + historique), au format CSV.
String buildJournalCsv(Simulator sim, double? Function(String) priceOf) {
  final rows = <String>[
    [
      'id', 'symbole', 'marche', 'sens', 'levier', 'ouverture_utc', 'cloture_utc', 'duree_min',
      'entree', 'stop_loss_initial', 'tp1', 'tp2', 'sortie_ou_prix_actuel', 'taille_usdt',
      'marge_usdt', 'risque_usdt', 'tp1_atteint', 'resultat', 'pnl_usdt', 'pnl_pct_taille', 'r_multiple',
      'source', 'score_radar', 'flux_btc', 'tendance_jeton', 'drapeaux', 'mfe_pct', 'mae_pct', 'version_app',
    ].join(','),
  ];
  final all = <PaperTrade>[...sim.open, ...sim.history]..sort((a, b) => a.openedAt.compareTo(b.openedAt));
  for (final t in all) {
    final isOpen = t.status == 'open';
    final px = isOpen ? priceOf(t.symbol) : t.exit;
    final pnl = isOpen && px != null ? t.unrealized(px) + t.realized : t.realized;
    final end = t.closedAt ?? DateTime.now().millisecondsSinceEpoch;
    final mins = ((end - t.openedAt) / 60000).round();
    final risk = riskUsd(t);
    rows.add(<Object?>[
      t.id,
      t.symbol,
      t.futures ? 'FUTURES' : 'SPOT',
      t.long ? 'LONG' : 'SHORT',
      t.leverage.toStringAsFixed(0),
      _iso(t.openedAt),
      _iso(t.closedAt),
      mins,
      t.entry,
      t.slInit,
      t.tp1,
      t.tp2,
      px ?? '',
      t.notional.toStringAsFixed(2),
      t.margin.toStringAsFixed(2),
      risk.toStringAsFixed(2),
      t.tp1Hit ? 'oui' : 'non',
      _result(t.status),
      pnl.toStringAsFixed(4),
      t.notional > 0 ? (pnl / t.notional * 100).toStringAsFixed(3) : '',
      risk > 0 ? (pnl / risk).toStringAsFixed(2) : '',
      t.source,
      t.source.isEmpty ? '' : t.score.toStringAsFixed(0),
      t.btcFlux,
      t.tokenTrend,
      t.flags,
      t.mfePct.toStringAsFixed(2),
      t.maePct.toStringAsFixed(2),
      t.appVersion,
    ].map(_csv).join(','));
  }
  return rows.join('\n');
}
